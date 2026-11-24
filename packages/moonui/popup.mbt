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
///    从 `T359` ① 起这份账与原生 first responder 是**同一条路**：`set_focus`
///    在派 `Focus` 之前经 `Backend::focus_widget` 调三端的
///    `moonui_native_focus_control`（mac 先让它成为 keyWindow 再
///    `makeFirstResponder:`；Win `SetFocus`；GTK `present` + `grab_focus`），
///    所以浮层里的控件真能拿到键盘，不只是账面上拿到。
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
  /// 宿主窗口。归属语义交给后端（建窗时已把句柄交过去），Core 这边留着它
  /// 做两件事：读 owner 当下原点（`Popup::anchor_below` 的摆位基准）、
  /// owner 动了之后在它的内容树里把锚点控件重新找出来（`Popup::reposition`）。
  owner_window : Window[B]
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
  /// 锚点：owner 内容树里被锚定的那只控件（下拉的触发器、菜单的按钮…）。
  /// `None` = 调用方自己用 `Window::set_position` 摆位，Core 不插手。
  ///
  /// 记的是**控件**不是矩形：owner 被拖动 / 改尺寸 / 换屏改 DPI 之后布局重排，
  /// 矩形会变、控件不会走丢，`Popup::reposition` 拿它的当下 frame 重算就行。
  /// （`T359` ②：跨屏 DPI 与 owner 位移的重摆就是这一条。）
  mut anchor : EventTarget?
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
    owner_window: owner,
    size,
    close_hook: None,
    close_cause: None,
    return_focus: self.focus_target,
    anchor: None,
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
/// 把焦点交给 `target`（`None` = 清空）：先给旧的派 `Blur`，把原生焦点搬过去，
/// 再给新的派 `Focus`（账由派发起点翻，见 `App.focus_target` 段注）。与当下相同
/// 则一次事件都不发。
///
/// **原生那一半走 `Backend::focus_widget`**（`T359` ①）：Core 的账只是皮肤/路由
/// 账，键盘的归属在原生层——浮层是 owned 非激活窗，不把 first responder 搬过去，
/// 键仍归原来那只控件。搬迁放在派 `Focus` 之前（"物先到位、账后翻"），挪不动
/// （后端没有这条通道 / 原生拒绝）也照旧翻账：皮肤与观察者跟着 Core 走，这是
/// 既有语义，不因为某个平台够不到键盘就变。`target` 认不出所在窗口（窗口自己、
/// 已销毁控件）时不动原生焦点——那是"把焦点还给窗口"的情形，浮层的宿主窗本来
/// 就握着键盘。
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
      self.move_native_focus(t)
      let _ = self.dispatch(Focus(t))
    }
    None => ()
  }
}

