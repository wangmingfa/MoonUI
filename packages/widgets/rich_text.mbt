///|
/// `RichText`——富文本（`T102` 的下一位住户，第二十二刀；第二十六刀补齐
/// 四件收尾：span 级字号、跨 span 词合并、滚动偏移、链接命中）。
///
/// 与 `Label` 的本质区别是**换行**：Label 一行到底，这里按可用宽度把一段带
/// 内联样式的文字重排成多行。数据模型是 `Array[RichSpan]`——每段 span 有
/// 自己的颜色、加粗、字号与链接标记，None 色继承控件默认色，None 字号继承
/// 控件字号。
///
/// **多字号基线（第二十六刀）**：mock 口径里度量只有"文本宽 × 字号高"，没有
/// 上伸部/下伸部，真正的字体基线对齐无从算起——这里取**盒底对齐**：piece 的
/// y = 行顶 + (行高 − piece 高)。行高取本行最大 piece 高，单一字号的行退化
/// 为旧行为（y 就是行顶），混排时小字沉到行底、与最大字共底边。真后端有
/// 度量细节了再换成真基线，判据不受影响（坐标是本控件的账）。
///
/// **断行口径**：**空格处可断、CJK 字符（码位 ≥ 0x2E80，含全角标点）之间
/// 可断、连续的西文词不可断**——中文没有空格，按词断等于整段不断。**词
/// 识别跨 span**（第二十六刀）：相邻两段 span 拼出的同一个西文词（同为不可
/// 断、样式完全相同）先合并再装行——不在词中间断开。英文长词超过整行宽时
/// 按字符硬断（宁可劈开也不丢字、不画到框外）。
///
/// **滚动偏移（第二十六刀）**：控件自带竖向滚动账——`Scroll` 事件增减偏移、
/// 绘制按偏移平移，上限 = 内容高 − 视口高、下限 0（写进来的值不夹，**读的
/// 时候夹**，与 `DataGrid` 同一条纪律）。`content_height()` 给外部滚动视口
/// 算总高，`set_offset`/`offset()` 让外部接管滚动手势。
///
/// **链接（第二十六刀）**：`RichSpan::link` 出来的 span 画下划线；点击落
/// 在链接 piece 上时回调 `on_link(span 序号, 文本)`——序号让消费方回查自己
/// 的数据（打开 URL、跳锚点都行），控件不猜语义。`link_at(x, y)` 是同一套
/// 命中的公开版（控件局部坐标）。
///
/// **布局是缓存的**：断行要逐 token 过后端度量（真机上过 C），所以只在
/// "宽度变了或数据变了"时重排（与 `DataGrid` 自适应列宽的缓存同一条理由），
/// 每帧只做"按缓存行画"这道纯算术。宽度对不上就重排——调用方用
/// `.width()` 覆盖声明宽之后，第一次绘制自己就把布局换过来，不需要显式
/// invalidate。
///
/// **窗口化**：高只有 `height~` 那么多，超出控件底的行整行不发命令——与
/// `DataGrid` / `TreeView` 的"看不见的就不画"同一条，天然支持外部拿滚动
/// 视口包着用（歌词滚动那类消费者）。
///
/// **同行同款合并**：相邻同样式 token 合并成一条 `Text` 命令——"hello world"
/// 是词 + 空格 + 词三个 token，一条命令发出去比三条便宜，语义完全一致。
///
/// 坐标一律控件局部逻辑像素（`T101` 的契约）；一条 ABI 都没动（全是
/// `text` / `line` 两样）。

///|
/// 一段内联样式文字。`color = None` 继承控件默认色；`size = None` 继承
/// 控件字号；`link = true` 画下划线、参与点击命中。
pub(all) struct RichSpan {
  text : String
  color : Int32?
  bold : Bool
  size : Double?
  link : Bool
}

///|
/// 无样式的 span（继承默认色与字号、不加粗）。
pub fn RichSpan::plain(text : String) -> RichSpan {
  { text, color: None, bold: false, size: None, link: false, }
}

///|
/// 带样式的 span（`size~` 不传 = 继承控件字号）。
pub fn RichSpan::styled(
  text : String,
  color~ : Int32,
  bold~ : Bool = false,
  size~ : Double? = None,
) -> RichSpan {
  { text, color: Some(color), bold, size, link: false, }
}

