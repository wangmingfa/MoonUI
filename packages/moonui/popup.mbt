///|
/// 浮层（`T359`）。
///
/// 浮层是一只 **owned 无边框窗**，里面装一棵普通的 Widget 内容树——不是 HUD
/// 那种只画文本的画布（`T343`），也不是原生 ComboBox 由系统弹的下拉（`Widget::
/// combobox`）。之所以把浮层做成"一只特殊角色的 Window"而不是另起一套第二棵树：
/// Core 已有的事件路由（`App::dispatch_round` 按 target 找窗口/控件）、重绘账
/// （`Widget::repaint` → `DrawList` → `Backend::draw_custom`）、焦点链
/// （`set_focus_chain`）、z 序（`set_paint_order`）对一只独立窗口的内容树**全都成立**——
/// `App.windows` 本来就能装多只窗。浮层缺的只是四件窗口本身不管的语义：
///
/// 1. **owner 锚定**：建窗时把 owner 句柄交给后端（`create_popup_window`），
///    系统负责"在 owner 之上 / owner 最小化一起隐藏 / 切走被盖住"；
/// 2. **点外部关闭**：一次 MouseDown 若 target 不在任何开的浮层树里，关掉栈顶；
/// 3. **Esc 关闭**：Escape 且栈非空时关掉栈顶，并吞掉那条按键（不再喂底层控件）；
/// 4. **关闭通知**：`Popup::on_close` 在三条关闭路径上都触发——控件靠它复位自
///    己"开着"的账（不复位就再也开不出来），也靠 `close_cause` 分辨"是不是被
///    我自己那一下点关的"；
/// 5. **焦点**：`App` 有一份焦点账（`App.focus_target`，只在 `dispatch_round`
///    的派发起点翻一次）。开窗时快照成 `Popup.return_focus`，关窗最后一步按它
///    派 `Focus` 归还；`App::focus_popup` 负责"交给内容树里第一个可聚焦控件"。
///    边界见 `App.focus_target` 段注——账在 Core，原生 first responder 没被改。
///
/// 这四件都在 Core，不碰平台 ABI 的摆位细节——逻辑像素坐标、锚点算法由调用方
/// （应用/控件）算好后 `Window::set_position`，与 `T354` HUD 的"Core 不定坐标"
/// 同一条纪律。

///|
/// 一只浮层。包装一只已经由 `create_popup_window` 建好的 `Window`，所以浮层
/// 内容树就是一个普通窗口的内容树——`set_content` / `repaint` / `find_widget`
/// 一路复用，没有第二套机制。
pub struct Popup[B] {
  window : Window[B]
  /// 宿主窗口的原生句柄。归属语义交给后端，Core 只留着做焦点归还与判据。
  owner : NativeHandle
  /// 浮层的逻辑像素尺寸（建窗时就定，与 `Window::size` 同源）。
  size : LogicalSize
  /// 关闭回调。**显式 `close_popup`、Esc、点外部**三条路都走
  /// `App::close_popup`，所以都会触发它——控件靠它在 Core 关窗后复位自己
  /// 那份"开着"的账（不复位就再也开不出来）。字段名带 `hook` 是为了不和方法
  /// `Popup::on_close` 同名。
  mut close_hook : (() -> Unit raise UiError)?
  /// 这次关闭是被哪条输入的 target 触发的。守卫在关窗前置入，`close_popup`
  /// 调完回调后清空（显式关闭因此读到 `None`）。
  ///
  /// 用途：下拉的触发器被点中时，Core 在 MouseDown 就关掉浮层、MouseUp 又
  /// 落到触发器上——不区分成因的话会立刻重开，用户看到的是"点不掉"。
  /// 控件在关闭回调里比对 `close_cause` 与自己的 target，相同就吃掉这一次
  /// 抬起，才是真 toggle。
  mut close_cause : EventTarget?
  /// 开这只浮层时焦点在谁身上（`App.focus_target` 的快照）。关窗时按它派回
  /// `Focus`——这就是"焦点归还"的全部实现，不需要调用方再记一份。
  return_focus : EventTarget?
}

