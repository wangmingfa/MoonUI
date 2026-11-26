///|
/// 文本几何账（`T389`）：可编辑记账的**可视行表**。绘制那半条路
/// （`paint_multiline_entry`）自己排一张，键盘/鼠标这半条路排另一张——同一份
/// 几何的两次求值，逐位一致（`canvas-common/lines.mbt` 的注）。
///
/// 画布还没收过帧（`win.canvas` None）就没有 Painter 可量字，统一返回 None，
/// 调用方退回"不动"（`T387` 点击定位的同一把）。

///|
/// 本窗的 Painter（画布没收过帧就 None）
fn CanvasBackend::painter_of(
  self : CanvasBackend,
  wi : Int32,
) -> @native-common.CanvasPainter? {
  match self.windows[wi].canvas {
    Some(c) => {
      // 缩放读数失败就按 1.0 走（Painter 只在量字时用，误差只影响定位精度）
      let sc : @moonui.Scale = @moonui.Backend::window_scale(
        self.inner,
        self.windows[wi].handle,
      ) catch {
        _ => @moonui.Scale::one()
      }
      Some(@native-common.CanvasPainter(c, sc.x))
    }
    None => None
  }
}

///|
/// 可编辑记账的可视行表 + 要量字的那条串（`T389`）。多行按框宽换行（断行宽 =
/// 框宽减左右各 8px 缩进，与配方同一把）；其余 kind 就是一条。
fn CanvasBackend::lines_of(
  self : CanvasBackend,
  wi : Int32,
  r : CwRec,
) -> (Array[@canvas-common.VLine], String)? {
  let p = match self.painter_of(wi) {
    Some(pp) => pp
    None => return None
  }
  let raw = r.edit_text()
  let size = self.font_size_of(r)
  // "一整条"退化表：不是多行、或量字失败时用它（编辑照旧能走，只是不换行）
  let one : Array[@canvas-common.VLine] = [
    @canvas-common.VLine(0, r.edit_limit(), 0.0),
  ]
  if r.kind is @moonui.MultilineEntry {
    let maxw = r.bounds.size.width - 2.0 * @canvas-common.TEXT_PAD
    let ls : Array[@canvas-common.VLine]? = Some(
      @canvas-common.wrap_lines(p, raw, size, maxw),
    ) catch {
      _ => None
    }
    return match ls {
      Some(l) => Some((l, raw))
      None => Some((one, raw))
    }
  }
  Some((one, raw))
}

///|
/// 光标所在可视行的 `[start, end)`（`T389` 的按行 Home/End）。
fn CanvasBackend::line_span_of(
  self : CanvasBackend,
  wi : Int32,
  r : CwRec,
  idx : Int32,
) -> (Int32, Int32)? {
  match self.lines_of(wi, r) {
    Some((ls, _)) => {
      let v = ls[@canvas-common.vline_of(ls, idx)]
      Some((v.start, v.end))
    }
    None => None
  }
}

///|
/// 上下移光标（`T389`）：按 **x 位置**对齐目标行——目标行里没有等宽的字符就
/// 夹到该行首/尾。顶到首行再按上、末行再按下就**不动**（与原生一致）。
fn CanvasBackend::step_line(
  self : CanvasBackend,
  wi : Int32,
  r : CwRec,
  dir : Int32,
) -> Int32? {
  match self.lines_of(wi, r) {
    Some((ls, text)) => {
      let p = match self.painter_of(wi) {
        Some(pp) => pp
        None => return None
      }
      let size = self.font_size_of(r)
      let i = @canvas-common.vline_of(ls, r.caret)
      // 量字失败就按 0 对齐（顶到行首），别把整次按键吃掉
      let x : Double = @canvas-common.line_x(p, text, ls[i], r.caret, size) catch {
        _ => 0.0
      }
      let j = i + dir
      if j < 0 || j >= ls.length() {
        return Some(r.caret)
      }
      // 同一列对齐：目标行里没有那一列就落最近的（`nearest_char` 平局取右，
      // 行尾那一列精确落回行尾，不会少一格）
      Some(
        @canvas-common.nearest_char(p, text, ls[j], size, x) catch {
          _ => r.caret
        },
      )
    }
    None => None
  }
}

///|
/// 光标跟着滚进视口（`T389`）：多行框文本锁在框内，光标跑到框外得把内容滚上来。
/// 只有多行记账有这条账，其余 kind 的 `scroll_y` 恒为 0。
fn CanvasBackend::scroll_follow(
  self : CanvasBackend,
  wi : Int32,
  h : @moonui.NativeHandle,
) -> Unit {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) =>
      if r.kind is @moonui.MultilineEntry {
        match self.lines_of(wi, r) {
          Some((ls, _)) => {
            let lh = self.font_size_of(r) * 1.4
            let view = r.bounds.size.height - 2.0
            r.scroll_y = @canvas-common.caret_scroll(
              ls,
              r.caret,
              r.scroll_y,
              lh,
              view,
            )
          }
          None => ()
        }
      }
    None => ()
  }
}

///|
/// 点击 y → 可视行下标（`T389`）：多行框按点击高度挑行，`scroll_y` 已经把内容
/// 往下顶过一截，得补回去。夹在 `[0, 行数-1]` 内。
fn CanvasBackend::line_at_y(
  self : CanvasBackend,
  r : CwRec,
  point : @moonui.LogicalPoint,
  off : @moonui.LogicalPoint,
  ls : Array[@canvas-common.VLine],
) -> Int32 {
  let lh = self.font_size_of(r) * 1.4
  if lh <= 0.0 {
    return 0
  }
  let rel = point.y -
    (r.bounds.origin.y + off.y) -
    @canvas-common.TOP_PAD +
    r.scroll_y
  let i = (rel / lh).floor().to_int()
  i.clamp(min=0, max=ls.length() - 1)
}

///|
/// 点击点 → 字符下标（`T389`）：多行先按 y 挑可视行、再在行内按 x 定位；其余
/// kind 就是行内的 `char_at_x`。`rel` 是相对文本左缘的 x，`shown` 是要量字的那
/// 条串（密码框传掩码后——下标与明文逐字符对应）。
fn CanvasBackend::seek_index(
  self : CanvasBackend,
  wi : Int32,
  r : CwRec,
  p : @native-common.CanvasPainter,
  shown : String,
  point : @moonui.LogicalPoint,
  off : @moonui.LogicalPoint,
  rel : Double,
) -> Int32 raise @moonui.UiError {
  let size = self.font_size_of(r)
  match self.lines_of(wi, r) {
    // 退化表（单条）只用于非多行记账，直接用 `char_at_x`
    Some((ls, _)) =>
      if r.kind is @moonui.MultilineEntry && ls.length() > 0 {
        @canvas-common.char_at(
          p,
          shown,
          ls[self.line_at_y(r, point, off, ls)],
          size,
          rel,
        )
      } else {
        char_at_x(p, shown, rel, size)
      }
    None => char_at_x(p, shown, rel, size)
  }
}
