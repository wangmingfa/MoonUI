///|
/// 自绘后端的键盘翻译（`T369`）：与 `mouse.mbt` 同一条"认控件只能发生在记账
/// 侧"的思路。自绘控件没有原生对象，C 的键盘监听只能把 `KeyDown/KeyUp` 报到
/// 窗口（first responder 落回 contentView），这一层按焦点账改写 target 再交
/// Core。
///
/// 焦点账两半：`set_focus_chain` 存 Core 推来的声明序（`CwWin.chain`），
/// `set_custom_focusable` 标哪些面要键盘（`CwRec.focusable`）。点击 focusable
/// 记账取焦（`mouse.mbt`），Tab / Shift+Tab 在链里循环；没有焦点时键照旧落回
/// 窗口，窗口级订阅不受影响。

///|
/// 这颗键要不要按焦点改写。返回 `true` = 已入队（调用方丢弃 inner 来的原
/// 事件）；`false` = 没人接，键继续以窗口为 target。
///
/// `pub` 是测试口（与 `translate_mouse` 同形）——参数化本体，C 读取壳在
/// `poll_event` 里接。
pub fn CanvasBackend::translate_key(
  self : CanvasBackend,
  window : @moonui.NativeHandle,
  kp : @moonui.KeyPress,
  down : Bool,
) -> Bool {
  let wi = match self.win_idx(window) {
    Some(i) => i
    None => return false
  }
  let current = self.focus_of(wi)
  let target = match current {
    Some(h) => h
    None => window
  }
  // Tab：先按**旧**焦点报这颗键（mac 的监听在 AppKit 挪焦点之前读到
  // firstResponder），再移动焦点、补 Blur/Focus。
  if kp.key == "Tab" {
    self.queue.push(self.key_event(target, kp, down))
    match self.focus_step(wi, current, kp.shift) {
      Some(next) => self.move_focus(wi, Some(next))
      None => ()
    }
    return true
  }
  match current {
    Some(h) => {
      // 键事件照旧派给焦点（订阅继续看得到）；编辑（`T374`）在键之后落，
      // `Input` 因此排在 `KeyDown` 后——与原生"键派发 → 文本变化回显"同序。
      // 代理接管期间（`T375`）编辑由 first responder 的隐形 NSTextView 自己做，
      // 这里再 `apply_edit` 会一颗键插两次。
      self.queue.push(self.key_event(h, kp, down))
      if down && !self.windows[wi].ime {
        self.apply_edit(h, kp)
      }
      true
    }
    None => false
  }
}

///|
/// 一颗按下键落到可编辑记账上（`T374`）：字符插入、退格、左/右移光标。
/// 只处理 ASCII 可打印键与 `Space`（键名归一化在 adapter_native.m，Shift 的
/// 字母在键名里是小写，靠 `kp.shift` 补大写）；带 ctrl/alt/meta 的组合键不插入，
/// 留给应用快捷键。文本真的变了才补 `Input`，光标移动只标脏。
fn CanvasBackend::apply_edit(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  kp : @moonui.KeyPress,
) -> Unit {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => {
      if !r.editable() || !r.enabled {
        return
      }
      if kp.ctrl || kp.alt || kp.meta {
        return
      }
      let limit = r.edit_limit()
      let caret = r.caret.clamp(min=0, max=limit)
      if kp.key == "Backspace" {
        if caret > 0 {
          let s = r.edit_text()
          r.text = s[0:caret - 1].to_owned() + s[caret:].to_owned()
          r.caret = caret - 1
          self.mark_dirty()
          self.queue.push(@moonui.Input(@moonui.EventTarget::of(h), r.text))
        }
        return
      }
      if kp.key == "Left" {
        r.caret = if caret > 0 { caret - 1 } else { 0 }
        self.mark_dirty()
        return
      }
      if kp.key == "Right" {
        r.caret = if caret < limit { caret + 1 } else { limit }
        self.mark_dirty()
        return
      }
      let ins = if kp.key == "Space" {
        " "
      } else if kp.key.length() == 1 {
        let c = kp.key.get_char(0)
        match c {
          Some(ch) =>
            if kp.shift && ch >= 'a' && ch <= 'z' {
              String::make(1, (ch.to_int() - 32).unsafe_to_char())
            } else {
              kp.key
            }
          None => ""
        }
      } else {
        ""
      }
      if ins == "" {
        return
      }
      let s = r.edit_text()
      let head = s[0:caret].to_owned()
      let mid = s[caret:limit].to_owned()
      let tail = s[limit:].to_owned()
      r.text = head + ins + mid + tail
      r.caret = caret + 1
      self.mark_dirty()
      self.queue.push(@moonui.Input(@moonui.EventTarget::of(h), r.text))
    }
    None => ()
  }
}

