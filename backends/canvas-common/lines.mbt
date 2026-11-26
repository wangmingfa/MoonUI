///|
/// 多行文本的可视行排版（`T389`）：把整串按 `\n` 断硬行、再在框宽内按词换行，
/// 得到一张「可视行表」。绘制、光标、选区、点击定位**共用这一张表**——四种
/// 几何必须同源，否则光标会落错行、选区会跨到不该跨的行上、拖选会把字符归
/// 到另一行去。
///
/// 表是纯几何账（字符下标 + 实测宽），不带任何平台状态。量字要走 `Painter`，
/// 所以 `wrap_lines` 是泛型的；同一 Painter + 同一串 + 同一字号 + 同一断行宽，
/// 结果逐位一致——配方（`paint_multiline_entry`）自己排一张用来画，后端另排
/// 一张做点击定位与滚动，两张是同一份几何。本包零 C、零 FFI，进 wasm 门。

///|
/// 文本左缩进（配方与点击定位共用同一把，别各写一个 8.0）
pub const TEXT_PAD : Double = 8.0

///|
/// 首行离框顶的间距（同上）
pub const TOP_PAD : Double = 6.0

///|
/// 一条可视行：整串里 `[start, end)` 的字符，`width` 是这段的实测宽。
/// 空行（`\n\n` 之间）是 `start == end` 的零宽行——不量字，但占一行高。
pub(all) struct VLine {
  start : Int32
  end : Int32
  width : Double
}

///|
/// 构造器，`VLine(start, end, width)` 裸调用
pub fn VLine::VLine(start : Int32, end : Int32, width : Double) -> VLine {
  { start, end, width, }
}

///|
/// 排版（`T389`）：先按 `\n` 断硬行，再在 `max_w` 内按词换行；单词比框还宽就
/// 按字符硬断。`max_w <= 0` = 不折断行（超长行原样溢出，与旧配方一致）。
pub fn[P : Painter] wrap_lines(
  p : P,
  text : String,
  size : Double,
  max_w : Double,
) -> Array[VLine] raise @moonui.UiError {
  let out : Array[VLine] = []
  let mut base = 0
  for hv in text.split("\n").to_array() {
    let hard : String = hv.to_owned()
    let len = hard.length()
    if len == 0 {
      // 空行也占一条：`"a\n\nb"` 得排出三条可视行，否则空段落会塌掉
      out.push(VLine(base, base, 0.0))
    } else {
      let mut cur = 0
      while cur < len {
        let b = break_at(p, hard, cur, len, size, max_w)
        let seg = hard[cur:b].to_owned()
        let (w, _) = if seg == "" {
          (0.0, 0.0)
        } else {
          p.measure_text(seg, size, false)
        }
        out.push(VLine(base + cur, base + b, w))
        cur = b
      }
    }
    // 行尾的 `\n` 本身也算一个字符（下标与 `text` 逐一对应）
    base = base + len + 1
  }
  out
}

///|
/// 找最远的可断位置：段宽装得下、且断点处的字符是空白（或已到硬行尾）。
fn[P : Painter] break_at(
  p : P,
  hard : String,
  cur : Int32,
  len : Int32,
  size : Double,
  max_w : Double,
) -> Int32 raise @moonui.UiError {
  if max_w <= 0.0 {
    return len
  }
  let (whole, _) = p.measure_text(hard[cur:len].to_owned(), size, false)
  if whole <= max_w {
    return len
  }
  // 从远往近退，只在空白处试断（试的少，量字的次数也少）
  for k = len; k > cur + 1; k = k - 1 {
    match hard.get_char(k - 1) {
      Some(c) =>
        if is_break_char(c) {
          let (w, _) = p.measure_text(hard[cur:k].to_owned(), size, false)
          if w <= max_w {
            return k
          }
        }
      None => ()
    }
  }
  // 连一个词都装不下（单词比框宽）：硬断到装得下的最后一个字符
  for k = len; k > cur; k = k - 1 {
    let (w, _) = p.measure_text(hard[cur:k].to_owned(), size, false)
    if w <= max_w {
      return k
    }
  }
  // 单字符也超宽，就断一个字符——否则 while 永远走不出去
  cur + 1
}

