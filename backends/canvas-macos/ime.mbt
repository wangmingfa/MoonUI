///|
/// 自绘后端的输入法镜像（`T375`）。
///
/// 自绘控件没有原生文本视图，输入法只在 first responder 实现 `NSTextInputClient`
/// 时才组合。native 半在窗口 contentView 上挂了一只隐形的 `NSTextView` 代理
/// （adapter.h 的「画布输入法代理」段）：组合、候选窗定位、字符插入都由 AppKit
/// 现成实现负责，这一层只做两件事——
///
/// 1. **镜像**：代理接管期间（`CwWin.ime`），文本/光标以代理为准写回记账，
///    撤销 `T374` 的裸键插入（`translate_key` 不再 `apply_edit`），否则一颗键
///    会插两次；
/// 2. **差分**：每圈读回「文本 / 光标 / 标记串」三份快照，与上一圈比较——文本
///    变推 `Input`，标记串空→非空推 `ImeStart` + `ImeCompose`、非空→变推
///    `ImeCompose`、非空→空推 `ImeEnd`。组合中的文本只画不报（`Input` 只在
///    上屏时补，与原生后端"组合中 `controlTextDidChange:` 不发"同一条语义）。
///
/// 首刀只接三只单行可编辑 kind；MultilineEntry 的跨行光标是另一刀。

///|
/// 本窗的窗口指针；句柄不在原生表里给 `None`（窗口刚销毁）。
fn CanvasBackend::ime_ptr(self : CanvasBackend, wi : Int32) -> Int64? {
  Some(
    @native-common.NativeBackend::window_ptr(
      self.inner,
      self.windows[wi].handle,
    ),
  ) catch {
    _ => None
  }
}

///|
/// 本窗的 DPI 缩放（物理像素 / 逻辑像素），非正值兜底 1。
fn CanvasBackend::ime_scale(
  self : CanvasBackend,
  wi : Int32,
) -> (Double, Double) {
  try {
    let s = @moonui.Backend::window_scale(self.inner, self.windows[wi].handle)
    (if s.x > 0.0 { s.x } else { 1.0 }, if s.y > 0.0 { s.y } else { 1.0 })
  } catch {
    _ => (1.0, 1.0)
  }
}

///|
/// 代理框的物理像素矩形（窗口客户区、左上原点），喂给
/// `canvas_ime_begin/move`。记账不在账上时给全零（调用方在此之前已判过账）。
fn CanvasBackend::ime_box_of(
  self : CanvasBackend,
  wi : Int32,
  h : @moonui.NativeHandle,
) -> (Int32, Int32, Int32, Int32) {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => {
      let off = self.scroll_offset(h)
      let (sx, sy) = self.ime_scale(wi)
      let x = ((r.bounds.origin.x + off.x) * sx + 0.5).to_int()
      let y = ((r.bounds.origin.y + off.y) * sy + 0.5).to_int()
      let w = (r.bounds.size.width * sx + 0.5).to_int()
      let hh = (r.bounds.size.height * sy + 0.5).to_int()
      (x, y, w, hh)
    }
    None => (0, 0, 0, 0)
  }
}

///|
/// 让代理接管这扇窗（`T375`）：先摆框、立 first responder，再把记账草稿写进
/// 代理。抢不到焦点（-4）就退回裸键编辑，不把整窗拖垮。
fn CanvasBackend::ime_begin(
  self : CanvasBackend,
  wi : Int32,
  h : @moonui.NativeHandle,
) -> Unit {
  if !self.ime_proxy {
    return
  }
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) =>
      if r.editable() && r.visible && r.enabled {
        match self.ime_ptr(wi) {
          Some(ptr) => {
            let (_, sy) = self.ime_scale(wi)
            let (x, y, w, hh) = self.ime_box_of(wi, h)
            let font_px = (self.font_size_of(r) * sy + 0.5).to_int()
            let rc = @native-common.canvas_ime_begin(ptr, x, y, w, hh, font_px)
            if rc == 0 {
              let text = r.edit_text()
              let caret = r.caret.clamp(min=0, max=r.edit_limit())
              @native-common.canvas_ime_set_state(ptr, text, caret)
              self.windows[wi].ime = true
              self.windows[wi].ime_text = text
              self.windows[wi].ime_marked = ""
              self.windows[wi].ime_target = Some(h)
              self.windows[wi].ime_pre = text
              self.windows[wi].ime_box = Some((x, y, w, hh))
            } else {
              self.windows[wi].ime = false
              self.windows[wi].ime_box = None
            }
          }
          None => ()
        }
      }
    None => ()
  }
}