///|
/// 链接 span：下划线 + 点击回调，默认链接蓝。
pub fn RichSpan::link(text : String, color~ : Int32 = 0x3182CE) -> RichSpan {
  { text, color: Some(color), bold: false, size: None, link: true, }
}

///|
/// span 的生效字号：None 或非正数都退回控件字号。
fn rich_span_size(span : RichSpan, font : Double) -> Double {
  match span.size {
    Some(s) => if s > 0.0 { s } else { font }
    None => font
  }
}

///|
/// 同行内的一段同样式文字（预算好的落点，绘制零计算）。
priv struct RichPiece {
  text : String
  color : Int32
  bold : Bool
  size : Double
  link : Bool
  span : Int32
  x : Double
  w : Double
  h : Double
}

///|
/// 排完的一行。
priv struct RichLine {
  pieces : Array[RichPiece]
  height : Double
  y : Double
}

///|
/// 分词产物：一段待装行的文字 + 它的样式 + 它能不能被断行拆开。
/// 断行口径记在 token 身上而不是装行现场判断字符——装行只认"这个 token
/// 愿不愿意留在本行"，字符口径只在分词那一处。
priv struct RichTok {
  text : String
  color : Int32
  bold : Bool
  size : Double
  link : Bool
  span : Int32
  /// true = 空格 / CJK 单字（前后都能断）；false = 西文词（整词一起挪）。
  breakable : Bool
}

///|
/// 两枚 token 画出来是不是同款（颜色/加粗/字号/链接全同）。span 序号不算
/// ——跨 span 同款词合并靠它放行。
fn rich_tok_same_style(a : RichTok, b : RichTok) -> Bool {
  a.color == b.color && a.bold == b.bold && a.size == b.size && a.link == b.link
}

///|
/// 可变账（与 `SparkState` 同一条理由：绘制回调捕获状态，控件只是宿主）。
/// `lines` 是布局缓存，`laid_out_at` 记"这份缓存是按多宽排的"——宽度对不上
/// 就重排，调用方覆盖宽度不需要通知本控件。`offset` 是竖向滚动偏移（写不
/// 夹、读时夹）。`on_link` 是链接点击回调（span 序号, 文本）。
struct RichState {
  mut spans : Array[RichSpan]
  font : Double
  base_color : Int32
  line_spacing : Double
  mut lines : Array[RichLine]?
  mut laid_out_at : Double
  mut offset : Double
  mut on_link : ((Int32, String) -> Unit)?
}

///|
/// 富文本控件。`new` 之后用 `widget()` 进布局，`set_spans()` 换内容（自动
/// 重画）。`width`/`height` 是声明尺寸，`.width()/.height()` 仍可覆盖，
/// 覆盖之后第一次绘制按实际宽重排。`on_link~` 接链接点击回调
/// （参数：span 序号、文本）。
pub struct RichText[B] {
  widget : @moonui.Widget[B]
  state : RichState
  backend : B
  size : @moonui.LogicalSize
}

///|
/// 码位是不是 CJK（含全角标点区）。0x2E80 起：CJK 部首、汉字、假名、
/// 全角 forms 都在之上；ASCII 与一般西文（含扩展拉丁）都在之下。作为
/// "字符之间可不可以断行"的口径够用，不做字典级的正字法。
fn rich_is_cjk(code : Int32) -> Bool {
  code >= 0x2E80
}

///|
/// chars[start:end] 拼成 String（`text_fit` 的 `text_prefix` 同款手法，
/// 这里要区间所以另写）。
fn rich_chars_to_string(
  chars : Array[Char],
  start : Int32,
  end : Int32,
) -> String {
  let mut out = ""
  let mut i = start
  while i < end {
    out = out + chars[i].to_string()
    i = i + 1
  }
  out
}