///|
/// 断行处认的字符：ASCII 空白（空格、制表）。中文等非空格分词不在这一刀内。
fn is_break_char(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
/// 下标落在哪条可视行：**最后一条**满足 `start <= idx <= end` 的行。断行边界
/// 那个下标同时是上一行末、下一行首——归**下一行首**（原生输入框在软换行处
/// 光标看着就在下一行的行首，`Home`/`End` 也就作用于那半行）。硬换行不受影响：
/// `\n` 之后的行从 `\n` 的下一个下标起，行尾下标（如 `"ab\ncd"` 的 2）只被
/// 上一行认，仍归上一行末。
pub fn vline_of(lines : Array[VLine], idx : Int32) -> Int32 {
  let mut last = -1
  for i = 0; i < lines.length(); i = i + 1 {
    if idx >= lines[i].start && idx <= lines[i].end {
      last = i
    }
  }
  if last < 0 {
    if lines.length() == 0 {
      0
    } else {
      lines.length() - 1
    }
  } else {
    last
  }
}

///|
/// 下标在其可视行内的 x 偏移（行首 = 0）。`text` 是**整串**，下标是整串里的
/// 绝对下标；段为空返回 0（原生 `measure_text` 对空串 raise，见 `T374`）。
pub fn[P : Painter] line_x(
  p : P,
  text : String,
  line : VLine,
  idx : Int32,
  size : Double,
) -> Double raise @moonui.UiError {
  let i = idx.clamp(min=line.start, max=line.end)
  if i == line.start {
    return 0.0
  }
  let seg = text[line.start:i].to_owned()
  let (w, _) = if seg == "" {
    (0.0, 0.0)
  } else {
    p.measure_text(seg, size, false)
  }
  w
}

///|
/// 行内 x → 整串下标：找第一个前缀宽 `>= rel` 的字符（点在字符内或左缘归它），
/// 全部窄于 `rel` 就落行尾。
pub fn[P : Painter] char_at(
  p : P,
  text : String,
  line : VLine,
  size : Double,
  rel : Double,
) -> Int32 raise @moonui.UiError {
  if rel <= 0.0 {
    return line.start
  }
  for i = line.start + 1; i <= line.end; i = i + 1 {
    if line_x(p, text, line, i, size) >= rel {
      return i
    }
  }
  line.end
}

///|
/// 行内 x → 最近下标（`T389` 上下移用）：`|line_x(i) − rel|` 最小的 i，平局取
/// **右边**那个。同一列换行时目标行没有那一列，就落最近的（行首/行尾）；
/// 行尾那一列（rel = 整行宽）精确落回行尾。与 `char_at`（点击用，左偏）不同。
pub fn[P : Painter] nearest_char(
  p : P,
  text : String,
  line : VLine,
  size : Double,
  rel : Double,
) -> Int32 raise @moonui.UiError {
  let mut best = line.start
  let mut best_d = rel.abs()
  for i = line.start + 1; i <= line.end; i = i + 1 {
    let d = (line_x(p, text, line, i, size) - rel).abs()
    if d <= best_d {
      best_d = d
      best = i
    }
  }
  best
}

///|
/// 光标所在可视行滚进视口（`T389`）：`cur` 是当前滚动量、`view_h` 是可视高、
/// `lh` 是行高。只补"看得见"的最小量，不反弹、不居中。
pub fn caret_scroll(
  lines : Array[VLine],
  idx : Int32,
  cur : Double,
  lh : Double,
  view_h : Double,
) -> Double {
  let n = lines.length()
  if n == 0 || lh <= 0.0 {
    return 0.0
  }
  let total = lh * n.to_double()
  let maxs = if total - view_h > 0.0 { total - view_h } else { 0.0 }
  let i = vline_of(lines, idx)
  let top = lh * i.to_double()
  let bot = top + lh
  let mut s = cur.clamp(min=0.0, max=maxs)
  if top < s {
    s = top
  }
  if bot > s + view_h {
    s = bot - view_h
  }
  s.clamp(min=0.0, max=maxs)
}