///|
/// 把 target 对应的控件交给后端当原生焦点（`T359` ①）。在每只活窗的内容树里
/// 找 target，找到就调写口；找不到（target 是窗口自己 / 控件已随树销毁）什么
/// 都不做。
///
/// 失败一律吞掉：写口回答 `false` 是"这个后端够不到键盘"（自绘侧没有原生焦点、
/// 平台拒收），不是错误；`raise` 那种（句柄配对不合法）在这里也不该让关闭浮层
/// 这类路径半途抛错——焦点是路由账的附属动作，账该翻的照翻。
fn[B : Backend] App::move_native_focus(
  self : App[B],
  target : EventTarget,
) -> Unit {
  for win in self.windows {
    if !win.is_closed() {
      match win.find_widget(target) {
        Some(w) => {
          match w.handle() {
            Some(h) =>
              try {
                let _ = Backend::focus_widget(self.backend, win.handle(), h)
              } catch {
                _ => ()
              }
            None => ()
          }
          break
        }
        None => ()
      }
    }
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
  self.owner_window.handle()
}

///|
/// 浮层尺寸（逻辑像素）。
pub fn[B] Popup::size(self : Popup[B]) -> LogicalSize {
  self.size
}

///|
/// 把浮层锚在 `w` 的下方左对齐（`T359` ②）：摆一次，并**记下这只控件**——
/// owner 之后被拖动 / 改尺寸 / 换到另一块屏（DPI 变了）时，Core 会按它的
/// 当下 frame 重摆（`App::popups_follow`）。不记矩形就是为这一步：重排之后
/// 矩形会变，控件不会走丢。
///
/// 坐标口径同 `Widget::frame`：owner **客户区**逻辑坐标（§30）。三端各自换成
/// 自己的坐标空间——mac/win 读 owner 原点加上偏移（`Window::set_position`，
/// 桌面绝对坐标），GTK4 没有窗口位置这条通道，浮层由合成器贴着 transient
/// parent 摆（`T354`/`T359` ① 的如实边界，见 TODO）。
///
/// `w` 不必已经挂在 owner 树里：只用到它的 `target` 与 `frame`。但重摆那一步
/// 要在 owner 树里按 target 找回来，所以常规用法是"先 `set_content` 再锚"。
pub fn[B : Backend] Popup::anchor_below(
  self : Popup[B],
  w : Widget[B],
) -> Unit raise UiError {
  self.anchor = Some(w.target())
  self.place_at(w.frame())
}

///|
/// 当下锚在哪只控件上（`None` = 调用方自己摆位）。
pub fn[B] Popup::anchor(self : Popup[B]) -> EventTarget? {
  self.anchor
}

///|
/// 按锚点控件的**当下** frame 重摆一次（`T359` ②）。owner 动了之后由
/// `App::popups_follow` 调；锚点控件已经随树销毁（关窗、换内容）时什么也不做
/// ——留在原地的浮层比"跳到 (0,0)"诚实。
///
/// **只摆位、不推尺寸**：拖窗时 `Moved` 每一帧都来，跟着重排一次浮层的整棵树
/// 是白烧（`set_size` 会走 `relayout`）。尺寸只有跨屏 DPI 那一档要重推，见
/// `Popup::resync_size`。
pub fn[B : Backend] Popup::reposition(self : Popup[B]) -> Unit raise UiError {
  match self.anchored_rect() {
    Some(rect) => self.place_at(rect)
    None => ()
  }
}

///|
/// 把逻辑尺寸重新推给后端（`T359` ②，跨屏 DPI 那一档）：换到另一块屏之后
/// scale 变了，逻辑尺寸不变、物理像素要按新 scale 重算，而换算就在后端的
/// `set_window_size` 里（Core 只给逻辑值）。`Resize`/`Moved` 不走这条——
/// 那两个不改 scale，重推只会白重排一次。
pub fn[B : Backend] Popup::resync_size(self : Popup[B]) -> Unit raise UiError {
  self.window.set_size(self.size)
}

///|
/// 锚点控件的当下 frame（`None` = 没锚，或锚点已随树销毁）。
fn[B] Popup::anchored_rect(self : Popup[B]) -> LogicalRect? {
  let target = match self.anchor {
    Some(t) => t
    None => return None
  }
  match self.owner_window.find_widget(target) {
    Some(w) => Some(w.frame())
    None => None
  }
}

///|
/// 把浮层摆到 `rect` 的下沿左对齐处（owner 客户区坐标）。
fn[B : Backend] Popup::place_at(
  self : Popup[B],
  rect : LogicalRect,
) -> Unit raise UiError {
  let ow = self.owner_window.position()
  self.window.set_position(
    LogicalPoint(ow.x + rect.origin.x, ow.y + rect.origin.y + rect.size.height),
  )
}

///|
/// 把焦点交给浮层内容树里**声明序第一个**可聚焦控件（`T359` ①）。内容还没
/// 装（`None`）或树里没有可聚焦控件时返回 `false`，焦点原地不动——自绘下拉
/// 的选项列表就是这种（`focusable=false`，键盘导航本该留在触发器上）。
///
/// 调用时机：`set_content` 之后、`show` 前后皆可（Core 只改账，不看窗口可
/// 见性）。要先装内容再调——空树的答案永远是 `false`。
///
/// 原生那一半由 `set_focus` 顺着 `Backend::focus_widget` 一并做掉：浮层这侧
/// 的写口会先让浮层窗成为 keyWindow（mac）/ 被 present（GTK）/ 拿到同线程的
/// 焦点（Win），键盘才真归浮层里的控件。后端拒绝不影响返回值——返回值说的是
/// "Core 找到了可交给的人"，不是"原生收下了"。
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

///|
/// owner 动了之后把挂在它身上的浮层重摆一遍（`T359` ②）。
///
/// 触发面就是 owner 自己的三条几何事件：`Moved`（用户拖窗 / 程序化移动）、
/// `Resize`（拖边、改尺寸、上屏第一拍）、`ScaleChanged`（换到另一块屏，DPI
/// 变了）。三条都在 `App::dispatch` 路由**之后**调这里——重排刚跑完，锚点控件
/// 的 frame 才是新的。
///
/// 为什么不是"把浮层也当成会被 `T89` 吸附带走的邻居"：浮层的归属是 owner，
/// 不是桌面上的自由窗口；它跟着走的是**锚点控件**，锚点控件又跟着布局走。
/// 两层账分开算，重排之后仍然对。
///
/// 只动锚了的那些（`anchor` 为 `None` 的是调用方自己摆的位，Core 不插手）。
/// 单只浮层摆位失败不影响其它：`set_position` 抛的是句柄类错误（窗口已关），
/// 那种情况下这只浮层本来就该消失了，吞掉继续。
///
/// `dpi_changed` 只有 `ScaleChanged` 那一档为真：那时还要把逻辑尺寸重推一遍
/// （物理像素按新 scale 重算），而 `Moved`/`Resize` 只摆位——拖窗的每一帧都
/// 重排整棵浮层树是白烧。
fn[B : Backend] App::popups_follow(
  self : App[B],
  owner : EventTarget,
  dpi_changed : Bool,
) -> Unit {
  for p in self.popups {
    if !p.window.is_closed() && p.owner_window.target() == owner {
      p.reposition() catch {
        _ => ()
      }
      if dpi_changed {
        p.resync_size() catch {
          _ => ()
        }
      }
    }
  }
}