///|
/// 事件 target → 本后端的窗口句柄。inner 报来的键事件只可能落在窗口上（自绘
/// 控件没有原生对象），这里只认自己的窗；不认识的 target 原样放行。
fn CanvasBackend::window_of_target(
  self : CanvasBackend,
  t : @moonui.EventTarget,
) -> @moonui.NativeHandle? {
  for w in self.windows {
    if w.handle.id == t.id && w.handle.generation == t.generation {
      return Some(w.handle)
    }
  }
  None
}

///|
/// 造一颗键事件（target 已是路由后的句柄）。
fn CanvasBackend::key_event(
  _self : CanvasBackend,
  target : @moonui.NativeHandle,
  kp : @moonui.KeyPress,
  down : Bool,
) -> @moonui.Event {
  if down {
    @moonui.KeyDown(@moonui.EventTarget::of(target), kp)
  } else {
    @moonui.KeyUp(@moonui.EventTarget::of(target), kp)
  }
}

///|
/// 这只记账现在能不能拿焦点：还在账上、可见且启用，并且要么显式声明了
/// focusable（`Widget::custom`），要么是可编辑四类（`T374`：自绘输入框没有
/// 原生的 first responder，不默认可聚焦就永远打不了字）。每条都真跑——记账
/// 销毁后句柄表会复用槽位，只比句柄不校验属性会把键投给一只不该收的控件。
fn CanvasBackend::focusable_of(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
) -> Bool {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => (r.focusable || r.editable()) && r.visible && r.enabled
    None => false
  }
}

///|
/// 窗口当前的焦点。记在窗上的句柄失效（销毁 / 隐藏 / 禁用 / 收回 focusable）
/// 就如实报 `None`——这是读账，不是状态迁移，不顺手发 `Blur`。
fn CanvasBackend::focus_of(
  self : CanvasBackend,
  wi : Int32,
) -> @moonui.NativeHandle? {
  match self.windows[wi].focus {
    Some(h) => if self.focusable_of(h) { Some(h) } else { None }
    None => None
  }
}

///|
/// 焦点链里的下一只可聚焦记账（循环）。`cur` 不在链上（或为空）时按方向从
/// 头/尾开始找；整条链没有可聚焦项就 `None`（不动焦点）。
fn CanvasBackend::focus_step(
  self : CanvasBackend,
  wi : Int32,
  cur : @moonui.NativeHandle?,
  backward : Bool,
) -> @moonui.NativeHandle? {
  let chain = self.windows[wi].chain
  let n = chain.length()
  if n == 0 {
    return None
  }
  let mut at = -1
  match cur {
    Some(h) =>
      for i = 0; i < n; i = i + 1 {
        if chain[i] == h {
          at = i
          break
        }
      }
    None => ()
  }
  // 没有当前焦点：向前从链头（-1 之后第一只）开始，向后从链尾开始。
  if at < 0 {
    at = if backward { 0 } else { n - 1 }
  }
  for step = 1; step <= n; step = step + 1 {
    let i = if backward {
      let k = at - step
      if k < 0 {
        k + n
      } else {
        k
      }
    } else {
      let k = at + step
      if k >= n {
        k - n
      } else {
        k
      }
    }
    if self.focusable_of(chain[i]) {
      return Some(chain[i])
    }
  }
  None
}