///|
/// 把 spans 展开成 token 序列。空格单独成 token（可断、行首可丢）；CJK
/// 逐字成 token（可断）；其余连续字符并成词（不可断，span 边界断开）。
/// 收尾做一遍**跨 span 词合并**：相邻两段 span 拼出的同一个西文词（同为
/// 不可断、同款）并成一枚——词中间的 span 边界不再算断点。
fn rich_tokens(state : RichState) -> Array[RichTok] {
  let raw : Array[RichTok] = []
  for si, span in state.spans {
    let color = match span.color {
      Some(c) => c
      None => state.base_color
    }
    let size = rich_span_size(span, state.font)
    let chars = span.text.to_array()
    let mut i = 0
    while i < chars.length() {
      let ch = chars[i]
      let code = ch.to_int()
      if code == 0x20 {
        raw.push({
          text: " ",
          color,
          bold: span.bold,
          size,
          link: span.link,
          span: si,
          breakable: true,
        })
        i = i + 1
      } else if rich_is_cjk(code) {
        raw.push({
          text: ch.to_string(),
          color,
          bold: span.bold,
          size,
          link: span.link,
          span: si,
          breakable: true,
        })
        i = i + 1
      } else {
        // 连续的非空格、非 CJK 字符并成一个词
        let start = i
        while i < chars.length() {
          let k = chars[i].to_int()
          if k == 0x20 || rich_is_cjk(k) {
            break
          }
          i = i + 1
        }
        raw.push({
          text: rich_chars_to_string(chars, start, i),
          color,
          bold: span.bold,
          size,
          link: span.link,
          span: si,
          breakable: false,
        })
      }
    }
  }
  let out : Array[RichTok] = []
  for tok in raw {
    let n = out.length()
    if n > 0 {
      let last = out[n - 1]
      if !last.breakable && !tok.breakable && rich_tok_same_style(last, tok) {
        out[n - 1] = { ..last, text: last.text + tok.text, }
        continue
      }
    }
    out.push(tok)
  }
  out
}

///|
/// token 的宽度与高度（mock 口径：宽 = 字符数 × 8 × 字号/12，粗体 ×1.25；
/// 高 = 16 × 字号/12）。
fn[B : @moonui.Backend] rich_measure(
  backend : B,
  text : String,
  font : Double,
  bold : Bool,
) -> (Double, Double) raise @moonui.UiError {
  backend.measure_text(text, font, bold)
}

///|
/// 内容总高：n 行高之和 + (n-1) 个行距。空内容 = 0。
fn rich_content_height_of(lines : Array[RichLine], spacing : Double) -> Double {
  let n = lines.length()
  if n == 0 {
    return 0.0
  }
  let mut h = 0.0
  for line in lines {
    h = h + line.height
  }
  h + spacing * (n - 1).to_double()
}

///|
/// 生效滚动偏移：把账面值夹进 [0, max(0, 内容高 − 视口高)]。夹在**读的
/// 时候**做——`DataGrid` 的 `grid_clamp_offset` 同一条纪律。
fn rich_effective_offset(
  state : RichState,
  lines : Array[RichLine],
  viewport_h : Double,
) -> Double {
  let over = rich_content_height_of(lines, state.line_spacing) - viewport_h
  let max = if over > 0.0 { over } else { 0.0 }
  if state.offset < 0.0 {
    0.0
  } else if state.offset > max {
    max
  } else {
    state.offset
  }
}

