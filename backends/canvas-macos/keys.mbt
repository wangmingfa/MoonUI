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
  // firstResponder），再移动焦点、补 Blur/Focus。**只在按下时挪**：抬起也
  // 挪一次会让一下 Tab 走过两只控件（`T380` 真窗口反馈"一次跳两个"）。
  if kp.key == "Tab" {
    self.post_key(self.key_event(target, kp, down))
    if down {
      match self.focus_step(wi, current, kp.shift) {
        Some(next) => self.move_focus(wi, Some(next))
        None => ()
      }
    }
    return true
  }
  match current {
    Some(h) => {
      // 键事件照旧派给焦点（订阅继续看得到）；编辑（`T374`）在键之后落，
      // `Input` 因此排在 `KeyDown` 后——与原生"键派发 → 文本变化回显"同序。
      // IME 代理接管期间（`T375`）**文本编辑键**（字符/退格/前删/粘贴/剪切）
      // 由 first responder 的隐形 NSTextView 自己做，这里再 `apply_edit` 会
      // 一颗键插两次；但**导航/选区键**（方向键/Home/End/Shift/⌘A/⌘C）仍归
      // 本层——代理只镜像文本与插入点，不管理选区账（`T393`：真窗里 IME 接管
      // 时 Shift+方向键与拖选选不中，根因就是把导航键也交给代理、且 ime_pump
      // 每圈把选区折叠回插入点）。
      self.post_key(self.key_event(h, kp, down))
      if down {
        self.apply_edit(wi, h, kp, self.windows[wi].ime)
      }
      true
    }
    None => false
  }
}

