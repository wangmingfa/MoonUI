///|
/// 把一段文字塞进一段宽度：量 → 放得下就画 / 放不下就省略并夹住。
/// `DataGrid` 的单元格与 `TreeView` 的行文案共用这一条。
///
/// 为什么单独立一个文件：省略号截断这条算术（先量"…"、再二分前缀）在两个控件
/// 里逐字相同，抄两份就意味着"哪天字体度量变了"要改两处；而它又不属于任何一方
/// 的业务，塞进哪个控件文件里，另一个就得去引用一个语义不相关的东西。
///
/// 宽度全部来自 `PaintEnv::measure_text`（后端度量），本文件只管"够不够"——
/// 这也是判据能写死期望值的前提：度量口径由 mock 定死，这里不掺任何常数。

///|
/// 省略号。放常量里是为了"省略之后还剩多少宽度"这件事只有一个出处——两处各
/// 抄一个字面量的话，改一处漏一处会让省略宽度算错一格。
const TEXT_ELLIPSIS : String = "…"

///|
/// 前缀（前 `k` 个字符）。
fn text_prefix(chars : Array[Char], k : Int32) -> String {
  let mut out = ""
  let mut i = 0
  while i < k {
    out = out + chars[i].to_string()
    i = i + 1
  }
  out
}

///|
/// "前 `k` 个字符 + 省略号"有多宽。
fn ellipsis_width(
  env : @moonui.PaintEnv,
  chars : Array[Char],
  k : Int32,
  size : Double,
  bold : Bool,
) -> Double {
  let (w, _) = env.measure_text(
    text_prefix(chars, k) + TEXT_ELLIPSIS,
    size,
    bold,
  )
  w
}

///|
/// 把一段文字裁到 `avail` 宽以内，返回带省略号的版本；连省略号都放不下就返回
/// `""`（宁可留白，也不要画半个字）。
///
/// 为什么二分而不是从头一个个试：字体度量是每条命令一次后端调用（真机上过 C），
/// 一屏几十行 × 几列 × 每个字符一次，就是每帧上万次。二分是 `log2(n)` 次，且
/// 前缀宽度随字符数单调不减——这条假设对任何正常字体都成立（advance 非负）。
fn ellipsize(
  env : @moonui.PaintEnv,
  text : String,
  size : Double,
  bold : Bool,
  avail : Double,
) -> String {
  let (ew, _) = env.measure_text(TEXT_ELLIPSIS, size, bold)
  if ew > avail {
    return ""
  }
  let chars = text.to_array()
  let mut lo = 0
  let mut hi = chars.length()
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    if ellipsis_width(env, chars, mid, size, bold) <= avail {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  text_prefix(chars, lo) + TEXT_ELLIPSIS
}

///|
/// 画一段文字，落点是 `[left, left + avail]` 这一段、竖直居中于 `[top, top + height]`。
/// `align_right` 时贴右端（数字与副文案）。
///
/// **够宽就不夹**不是偷懒：`clip_rect` 要配 `save`/`restore` 三次命令，一屏几十行
/// 全是字，每格都夹等于把命令数翻四倍；真正需要夹的只有少数溢出的格子。夹的
/// 范围就是这**一段文字区**（不是整格）——文字本来只画在内边距以内，夹窄一点
/// 语义更准，也顺带保证省略之后那半个字形不会压到隔壁。
fn draw_fitted_text(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  text : String,
  left : Double,
  avail : Double,
  top : Double,
  height : Double,
  size : Double,
  bold : Bool,
  rgb : Int32,
  align_right : Bool,
) -> Unit {
  if text == "" || avail <= 0.0 {
    return
  }
  let (tw, th) = env.measure_text(text, size, bold)
  let ty = top + (height - th) / 2.0
  if tw <= avail {
    let x = if align_right { left + avail - tw } else { left }
    dl.text(text, x, ty, size~, bold~, rgb~)
    return
  }
  let shown = ellipsize(env, text, size, bold, avail)
  if shown == "" {
    return
  }
  // 省略之后的"…"也要贴着那一侧：右对齐列的数字被截断时，留在右边的才是高位
  let (sw, _) = env.measure_text(shown, size, bold)
  let x = if align_right { left + avail - sw } else { left }
  dl.save()
  dl.clip_rect(left, top, avail, height)
  dl.text(shown, x, ty, size~, bold~, rgb~)
  dl.restore()
}