///|
/// 贪心装行。换行发生在"装不下"的 token 之前；行首空格丢弃；行首超宽的
/// token 按字符硬断（前缀塞满本行、余下重试——每次至少断掉一个字符，不会
/// 死循环）。同样式相邻 piece 合并成一条命令（同款判定含字号与链接，但
/// **不含 span 序号**——跨 span 同款照样并）。
///
/// 每行的 `y` 在落账时记下、随即推进——行顶 = 前面所有行高与行距之和。
///
/// 账要紧的一处：`pieces` 是**引用**，flush 时不能 push 进行之后再清空
/// （那会把行里的也掏空）——每次 flush 换**新数组**，旧行带着自己的那只走。
fn[B : @moonui.Backend] rich_layout(
  state : RichState,
  backend : B,
  width : Double,
) -> Array[RichLine] raise @moonui.UiError {
  let avail = if width > 0.0 { width } else { 0.0 }
  let tokens = rich_tokens(state)
  let lines : Array[RichLine] = []
  let mut pieces : Array[RichPiece] = []
  let mut x = 0.0
  let mut line_h = 0.0
  let mut line_y = 0.0
  let mut i = 0
  while i < tokens.length() {
    let tok = tokens[i]
    if tok.text == "" {
      i = i + 1
      continue
    }
    let (tw, th) = rich_measure(backend, tok.text, tok.size, tok.bold)
    if tok.text == " " && x == 0.0 {
      i = i + 1 // 行首空格丢弃
      continue
    }
    if x > 0.0 && x + tw > avail {
      // 换行：本行落账，token 原地重试（行首空格会被上面的分支丢掉）
      lines.push({ pieces, height: line_h, y: line_y, })
      line_y = line_y + line_h + state.line_spacing
      pieces = []
      x = 0.0
      line_h = 0.0
      continue
    }
    if x == 0.0 && tw > avail && tok.text != " " {
      // 硬断：最大前缀塞满本行，余下重试。字符 advance 单调不减（正常字体
      // 的假设），线性扫就够；每次至少断一个字符，外层循环必然推进。
      let chars = tok.text.to_array()
      let mut k = 1
      let mut best = 0
      while k <= chars.length() {
        let (pw, _) = rich_measure(
          backend,
          rich_chars_to_string(chars, 0, k),
          tok.size,
          tok.bold,
        )
        if pw <= avail {
          best = k
          k = k + 1
        } else {
          break
        }
      }
      if best > 0 {
        let head = rich_chars_to_string(chars, 0, best)
        let (hw, hh) = rich_measure(backend, head, tok.size, tok.bold)
        pieces.push({
          text: head,
          color: tok.color,
          bold: tok.bold,
          size: tok.size,
          link: tok.link,
          span: tok.span,
          x: 0.0,
          w: hw,
          h: hh,
        })
        lines.push({ pieces, height: hh, y: line_y, })
        line_y = line_y + hh + state.line_spacing
        pieces = []
        x = 0.0
        line_h = 0.0
        // 余下部分替换当前 token，原地重试
        tokens[i] = {
          text: rich_chars_to_string(chars, best, chars.length()),
          color: tok.color,
          bold: tok.bold,
          size: tok.size,
          link: tok.link,
          span: tok.span,
          breakable: tok.breakable,
        }
        continue
      }
      // best == 0：连一个字符都放不下（avail 极小）——整 token 丢弃，别死循环
      i = i + 1
      continue
    }
    // 装进本行：同样式相邻 piece 合并
    let n = pieces.length()
    if n > 0 {
      let last = pieces[n - 1]
      if last.color == tok.color &&
        last.bold == tok.bold &&
        last.size == tok.size &&
        last.link == tok.link {
        pieces[n - 1] = { ..last, text: last.text + tok.text, w: last.w + tw, }
      } else {
        pieces.push({
          text: tok.text,
          color: tok.color,
          bold: tok.bold,
          size: tok.size,
          link: tok.link,
          span: tok.span,
          x,
          w: tw,
          h: th,
        })
      }
    } else {
      pieces.push({
        text: tok.text,
        color: tok.color,
        bold: tok.bold,
        size: tok.size,
        link: tok.link,
        span: tok.span,
        x,
        w: tw,
        h: th,
      })
    }
    x = x + tw
    if th > line_h {
      line_h = th
    }
    i = i + 1
  }
  if pieces.length() > 0 || lines.length() == 0 {
    lines.push({ pieces, height: line_h, y: line_y, })
  }
  lines
}