///|
/// 一颗按下键落到可编辑记账上（`T374` 第一刀 + `T387` 第二刀）：字符插入、
/// 退格、前删（Delete）、左/右移光标、Home/End、剪贴板、选区。
/// 只处理 ASCII 可打印键与 `Space`（键名归一化在 adapter_native.m，Shift 的
/// 字母在键名里是小写，靠 `kp.shift` 补大写）；带 ctrl/alt/meta 的组合键不
/// 插入，**⌘/Ctrl+C/V/X** 例外——那是剪贴板（文本输入框聚焦时先吃复制粘贴，
/// 与原生输入框一致），其余组合留给应用快捷键。文本真的变了才补 `Input`，
/// 光标/选区移动只标脏。
///
/// 选区账：`caret` 是活动端、`sel` 是锚点端。无 shift 的移动把两者折回同一点
/// （折叠选区）；Shift+方向键 / Shift+Home / Shift+End 只动活动端（从当前点
/// 扩出选区）。插入/退格/前删在存在选区时作用于整段 `[lo,hi)`。
fn CanvasBackend::apply_edit(
  self : CanvasBackend,
  wi : Int32,
  h : @moonui.NativeHandle,
  kp : @moonui.KeyPress,
  ime : Bool,
) -> Unit {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => {
      if !r.editable() || !r.enabled {
        return
      }
      if kp.alt {
        return // Alt 组合一律留给应用
      }
      // IME 代理接管期间，**文本编辑键**交给代理（否则双插，`T375`）；
      // **导航/选区键**（方向/Home/End/Shift/⌘A/⌘C）仍在本层——代理只镜像
      // 文本与插入点，不管理选区账（`T393`）。
      if ime {
        if kp.key == "Space" || kp.key.length() == 1 {
          return
        }
        if kp.key == "Backspace" || kp.key == "Delete" {
          return
        }
        if kp.meta || kp.ctrl {
          if kp.key == "v" || kp.key == "V" || kp.key == "x" || kp.key == "X" {
            return
          }
        }
      }
      let limit = r.edit_limit()
      let caret = r.caret.clamp(min=0, max=limit)
      let sel = r.sel.clamp(min=0, max=limit)
      let lo = if sel < caret { sel } else { caret }
      let hi = if sel > caret { sel } else { caret }
      // 剪贴板（`T387`）+ 全选（`T389`）：mac 上 ⌘ 是主、同时认 Ctrl（键名一致，
      // 兼容未来 Windows canvas 与用户习惯）。非 c/v/x/a 的组合一律丢给应用。
      if kp.meta || kp.ctrl {
        if !kp.shift {
          if kp.key == "c" || kp.key == "C" {
            self.copy_selection(h, lo, hi)
            return
          }
          if kp.key == "v" || kp.key == "V" {
            self.paste_at(h, lo, hi)
            return
          }
          if kp.key == "x" || kp.key == "X" {
            self.cut_selection(h, lo, hi)
            return
          }
          // ⌘A 全选（`T389`）：锚点落最前、活动端落末尾，选区横跨整串（多行也
          // 包含 `\n`）。之后 ⌘C 复制整段、插入替换整段。
          if kp.key == "a" || kp.key == "A" {
            r.sel = 0
            r.caret = limit
            self.mark_dirty()
            self.caret_poke()
            self.scroll_follow(wi, h)
            return
          }
        }
        return
      }
      // Home / End（`T387`，`T389` 起按**可视行**）：换行之后 Home 到的是当前
      // 这一行（断行后的那半行）的首，与原生一致。无 shift 折叠；有 shift 只动
      // 活动端（扩出选区，锚点留在原活动端）。
      if kp.key == "Home" || kp.key == "End" {
        let to = match self.line_span_of(wi, r, r.caret) {
          Some(sp) => if kp.key == "Home" { sp.0 } else { sp.1 }
          None => if kp.key == "Home" { 0 } else { limit }
        }
        if kp.shift {
          r.caret = to
        } else {
          r.caret = to
          r.sel = to
        }
        self.mark_dirty()
        self.caret_poke()
        self.scroll_follow(wi, h)
        return
      }
      // Up / Down（`T389`）：多行框上下移光标，按 x 位置对齐目标行。无 shift 折叠
      // 选区；有 shift 只动活动端。
      if kp.key == "Up" || kp.key == "Down" {
        let dir = if kp.key == "Up" { -1 } else { 1 }
        match self.step_line(wi, r, dir) {
          Some(to) => {
            r.caret = to
            if !kp.shift {
              r.sel = to
            }
          }
          None => ()
        }
        self.mark_dirty()
        self.caret_poke()
        self.scroll_follow(wi, h)
        return
      }
      if kp.key == "Delete" {
        self.delete_forward(h, caret, lo, hi)
        self.scroll_follow(wi, h)
        return
      }
      if kp.key == "Backspace" {
        // 多行框光标在行首时删掉前一个 `\n`、两行并成一行（`T389`）：
        // `s[0:caret-1] + s[caret:]` 天然把两行接上，光标落在接缝处。
        self.delete_backward(h, caret, lo, hi)
        self.scroll_follow(wi, h)
        return
      }
      if kp.key == "Left" {
        if kp.shift {
          r.caret = if caret > 0 { caret - 1 } else { 0 }
        } else if lo != hi {
          r.caret = lo
          r.sel = lo
        } else {
          r.caret = if caret > 0 { caret - 1 } else { 0 }
          r.sel = r.caret
        }
        self.mark_dirty()
        self.caret_poke()
        self.scroll_follow(wi, h)
        return
      }
      if kp.key == "Right" {
        if kp.shift {
          r.caret = if caret < limit { caret + 1 } else { limit }
        } else if lo != hi {
          r.caret = hi
          r.sel = hi
        } else {
          r.caret = if caret < limit { caret + 1 } else { limit }
          r.sel = r.caret
        }
        self.mark_dirty()
        self.caret_poke()
        self.scroll_follow(wi, h)
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
      self.insert_at(h, lo, hi, ins)
      self.scroll_follow(wi, h)
    }
    None => ()
  }
}

///|
/// 标脏 + 重开光标相位 + 补一条 `Input`（文本真的变了的三件套）。helper 们
/// 共用，免得每处编辑重复这三行。
fn CanvasBackend::dirty_poke_input(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  text : String,
) -> Unit {
  self.mark_dirty()
  self.caret_poke()
  self.post(@moonui.Input(@moonui.EventTarget::of(h), text))
}

///|
/// 退格（`T374` 已有 + `T387` 选区）：有选区删整段 `[lo,hi)`，无选区删活动端
/// 左侧一字符。删完光标/选区落在 lo。
fn CanvasBackend::delete_backward(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  caret : Int32,
  lo : Int32,
  hi : Int32,
) -> Unit {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) =>
      if lo != hi {
        let s = r.edit_text()
        r.text = s[0:lo].to_owned() + s[hi:].to_owned()
        r.caret = lo
        r.sel = lo
        self.dirty_poke_input(h, r.text)
      } else if caret > 0 {
        let s = r.edit_text()
        r.text = s[0:caret - 1].to_owned() + s[caret:].to_owned()
        r.caret = caret - 1
        r.sel = r.caret
        self.dirty_poke_input(h, r.text)
      }
    None => ()
  }
}