///|
/// 换焦点并补事件：先 `Blur` 后 `Focus`（与原生后端的 `refresh_focus` 同一条
/// 顺序）。同值不动、不产事件。
fn CanvasBackend::move_focus(
  self : CanvasBackend,
  wi : Int32,
  next : @moonui.NativeHandle?,
) -> Unit {
  let old = self.windows[wi].focus
  if old == next {
    return
  }
  match old {
    Some(h) => self.queue.push(@moonui.Blur(@moonui.EventTarget::of(h)))
    None => ()
  }
  match next {
    Some(h) => self.queue.push(@moonui.Focus(@moonui.EventTarget::of(h)))
    None => ()
  }
  self.windows[wi].focus = next
  // 焦点进入可编辑记账（`T374`）：Spinbox 先起稿，光标落到可编辑区间末尾
  // （原生输入框点进去也是"接在已有文本后面"）。离开不动旧光标——再点回来
  // 会重新落末尾。
  match next {
    Some(hh) => {
      let rec : CwRec? = Some(self.rec_of(hh)) catch { _ => None }
      match rec {
        Some(r) =>
          if r.editable() {
            r.text = r.edit_text()
            r.caret = r.edit_limit()
          }
        None => ()
      }
    }
    None => ()
  }
  // 输入法代理（`T375`）：焦点离开就 resign（组合就地取消、回显留给下一圈
  // `ime_pump`），落到可编辑记账才重新立起。先 end 再 begin，Tab 从一只输入框
  // 换到另一只时代理随之改绑，不会把组合串带进新控件。
  self.ime_end(wi)
  match next {
    Some(hh) => self.ime_begin(wi, hh)
    None => ()
  }
  // 焦点环（`T370`）是画账的一部分：焦点变了整窗标脏，环随下一帧出现/消失。
  self.windows[wi].dirty = true
}

///|
/// 键窗状态同步（`T371`）：画布壳不知道 AppKit 的 keyWindow 变化，每圈向
/// 原生后端问一次。失键（切到别的应用/别的窗）→ 清焦点、补 `Blur`；重新成键
/// 且没有有效焦点 → 首焦点落回链里第一只可聚焦的记账（原生后端把 first
/// responder 交给默认控件的对应物）。两态迁移都走 `move_focus`，脏位与
/// `Blur/Focus` 随之处理。
///
/// 失键的清理要等下一圈 `poll_event`——此刻没有事件叫醒我们时不重绘，环会留
/// 在旧帧上；窗口本身已不是键窗，视觉上不可见，如实记这条边界。
fn CanvasBackend::sync_activation(self : CanvasBackend) -> Unit {
  for wi = 0; wi < self.windows.length(); wi = wi + 1 {
    let probe = match self.key_probe {
      Some(v) => v
      None =>
        @native-common.native_window_is_key(self.windows[wi].handle) catch {
          _ => -1
        }
    }
    if probe < 0 {
      continue // 句柄已不在原生表里：这扇窗没有键状态可谈
    }
    let key = probe == 1
    let was = self.windows[wi].was_key
    self.windows[wi].was_key = key
    if key == was {
      continue
    }
    if key {
      // 成键：没有有效焦点才落首焦点——点击/Tab 取过的焦点不动。
      match self.focus_of(wi) {
        Some(_) => ()
        None =>
          match self.focus_step(wi, None, false) {
            Some(h) => self.move_focus(wi, Some(h))
            None => ()
          }
      }
    } else {
      // 失键：焦点让回窗口，后续键事件自然回到窗口级订阅。
      self.move_focus(wi, None)
    }
  }
}