///|
/// 绘制：按缓存行逐条发 `Text` 命令，超出控件底的行整行不发（窗口化）。
/// 滚动偏移在行顶上平移（`top = line.y − offset`）：整行滚出视口顶（top +
/// 行高 ≤ 0）跳过、滚出视口底（top ≥ 高）停。
///
/// piece 的 y = 行顶 + (行高 − piece 高)——**盒底对齐**：mock 口径没有上伸
/// 部，取"行内最大字共底边"作确定性近似；单一字号的行 piece 高 = 行高，y
/// 退化为行顶，与旧账完全一致。链接 piece 多发一条下划线 `line` 命令。
fn[B : @moonui.Backend] paint_rich(
  state : RichState,
  backend : B,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit raise @moonui.UiError {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  if state.lines is None || state.laid_out_at != w {
    state.lines = Some(rich_layout(state, backend, w))
    state.laid_out_at = w
  }
  let lines = state.lines.unwrap()
  let offset = rich_effective_offset(state, lines, h)
  for line in lines {
    let top = line.y - offset
    if top >= h {
      break
    }
    if top + line.height <= 0.0 {
      continue
    }
    for piece in line.pieces {
      // 纯空格 piece 不进命令清单（画了也是空白，省一条无输出的调用）
      if piece.text == " " || piece.text == "" {
        continue
      }
      let py = top + (line.height - piece.h)
      dl.text(
        piece.text,
        piece.x,
        py,
        size=piece.size,
        bold=piece.bold,
        rgb=piece.color,
      )
      if piece.link {
        dl.line(
          piece.x,
          py + piece.h,
          piece.x + piece.w,
          py + piece.h,
          width=1.0,
          rgb=piece.color,
        )
      }
    }
  }
}

///|
/// 造一个富文本。
///
/// - `font` 是整段默认字号（span 的 `size: None` 继承它）；`color` 是默认色
///   （span 的 `color: None` 继承它）；
/// - `line_spacing` 是行间空隙（行高本身来自后端度量，mock 12px 字号 = 16 高）；
/// - `width`/`height` 是声明尺寸；断行按可用宽（= 声明宽或覆盖宽）算；
/// - `on_link~` 是链接点击回调（span 序号、文本）——不传也能用 `link_at`
///   自己查命中。
pub fn[B : @moonui.Backend] RichText::new(
  backend : B,
  spans : Array[RichSpan],
  width~ : Double = 200.0,
  height~ : Double = 80.0,
  font~ : Double = 13.0,
  color~ : Int32 = 0x1A202C,
  line_spacing~ : Double = 6.0,
  on_link~ : ((Int32, String) -> Unit)? = None,
) -> RichText[B] raise @moonui.UiError {
  let w = if width > 0.0 { width } else { 0.0 }
  let h = if height > 0.0 { height } else { 0.0 }
  let state = RichState::{
    spans,
    font,
    base_color: color,
    line_spacing,
    lines: None,
    laid_out_at: -1.0,
    offset: 0.0,
    on_link,
  }
  let bk = backend
  // `custom` 的 paint 闭包签名不收 raise：度量失败（后端报错）在这里 catch
  // 掉、退成空帧——真后端的度量不该失败，失败了也没有一个更聪明的画法。
  let widget = @moonui.Widget::custom(backend, @moonui.LogicalSize(w, h), fn(
    dl,
    env,
  ) {
    paint_rich(state, bk, dl, env) catch {
      _ => ()
    }
  })
  // 滚动与链接命中默认接上（`DataGrid` 排序同一条理由：点了没反应是用户
  // 看得见的破绽，而这笔账只有控件自己会算）。想自己接管的应用层仍可以在
  // 订阅里拿到 `Scroll`/`MouseDown`——两条路不冲突（订阅是加法）。
  // 坐标口径：Core 的鼠标事件是窗口/父局部，减 `frame().origin` 换控件局部。
  let _ = widget.on_any(fn(ev) raise @moonui.UiError {
    match ev {
      @moonui.Scroll(_, delta) => {
        let f = widget.frame()
        let vw = if f.size.width > 0.0 { f.size.width } else { w }
        let vh = if f.size.height > 0.0 { f.size.height } else { h }
        if state.lines is None || state.laid_out_at != vw {
          state.lines = Some(rich_layout(state, bk, vw))
          state.laid_out_at = vw
        }
        let lines = state.lines.unwrap()
        let next = rich_effective_offset(state, lines, vh) + delta.y
        if next != state.offset {
          state.offset = next
          widget.repaint()
        }
      }
      @moonui.MouseDown(_, @moonui.Left, p, _) => {
        let origin = widget.frame().origin
        match
          rich_link_at_impl(
            state,
            bk,
            widget,
            p.x - origin.x,
            p.y - origin.y,
            w,
            h,
          ) {
          Some((si, text)) =>
            match state.on_link {
              Some(f) => f(si, text)
              None => ()
            }
          None => ()
        }
      }
      _ => ()
    }
  })
  { widget, state, backend, size: @moonui.LogicalSize(w, h), }
}

///|
/// 拿控件进布局。
pub fn[B] RichText::widget(self : RichText[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 声明尺寸。
pub fn[B] RichText::size(self : RichText[B]) -> @moonui.LogicalSize {
  self.size
}

///|
/// 布局缓存就位（宽度对不上就按给定宽重排）。
fn[B : @moonui.Backend] RichText::ensure_layout(
  self : RichText[B],
  width : Double,
) -> Unit raise @moonui.UiError {
  if self.state.lines is Some(_) && self.state.laid_out_at == width {
    return
  }
  self.state.lines = Some(rich_layout(self.state, self.backend, width))
  self.state.laid_out_at = width
}

///|
/// 按声明宽重排，返回行数。布局要过后端度量，会 raise。
pub fn[B : @moonui.Backend] RichText::line_count(
  self : RichText[B],
) -> Int32 raise @moonui.UiError {
  self.ensure_layout(self.size.width)
  self.state.lines.unwrap().length()
}

///|
/// 按声明宽算内容总高：n 行高之和 + (n-1) 个行距。空内容 = 0。
pub fn[B : @moonui.Backend] RichText::content_height(
  self : RichText[B],
) -> Double raise @moonui.UiError {
  self.ensure_layout(self.size.width)
  let lines = self.state.lines.unwrap()
  let n = lines.length()
  if n == 0 {
    return 0.0
  }
  let mut h = 0.0
  for line in lines {
    h = h + line.height
  }
  h + self.state.line_spacing * (n - 1).to_double()
}

///|
/// 整份换内容并重画（布局缓存一并失效——宽度没变也要重排，数据变了）。
pub fn[B : @moonui.Backend] RichText::set_spans(
  self : RichText[B],
  spans : Array[RichSpan],
) -> Unit raise @moonui.UiError {
  self.state.spans = spans
  self.state.lines = None
  self.widget.repaint()
}

///|
/// 当前 span 数。
pub fn[B] RichText::span_count(self : RichText[B]) -> Int32 {
  self.state.spans.length()
}

///|
/// 链接命中（控件局部坐标）：命中的行里找第一枚**链接** piece 横向罩住 x
/// 的，回 (span 序号, 文本)；没落上（普通文字、行间空隙、空白）回 None。
/// y 先加上生效偏移换回内容坐标——与绘制同一套账，滚到哪都能点。
fn[B : @moonui.Backend] rich_link_at_impl(
  state : RichState,
  backend : B,
  widget : @moonui.Widget[B],
  x : Double,
  y : Double,
  declared_w : Double,
  declared_h : Double,
) -> (Int32, String)? raise @moonui.UiError {
  let f = widget.frame()
  let vw = if f.size.width > 0.0 { f.size.width } else { declared_w }
  let vh = if f.size.height > 0.0 { f.size.height } else { declared_h }
  if state.lines is None || state.laid_out_at != vw {
    state.lines = Some(rich_layout(state, backend, vw))
    state.laid_out_at = vw
  }
  let lines = state.lines.unwrap()
  let ly = y + rich_effective_offset(state, lines, vh)
  for line in lines {
    if ly >= line.y && ly < line.y + line.height + state.line_spacing {
      for piece in line.pieces {
        if piece.link && x >= piece.x && x < piece.x + piece.w {
          return Some((piece.span, piece.text))
        }
      }
    }
  }
  None
}

///|
/// 链接命中，公开版：`x`/`y` 是控件局部坐标（与 `MouseDown` 减
/// `frame().origin` 之后的口径一致）。回 (span 序号, 文本) 或 None。会按
/// 需要重排（过 后端度量），raise。
pub fn[B : @moonui.Backend] RichText::link_at(
  self : RichText[B],
  x : Double,
  y : Double,
) -> (Int32, String)? raise @moonui.UiError {
  rich_link_at_impl(
    self.state,
    self.backend,
    self.widget,
    x,
    y,
    self.size.width,
    self.size.height,
  )
}

///|
/// 设竖向滚动偏移（账面值不夹，读的时候夹进 [0, 内容高 − 视口高]），变了
/// 就重画。
pub fn[B : @moonui.Backend] RichText::set_offset(
  self : RichText[B],
  offset : Double,
) -> Unit raise @moonui.UiError {
  if offset != self.state.offset {
    self.state.offset = offset
    self.widget.repaint()
  }
}

///|
/// 读竖向滚动偏移——**夹好的生效值**（与绘制平移用的是同一个数）。会按
/// 需要重排（过后端度量），raise。
pub fn[B : @moonui.Backend] RichText::offset(
  self : RichText[B],
) -> Double raise @moonui.UiError {
  self.ensure_layout(self.size.width)
  let lines = self.state.lines.unwrap()
  rich_effective_offset(self.state, lines, self.size.height)
}

///|
/// 换链接点击回调（`None` = 撤掉）。
pub fn[B] RichText::set_on_link(
  self : RichText[B],
  f : ((Int32, String) -> Unit)?,
) -> Unit {
  self.state.on_link = f
}