///|
/// 前删（`T387`）：有选区删整段 `[lo,hi)`，无选区删活动端右侧一字符。
fn CanvasBackend::delete_forward(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  caret : Int32,
  lo : Int32,
  hi : Int32,
) -> Unit {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) =>
      if lo != hi {
        let s = r.edit_text()
        r.text = s[0:lo].to_owned() + s[hi:].to_owned()
        r.caret = lo
        r.sel = lo
        self.dirty_poke_input(h, r.text)
      } else if caret < r.edit_limit() {
        let s = r.edit_text()
        r.text = s[0:caret].to_owned() + s[caret + 1:].to_owned()
        r.caret = caret
        r.sel = caret
        self.dirty_poke_input(h, r.text)
      }
    None => ()
  }
}

///|
/// 插入 `ins`（`T374` 已有 + `T387` 选区替换）：有选区时替换整段 `[lo,hi)`，
/// 无选区时在活动端插入。插完光标落在插入串之后、选区折叠。
fn CanvasBackend::insert_at(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  lo : Int32,
  hi : Int32,
  ins : String,
) -> Unit {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => {
      let limit = r.edit_limit()
      let lo = lo.clamp(min=0, max=limit)
      let hi = hi.clamp(min=0, max=limit)
      let s = r.edit_text()
      let head = s[0:lo].to_owned()
      let mid = s[hi:limit].to_owned()
      let tail = s[limit:].to_owned()
      r.text = head + ins + mid + tail
      r.caret = lo + ins.length()
      r.sel = r.caret
      self.dirty_poke_input(h, r.text)
    }
    None => ()
  }
}

///|
/// 复制（`T387`）：有选区把 `[lo,hi)` 写进剪贴板；无选区不写也不产事件
/// （与原生输入框"没选中按 ⌘C 无事发生"一致）。
fn CanvasBackend::copy_selection(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  lo : Int32,
  hi : Int32,
) -> Unit {
  if lo >= hi {
    return
  }
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => {
      let txt = r.edit_text()
      let piece = txt[lo:hi].to_owned()
      self.set_clip(piece)
    }
    None => ()
  }
}

///|
/// 剪切（`T387`）：先复制再删选区（删完补 `Input`）。
fn CanvasBackend::cut_selection(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  lo : Int32,
  hi : Int32,
) -> Unit {
  if lo >= hi {
    return
  }
  self.copy_selection(h, lo, hi)
  self.delete_backward(h, 0, lo, hi)
}

///|
/// 粘贴（`T387`）：把剪贴板串替换进 `[lo,hi)`（无选区时在活动端插入）。
/// 剪贴板空/读失败不动。
fn CanvasBackend::paste_at(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  lo : Int32,
  hi : Int32,
) -> Unit {
  let piece = self.get_clip()
  match piece {
    Some(s) => {
      if s == "" {
        return
      }
      self.insert_at(h, lo, hi, s)
    }
    None => ()
  }
}

///|
/// 剪贴板写（`T387`）：测试探针在时写探针（无头环境没有真系统剪贴板），
/// 否则走 inner 的原生剪贴板。失败静默（自绘输入框的复制粘贴不因剪贴板
/// 不可用而崩——与原生半的 try 同一条纪律）。
fn CanvasBackend::set_clip(self : CanvasBackend, s : String) -> Unit {
  if self.clip_probe is Some(_) {
    self.clip_probe = Some(s)
  } else {
    @moonui.Backend::set_clipboard_text(self, s) catch {
      _ => ()
    }
  }
}

///|
/// 剪贴板读（`T387`）：同上，探针优先；原生读失败报 None（粘贴无内容）。
fn CanvasBackend::get_clip(self : CanvasBackend) -> String? {
  match self.clip_probe {
    Some(s) => Some(s)
    None => @moonui.Backend::clipboard_text(self) catch { _ => None }
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
  // 焦点真转移就结束拖选（`T388`）：Tab 换焦、点空白、点另一只控件——按住
  // 的手还按着，但没有人在拖了。
  self.drag = None
  match old {
    Some(h) => self.post(@moonui.Blur(@moonui.EventTarget::of(h)))
    None => ()
  }
  match next {
    Some(h) => self.post(@moonui.Focus(@moonui.EventTarget::of(h)))
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
            // 选区锚点一起落末尾（`T387`）：进入即无选区，Shift 从末尾起扩。
            r.sel = r.edit_limit()
            r.caret = r.sel
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
  // 光标相位重开（`T379`）：点进来/切走都先亮，别让人等着看不见的光标。
  self.caret_poke()
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