///|
/// 建一只浮层并登记进 `App` 的浮层栈。窗口本身也进 `App.windows`——这样事件
/// 路由、重排、present 全部走既有路径，不需要为浮层开第二条循环。
///
/// 建好**不自动 show**：调用方先 `set_content`（内容树要在显示前装好），再
/// `show`。owner 必须是本应用登记过的活窗——真后端对失效 owner 返回 0 由
/// FFI 转成 `OperationFailed`，Mock 抛 `InvalidHandle`。
pub fn[B : Backend] App::open_popup(
  self : App[B],
  owner : Window[B],
  size : LogicalSize,
) -> Popup[B] raise UiError {
  let owner_handle = owner.handle()
  let backend = self.backend()
  let handle = Backend::create_popup_window(backend, owner_handle, size)
  let win = Window::popup(backend, handle, size)
  win.refresh_style_base(self.style_base())
  win.refresh_live_default(self.live_redraw)
  self.windows.push(win)
  let popup = Popup::{
    window: win,
    owner: owner_handle,
    size,
    close_hook: None,
    close_cause: None,
    return_focus: self.focus_target,
  }
  self.popups.push(popup)
  popup
}

///|
/// 当下拿到焦点的 target（`None` = 没有）。读的就是 `dispatch_round` 在派发
/// 起点翻的那份账，不是另存一份。
pub fn[B] App::focused_target(self : App[B]) -> EventTarget? {
  self.focus_target
}

///|
/// 把焦点交给 `target`（`None` = 清空）：先给旧的派 `Blur`，再给新的派
/// `Focus`，账由派发起点翻（见 `App.focus_target` 段注）。与当下相同则一次
/// 事件都不发。
///
/// 边界：这是 Core 的皮肤/路由账，不改原生 first responder——三端没有那个
/// ABI（只有读的 `moonui_native_focused_control`）。所以"把焦点交给浮层里
/// 第一个可聚焦控件"在原生层只表现为键盘事件仍归既有的 first responder，
/// 皮肤与观察者按这份账走。
pub fn[B : Backend] App::set_focus(
  self : App[B],
  target : EventTarget?,
) -> Unit raise UiError {
  let same = match (self.focus_target, target) {
    (None, None) => true
    (Some(a), Some(b)) => a == b
    _ => false
  }
  if same {
    return
  }
  match self.focus_target {
    Some(t) => {
      let _ = self.dispatch(Blur(t))
    }
    None => ()
  }
  match target {
    Some(t) => {
      let _ = self.dispatch(Focus(t))
    }
    None => ()
  }
}

///|
/// 这次关闭是由哪条输入的 target 触发的（显式 `close_popup` 为 `None`）。
/// 控件在自己不是"被点中的那个"时据此判断要不要吃掉随后的抬起事件。
pub fn[B] Popup::close_cause(self : Popup[B]) -> EventTarget? {
  self.close_cause
}

///|
/// 设浮层关闭回调。三条关闭路径（显式 `close_popup` / Esc / 点外部）都经
/// `App::close_popup` 收口，因此都会走到。只调一次：`close_popup` 在调用前
/// 先把回调摘空，回调里再 `close_popup` 也因摘栈幂等直接返回。
pub fn[B] Popup::on_close(
  self : Popup[B],
  f : () -> Unit raise UiError,
) -> Unit {
  self.close_hook = Some(f)
}

///|
/// 浮层包装的窗口。拿到它就能 `set_content` / `set_position` / `show`——
/// 与操作普通窗口一字不差。
pub fn[B] Popup::window(self : Popup[B]) -> Window[B] {
  self.window
}

///|
/// 浮层归属的 owner 原生句柄。
pub fn[B] Popup::owner(self : Popup[B]) -> NativeHandle {
  self.owner
}

///|
/// 浮层尺寸（逻辑像素）。
pub fn[B] Popup::size(self : Popup[B]) -> LogicalSize {
  self.size
}

