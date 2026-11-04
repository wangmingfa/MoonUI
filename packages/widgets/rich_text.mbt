///|
/// `RichText`——富文本（`T102` 的下一位住户，第二十二刀）。
///
/// 与 `Label` 的本质区别是**换行**：Label 一行到底，这里按可用宽度把一段带
/// 内联样式的文字重排成多行。数据模型是 `Array[RichSpan]`——每段 span 有
/// 自己的颜色与加粗，None 色继承控件默认色。
///
/// **范围裁决（第一版）**：同一段文字统一字号（`font~`），span 只分颜色与
/// 加粗，不做 span 级字号——多字号混排要算基线对齐，等有真实消费者再开。
/// 断行口径：**空格处可断、CJK 字符（码位 ≥ 0x2E80，含全角标点）之间可断、
/// 连续的西文词不可断**——中文没有空格，按词断等于整段不断。英文长词超过
/// 整行宽时按字符硬断（宁可劈开也不丢字、不画到框外）。span 边界算可断点
/// （两段 span 拼出的"词"在边界断开是可接受的第一版近似）。
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
/// `text` 那一样）。

///|
/// 一段内联样式文字。`color = None` 继承控件默认色。
pub(all) struct RichSpan {
  text : String
  color : Int32?
  bold : Bool
}

///|
/// 无样式的 span（继承默认色、不加粗）。
pub fn RichSpan::plain(text : String) -> RichSpan {
  { text, color: None, bold: false, }
}

///|
/// 带样式的 span。
pub fn RichSpan::styled(
  text : String,
  color~ : Int32,
  bold~ : Bool = false,
) -> RichSpan {
  { text, color: Some(color), bold, }
}

///|
/// 同行内的一段同样式文字（预算好的落点，绘制零计算）。
priv struct RichPiece {
  text : String
  color : Int32
  bold : Bool
  x : Double
}

///|
/// 排完的一行。
priv struct RichLine {
  pieces : Array[RichPiece]
  height : Double
}

///|
/// 分词产物：一段待装行的文字 + 它的样式 + 它能不能被断行拆开。
/// 断行口径记在 token 身上而不是装行现场判断字符——装行只认"这个 token
/// 愿不愿意留在本行"，字符口径只在分词那一处。
priv struct RichTok {
  text : String
  color : Int32
  bold : Bool
  /// true = 空格 / CJK 单字（前后都能断）；false = 西文词（整词一起挪）。
  breakable : Bool
}

///|
/// 可变账（与 `SparkState` 同一条理由：绘制回调捕获状态，控件只是宿主）。
/// `lines` 是布局缓存，`laid_out_at` 记"这份缓存是按多宽排的"——宽度对不上
/// 就重排，调用方覆盖宽度不需要通知本控件。
struct RichState {
  mut spans : Array[RichSpan]
  font : Double
  base_color : Int32
  line_spacing : Double
  mut lines : Array[RichLine]?
  mut laid_out_at : Double
}

///|
/// 富文本控件。`new` 之后用 `widget()` 进布局，`set_spans()` 换内容（自动
/// 重画）。`width`/`height` 是声明尺寸，`.width()/.height()` 仍可覆盖，
/// 覆盖之后第一次绘制按实际宽重排。
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
fn rich_tokens(state : RichState) -> Array[RichTok] {
  let out : Array[RichTok] = []
  for span in state.spans {
    let color = match span.color {
      Some(c) => c
      None => state.base_color
    }
    let chars = span.text.to_array()
    let mut i = 0
    while i < chars.length() {
      let ch = chars[i]
      let code = ch.to_int()
      if code == 0x20 {
        out.push({ text: " ", color, bold: span.bold, breakable: true, })
        i = i + 1
      } else if rich_is_cjk(code) {
        out.push({
          text: ch.to_string(),
          color,
          bold: span.bold,
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
        out.push({
          text: rich_chars_to_string(chars, start, i),
          color,
          bold: span.bold,
          breakable: false,
        })
      }
    }
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
/// 贪心装行。换行发生在"装不下"的 token 之前；行首空格丢弃；行首超宽的
/// token 按字符硬断（前缀塞满本行、余下重试——每次至少断掉一个字符，不会
/// 死循环）。同样式相邻 piece 合并成一条命令。
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
  let mut i = 0
  while i < tokens.length() {
    let tok = tokens[i]
    if tok.text == "" {
      i = i + 1
      continue
    }
    let (tw, th) = rich_measure(backend, tok.text, state.font, tok.bold)
    if tok.text == " " && x == 0.0 {
      i = i + 1 // 行首空格丢弃
      continue
    }
    if x > 0.0 && x + tw > avail {
      // 换行：本行落账，token 原地重试（行首空格会被上面的分支丢掉）
      lines.push({ pieces, height: line_h, })
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
          state.font,
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
        let (_, hh) = rich_measure(backend, head, state.font, tok.bold)
        pieces.push({ text: head, color: tok.color, bold: tok.bold, x: 0.0, })
        lines.push({ pieces, height: hh, })
        pieces = []
        x = 0.0
        line_h = 0.0
        // 余下部分替换当前 token，原地重试
        tokens[i] = {
          text: rich_chars_to_string(chars, best, chars.length()),
          color: tok.color,
          bold: tok.bold,
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
      if last.color == tok.color && last.bold == tok.bold {
        pieces[n - 1] = {
          text: last.text + tok.text,
          color: last.color,
          bold: last.bold,
          x: last.x,
        }
      } else {
        pieces.push({ text: tok.text, color: tok.color, bold: tok.bold, x, })
      }
    } else {
      pieces.push({ text: tok.text, color: tok.color, bold: tok.bold, x, })
    }
    x = x + tw
    if th > line_h {
      line_h = th
    }
    i = i + 1
  }
  if pieces.length() > 0 || lines.length() == 0 {
    lines.push({ pieces, height: line_h, })
  }
  lines
}

///|
/// 绘制：按缓存行逐条发 `Text` 命令，超出控件底的行整行不发（窗口化）。
/// 同字号下行高一致，piece 的 y 就是行顶（省一次竖直居中算术）。
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
  let mut y = 0.0
  for line in lines {
    if y >= h {
      break
    }
    for piece in line.pieces {
      // 纯空格 piece 不进命令清单（画了也是空白，省一条无输出的调用）
      if piece.text == " " || piece.text == "" {
        continue
      }
      dl.text(
        piece.text,
        piece.x,
        y,
        size=state.font,
        bold=piece.bold,
        rgb=piece.color,
      )
    }
    y = y + line.height + state.line_spacing
  }
}

///|
/// 造一个富文本。
///
/// - `font` 是整段统一字号；`color` 是默认色（span 的 `color: None` 继承它）；
/// - `line_spacing` 是行间空隙（行高本身来自后端度量，mock 12px 字号 = 16 高）；
/// - `width`/`height` 是声明尺寸；断行按可用宽（= 声明宽或覆盖宽）算。
pub fn[B : @moonui.Backend] RichText::new(
  backend : B,
  spans : Array[RichSpan],
  width~ : Double = 200.0,
  height~ : Double = 80.0,
  font~ : Double = 13.0,
  color~ : Int32 = 0x1A202C,
  line_spacing~ : Double = 6.0,
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