///|
/// 让代理交还编辑：resign 并取消组合，代理本身留到窗口销毁。
fn CanvasBackend::ime_end(self : CanvasBackend, wi : Int32) -> Unit {
  if !self.windows[wi].ime {
    return
  }
  // 换焦时焦点已经指向新控件，未收尾的组合要报给旧记账（`ime_target`）。
  if self.windows[wi].ime_marked != "" {
    match self.windows[wi].ime_target {
      Some(t) => self.post(@moonui.ImeEnd(@moonui.EventTarget::of(t)))
      None => ()
    }
  }
  match self.ime_ptr(wi) {
    Some(ptr) => @native-common.canvas_ime_end(ptr)
    None => ()
  }
  self.windows[wi].ime = false
  self.windows[wi].ime_text = ""
  self.windows[wi].ime_marked = ""
  self.windows[wi].ime_target = None
  self.windows[wi].ime_pre = ""
  self.windows[wi].ime_box = None
}

///|
/// 一圈镜像（`T375`）。调用点在 `poll_event` 的开头（`sync_activation` 之后、
/// `flush_dirty` 之前）：上一圈由键/输入法引起的代理变化在这里变成事件，事件序
/// 仍是「上一圈 `KeyDown` → 本圈 `Input`/相位」，且不会插进 `translate_key`
/// 刚推的键事件之前。
fn CanvasBackend::ime_pump(self : CanvasBackend, wi : Int32) -> Unit {
  if !self.windows[wi].ime {
    return
  }
  // 自愈：焦点没了/不再是可编辑记账（销毁、隐藏、禁用、失键都在这一条收口）。
  let target = match self.focus_of(wi) {
    Some(h) => h
    None => {
      self.ime_end(wi)
      return
    }
  }
  let rec : CwRec? = Some(self.rec_of(target)) catch { _ => None }
  let r = match rec {
    Some(r) =>
      if r.editable() && r.enabled && r.visible {
        r
      } else {
        self.ime_end(wi)
        return
      }
    None => {
      self.ime_end(wi)
      return
    }
  }
  let ptr = match self.ime_ptr(wi) {
    Some(ptr) => ptr
    None => {
      self.ime_end(wi)
      return
    }
  }
  let text = @native-common.canvas_ime_text(ptr)
  let caret = @native-common.canvas_ime_caret(ptr)
  let marked = @native-common.canvas_ime_marked(ptr)
  let prev_marked = self.windows[wi].ime_marked
  let mut dirty = false
  // 组合相位：先报相位，再决定文本要不要变成 `Input`。相位挂 `ime_target`
  // 而不是当前焦点——Tab 换焦后旧控件的 `ImeEnd` 仍要报给旧控件。
  if marked != prev_marked {
    let phase_target = match self.windows[wi].ime_target {
      Some(t) => t
      None => target
    }
    let t = @moonui.EventTarget::of(phase_target)
    if prev_marked == "" && marked != "" {
      self.post(@moonui.ImeStart(t))
      self.post(@moonui.ImeCompose(t, marked))
      self.windows[wi].ime_target = Some(target)
      // 组合开始前的文本：取消组合时代理会退回它，相同就不算输入。
      self.windows[wi].ime_pre = self.windows[wi].ime_text
    } else if marked != "" {
      self.post(@moonui.ImeCompose(t, marked))
    } else {
      self.post(@moonui.ImeEnd(t))
    }
    self.windows[wi].ime_marked = marked
  }
  let composing = marked != ""
  if text != self.windows[wi].ime_text {
    r.text = text
    // 组合替换整段文本，不保留选区（`T387`）：组合中的光标是组合串的编辑点，
    // 不是选区活动端——否则组合一开，上一颗退格留下的选区会盖住组合串。
    r.sel = r.caret
    dirty = true
    // `Input` 只在上屏时补：组合中的文本只画不报（与原生"组合中不发文本变化"
    // 同一条语义）；组合刚结束时的上屏全文在这里补。
    if !composing && text != self.windows[wi].ime_pre {
      self.post(@moonui.Input(@moonui.EventTarget::of(target), text))
      self.windows[wi].ime_pre = text
    }
  }
  let limit = r.edit_limit()
  let c = caret.clamp(min=0, max=limit)
  if c != r.caret {
    r.caret = c
    r.sel = c
    dirty = true
  }
  self.windows[wi].ime_text = text
  // 框跟控件走（滚动/布局变化才重摆），候选窗才不会停在旧位置。
  let box = self.ime_box_of(wi, target)
  if self.windows[wi].ime_box != Some(box) {
    let (x, y, w, hh) = box
    let _ = @native-common.canvas_ime_move(ptr, x, y, w, hh)
    self.windows[wi].ime_box = Some(box)
  }
  if dirty {
    self.windows[wi].dirty = true
    // 组合/上屏都在动光标位置，相位重开（`T379`）：正在打字时光标不闪灭。
    self.caret_poke()
  }
}

///|
/// 所有窗都泵一遍（`poll_event` 开头调用）。
fn CanvasBackend::ime_pump_all(self : CanvasBackend) -> Unit {
  for wi = 0; wi < self.windows.length(); wi = wi + 1 {
    self.ime_pump(wi)
  }
}