///|
/// 把焦点交给浮层内容树里**声明序第一个**可聚焦控件（`T359` ①）。内容还没
/// 装（`None`）或树里没有可聚焦控件时返回 `false`，焦点原地不动——自绘下拉
/// 的选项列表就是这种（`focusable=false`，键盘导航本该留在触发器上）。
///
/// 调用时机：`set_content` 之后、`show` 前后皆可（Core 只改账，不看窗口可
/// 见性）。要先装内容再调——空树的答案永远是 `false`。
pub fn[B : Backend] App::focus_popup(
  self : App[B],
  popup : Popup[B],
) -> Bool raise UiError {
  match popup.window.content() {
    Some(root) =>
      match root.first_focusable() {
        Some(w) => {
          self.set_focus(Some(w.target()))
          true
        }
        None => false
      }
    None => false
  }
}

///|
/// 关掉一只浮层：先从栈里摘（幂等——重复关不再动窗口），再走 `Window::close`
/// 的既有释放路径（先关内容树、后销毁原生窗），最后触发 `Popup::on_close`
/// 回调，并把焦点还给开窗时的那个人（`Popup.return_focus`）。
pub fn[B : Backend] App::close_popup(
  self : App[B],
  popup : Popup[B],
) -> Unit raise UiError {
  let mut found = false
  for p in self.popups {
    if p.window.handle() == popup.window.handle() {
      found = true
    }
  }
  if !found {
    return
  }
  self.popups = self.popups.filter(fn(p) {
    p.window.handle() != popup.window.handle()
  })
  if !popup.window.is_closed() {
    popup.window.close()
  }
  // 先摘栈、再关窗、最后回调：回调里若又调 `close_popup`，摘栈那步已让
  // `found` 为假而直接返回，不会二次进这里。回调在关闭前摘空，保证只调一次。
  let hook = popup.close_hook
  popup.close_hook = None
  match hook {
    Some(f) => f()
    None => ()
  }
  // 回调读完成因再清：显式关闭读到 `None`，守卫那条读到被点中的 target。
  popup.close_cause = None
  // 焦点归还放最后：回调可能已经自己把焦点挪到别处（比如选中项后跳到下一
  // 个控件），那就不该再拉回旧宿主——`set_focus` 与当下相同则一次事件都不发。
  self.set_focus(popup.return_focus)
}

///|
/// 当前开着的浮层数。
pub fn[B] App::popup_count(self : App[B]) -> Int32 {
  self.popups.length()
}

///|
/// 栈顶浮层（`None` = 栈空）。判据用它断言"Esc 关的是最上面那只"。
pub fn[B] App::top_popup(self : App[B]) -> Popup[B]? {
  if self.popups.length() == 0 {
    None
  } else {
    Some(self.popups[self.popups.length() - 1])
  }
}

///|
/// 一次输入事件进来时先看浮层栈：Esc 关栈顶并吞掉事件；左键 MouseDown 落在
/// 所有浮层树之外则关栈顶（不吞——那一下要照常落到 owner）。返回是否吞掉
/// 这条事件（只有 Esc 命中时为真）。由 `App::dispatch_round` 在**拖放拦截之后、
/// 正式路由之前**调用。
///
/// 为什么要"所有浮层树之外"而不是"栈顶之外"：连开两层浮层时，点第二层的内容
/// 不该把第一层也关掉。只要 target 命中任意一层，就不 dismiss。
pub fn[B : Backend] App::popup_input_guard(
  self : App[B],
  ev : Event,
) -> Bool raise UiError {
  if self.popups.length() == 0 {
    return false
  }
  match ev {
    KeyDown(_, kp) =>
      if kp.key == "Escape" {
        match self.top_popup() {
          Some(p) => {
            p.close_cause = Some(Event::target(ev))
            let _ = self.close_popup(p)
            true
          }
          None => false
        }
      } else {
        false
      }
    MouseDown(_, Left, _, _) => {
      let target = Event::target(ev)
      let mut inside = false
      for p in self.popups {
        if App::popup_hits(p, target) {
          inside = true
        }
      }
      if !inside {
        match self.top_popup() {
          Some(p) => {
            p.close_cause = Some(target)
            let _ = self.close_popup(p)
            false
          }
          None => false
        }
      } else {
        false
      }
    }
    _ => false
  }
}

///|
/// target 是否落在这只浮层的窗口或其内容树里。
fn[B] App::popup_hits(popup : Popup[B], target : EventTarget) -> Bool {
  let win = popup.window
  if win.target() == target {
    return true
  }
  match win.find_widget(target) {
    Some(_) => true
    None => false
  }
}
