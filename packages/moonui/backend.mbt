///|
/// Backend 接口（设计文档 §19、§47 风险 6）。
///
/// Core 只通过 `Backend` 与具体 GUI 库对话，因此平台的差异（现在是直写 AppKit /
/// Win32 的原生适配器）全部留在实现侧。当前 MoonBit 版本里 trait 不是类型（也没有 `dyn`），所以
/// Backend 走泛型静态分发：`App[B : Backend]`。这意味着 **后端是编译期选定**
/// 的，与 §34/§35 "每个平台预编译对应后端" 的方向一致。

///|
/// 后端跑在哪个宿主上（§12 的窗口装饰分叉用）。
///
/// 与 `system_theme` 不同，这条**不是偏好**而是血统：同一个应用二进制只会跑在
/// 一个宿主上，读数不会随会话变化。用途只有一个——让应用知道"系统有没有替它
/// 画窗口控制按钮"。macOS 有红绿灯（沉浸式标题栏下浮在内容左上），Windows 的
/// 最小化/最大化/关闭由标题栏右侧自绘（Win32 的 `WS_SYSMENU` 那套在无边框窗
/// 上就没了），Web 两种都没有。所以要自绘窗口钮的界面得先问这一条，否则 mac
/// 上会跟红绿灯重复、Windows 上会少一排按钮。
///
/// `Unknown` 按"没有系统按钮"处理（自绘那套照常出现）：宁可多画一排按钮，
/// 也不要在一个真的没有关闭按钮的平台上让用户关不掉窗口。
pub(all) enum HostPlatform {
  Macos
  Windows
  Web
  Unknown
} derive(Debug, Eq)

///|
pub(open) trait Backend {
  /// 初始化底层工具链。失败必须带原因（§33）。
  fn init(Self) -> Unit raise UiError
  /// 释放底层资源；调用后不允许再创建对象。
  fn terminate(Self) -> Unit
  /// 非阻塞取出一个待处理事件，队列空时返回 `None`（§10、§27）。
  ///
  /// 契约：事件里所有坐标/增量都必须是**逻辑像素**。原生层给的是物理坐标
  /// （Win32 的 lParam、Cocoa 的 NSEvent.locationInWindow 换算结果、SDL3 的
  /// mouse button 都是物理的），适配器入队前要先除以该窗口的 Scale（§30）。
  /// 这条换算放在实现侧而不是 Core 侧，是因为 Core 已经在唯一一处读 Scale，
  /// 两边都换算就会出现"除以两次"的经典 HiDPI 位移 bug。
  fn poll_event(Self) -> Event?
  /// 下一次 `poll_event` 的**等待上限**（毫秒），`-1` = 恢复默认（产品语义：
  /// 一直等到有原生事件）。
  ///
  /// 为什么这条路必须在后端：方块掉在哪一端决定了"空闲时多久醒一次"。产品
  /// 默认是一觉睡到下一个原生事件，于是**没有事件就没有循环**——任何靠
  /// 循环自续的活（定时投递、500ms 心跳、长按到期）都只能蹭别人的事件。
  /// Core 每个 `step` 在 `poll_event` 之前把"最近一个到期时刻"折算成本条
  /// 推下来，后端据此把这一觉的时长夹到那个上限；没有待办的活推 -1 恢复
  /// 零开销。与帧钟那条（`NativeBackend::set_frame_budget`）是**两个独立的
  /// 来源**，后端取两者（以及测试预算）里最小的那个，谁也不覆盖谁。
  ///
  /// `MockBackend` 的 `poll_event` 本来就不阻塞，实现为空操作（只记账，
  /// 判据靠它断言"Core 真的把到期时刻交下来了"）。
  fn set_wait_cap(Self, Int32) -> Unit
  /// 后端侧有没有人在请求退出循环（`T154`）。Core 每圈在 `poll_event` 之后问一次。
  ///
  /// 为什么必须由 Core 问：进程级退出有两条路，一条在 Core 手里（`App::quit`，
  /// 应用自己的按钮/菜单项），另一条在**原生层手里**——mac 默认「应用」菜单的
  /// ⌘Q 直接调 `moonui_native_quit()`、Win32 的 `WM_CLOSE` 兜底同理，它们不知道
  /// Core 的存在。以前 `App::drive` 只认自己那个 `quit_requested`，于是原生那条
  /// 路退不掉：`poll_event` 返回 `None` 只在"没有存活窗口"或"后端已经读到过
  /// 那个标志"时发生，而后者要求 `pump` 至少完整跑一圈——它不跑，`loop_ended`
  /// 就一直是 `false`，`step` 也一直有活干（定时账非空），循环永远出不来。
  /// 真机上表现成"播着音乐按 ⌘Q 卡死"；暂停时定时账空掉、`step` 报"没进展"，
  /// 循环才靠那条旁路结束，所以看起来是"卡一会儿又能退"。
  ///
  /// 实现只需读后端当下持有的那个标志，不阻塞、不唤醒：
  /// - `NativeBackend`：C 侧 `loop_ended` 已被 `pump` 收进 `self.loop_ended`；
  /// - `CanvasBackend`：转发内嵌原生后端；
  /// - `MockBackend`：注入的 `quit_requests` 计数（判据靠它模拟原生侧退出）。
  fn quit_pending(Self) -> Bool
  /// 请求给这只窗口画一帧（`T31`）。原生控件后端是空操作——重绘是系统的事，
  /// 窗口脏了系统自己会画，这条对它没有意义；自绘后端（§51 的 Backend #2）靠它
  /// 在空闲时续命：调用后下一圈 `poll_event` 要吐一条 `Frame`（target 是这只
  /// 窗口），Core 据此驱动它画一帧。契约只钉"调用后下一圈能取到一条 Frame"，
  /// 不钉"恰好一条"——后端可以合并多次请求（脏了就是脏了，画一帧就够）。
  fn request_redraw(Self, NativeHandle) -> Unit raise UiError
  fn create_window(Self, title : String, size : LogicalSize) -> NativeHandle raise UiError
  fn destroy_window(Self, NativeHandle) -> Unit raise UiError
  fn set_window_title(Self, NativeHandle, String) -> Unit raise UiError
  fn set_window_size(Self, NativeHandle, LogicalSize) -> Unit raise UiError
  /// 客户区最小尺寸（§12），`None` = 清掉限制。
  ///
  /// 为什么非要有原生这条路：Core 的夹紧只挡得住**程序化**改尺寸（`set_size` /
  /// `sync_size`），用户拖窗格根本不经过 Core——Resize 事件是"已经拖完了"的
  /// 回报。只靠 `Window::clamped` 挡不住窗口被拖成一条缝、内容挤成一团。mac 落
  /// `NSWindow.contentMinSize`、Win32 落 `WM_GETMINMAXINFO`，都是系统级的钳位，
  /// 拖拽过程中就会被顶住。
  fn set_window_min_size(Self, NativeHandle, LogicalSize?) -> Unit raise UiError
  /// 拖拽改尺寸时是否**实时重排**（live redraw）。默认开。
  ///
  /// 开 = 每一记 resize 当场重排（内容跟手）；关 = 拖拽期间不动，松手后按最新
  /// 尺寸补一次重排（复杂应用拖起来卡时关掉它）。为什么开关要落在后端：拖拽
  /// 跑在系统模态循环里（mac 的窗口跟踪循环、Win32 的 sizing 循环），
  /// `App::step` 被泵卡住、事件队列根本排不动——"当场重排"只能在原生回调的
  /// 同步栈上兑现，那条路在 `push_resize` 里按这个开关分流（配合
  /// `set_live_dispatch` 的直达通道）。
  fn set_window_live_redraw(Self, NativeHandle, Bool) -> Unit raise UiError
  /// 事件的**实时直达通道**（live dispatch）：`push_resize` / `push_move` /
  /// 滑块的 `Change` 走实时路时把事件同步交给这里装的处理器（App 装的是
  /// `fn(ev) { app.dispatch(ev) }`），不再入队——入了也得等松手才排空，白绕
  /// 一圈。`None`（默认）= 没人接实时路，一切照旧入队。处理器的失败由调用处
  /// 就地吞掉（原生回调栈上没有能把 `UiError` 传出去的路）；走队列的那条失败
  /// 照旧从 `step` 传出（§33）。
  fn set_live_dispatch(Self, ((Event) -> Unit raise UiError)?) -> Unit
  fn show_window(Self, NativeHandle) -> Unit raise UiError
  fn hide_window(Self, NativeHandle) -> Unit raise UiError
  /// 窗口所在屏幕的缩放因子，用于逻辑/物理像素换算（§30）。
  fn window_scale(Self, NativeHandle) -> Scale raise UiError
  /// 主屏可用区域，逻辑像素。`Window::center` 与多屏定位依赖它（§12、§30）。
  /// 这条是**进程级**的读数：窗口还没建出来时只有它能用。窗口已经存在时用下面那条。
  fn screen_size(Self) -> LogicalSize raise UiError
  /// 这只窗口**当下所在那块屏**的工作区（去掉任务栏 / Dock），逻辑像素。
  /// `Window::center` 用它，用 `screen_size` 会把副屏上的窗口摆回主屏（§12、`T42`）。
  ///
  /// 契约：这个矩形的坐标空间和 `window_position` / `set_window_position` **同一个**，
  /// 因为读数只有用摆位那套坐标才摆得回去。两个平台那套空间本身不同（mac 的原点是
  /// "该屏可见区的左上角"，所以 origin.y 恒为 0；Win32 是虚拟屏幕绝对坐标，副屏在右
  /// 边时 origin.x 是个非零绝对值），所以 Core 拿它只做一件事——在这块屏的可用矩形里
  /// 算一个摆位点，然后交给同一个后端的 set_position。不要在两个后端之间比这个数。
  fn window_work_area(Self, NativeHandle) -> LogicalRect raise UiError
  /// 系统当前的外观（Light/Dark）。`Theme::System` 靠它落地（§16）。
  fn system_theme(Self) -> Theme raise UiError
  /// 宿主平台（`HostPlatform` 的段注）。不 raise：血统是编译期就定死的，
  /// 读不到只能是"未知"，没有失败可报。
  fn host_platform(Self) -> HostPlatform
  /// 进程级偏好读数（`T87`③）：系统"减少动态效果"开着没有。开着 = 动画
  /// 退场闸门拉下——泵把激活账当圈推**精确的落点**、不跑中间帧（语义在
  /// `app.mbt` 的 `pump_animations`）。快照式读当下偏好（与 `window_state`
  /// 读回同一条纪律，`T86`② 落地注记）：不推送、不订阅，问一次拿一份。
  /// 读不到（平台没有这个偏好）一律返回 `false`，不当失败——外观那条
  /// `system_theme` 的"读不到就当浅色"同一条绕行。
  fn get_prefers_reduced_motion(Self) -> Bool raise UiError
  /// 进程级偏好读数（`T87`②）：系统"增强对比度"开着没有。首版只做读口 +
  /// Mock 可模拟；消费点（主题读数档——按偏好换一套配色）第二版再接，
  /// 首版不接主题（主题账 §15/`T40` 是另一块地基，不夹带）。
  /// 快照式与"读不到当 `false`"的理由同上。
  fn get_prefers_high_contrast(Self) -> Bool raise UiError
  /// 读回窗口当前的尺寸/位置：原生层是唯一事实来源，Core 不缓存。
  fn window_size(Self, NativeHandle) -> LogicalSize raise UiError
  fn set_window_position(Self, NativeHandle, LogicalPoint) -> Unit raise UiError
  fn window_position(Self, NativeHandle) -> LogicalPoint raise UiError
  fn set_window_resizable(Self, NativeHandle, Bool) -> Unit raise UiError
  fn set_window_fullscreen(Self, NativeHandle, Bool) -> Unit raise UiError
  /// 标题栏样式（§12）。`Immersive` = 内容铺满整个窗口、窗口钮浮在内容上：
  /// mac 走 `fullSizeContentView` + 透明标题栏 + 隐藏标题文字；Windows 摘掉
  /// `WS_CAPTION`（系统标题栏连同菜单条一起没有），拖动改由 `set_window_drag_band`
  /// 报的自绘顶条承担。`Standard` 切回各自的标准标题栏。
  fn set_window_titlebar_style(Self, NativeHandle, TitlebarStyle) -> Unit raise UiError
  /// 红绿灯位置（§12）。`p` 是**关闭按钮左上角**相对**窗口左上角**的逻辑像素坐标，
  /// mac 把三个红绿灯整簇挪过去（resize 时重新断言，AppKit 会在 resize 时把它们
  /// 摆回默认位）；Windows 没有红绿灯，是空操作。
  fn set_window_traffic_light_position(Self, NativeHandle, LogicalPoint) -> Unit raise UiError
  /// 自绘顶条的**拖动带**（`T116`）：窗口上缘往下 `height` 个**逻辑像素**算标题栏。
  ///
  /// 为什么这条必须在 Core 之外落地：沉浸式窗在 Windows 上摘掉了系统标题栏
  /// （`WS_CAPTION`），系统再没有"拖这块能搬窗"的区域；而每只窗的顶条多高只有
  /// Core 知道（主控 30、伴窗 22、迷你条 48，桌面歌词根本没有）。不报这一条，
  /// 自绘标题栏的窗就拖不动——鼠标落在条上只会报普通客户区命中。
  ///
  /// mac 是空操作（AppKit 的沉浸式窗仍认原标题栏那一条为可拖区域），留这条是
  /// 为了调用方不按平台分叉。`height <= 0` = 没有拖动带。
  fn set_window_drag_band(Self, NativeHandle, Double) -> Unit raise UiError
  /// 控件创建与属性读写（§13）。窗口和控件共用同一张句柄表，所以
  /// `EventTarget.id` 全局唯一，派发时不会把窗口和控件混为一谈。
  fn create_widget(Self, kind : WidgetKind, text : String) -> NativeHandle raise UiError
  /// Slider / Spinbox 的创建通道：范围是这两个控件的构造参数（沿 libui 的
  /// 口径——`uiNewSlider(min,max)` / `uiNewSpinbox(min,max)` 没有"先建再设"的入口，
  /// Spinbox 连事后改范围都没有），所以单独一条而不是给 `create_widget`
  /// 塞一对大多数种类用不上的参数。其余种类必须走 `create_widget`。
  fn create_ranged_widget(Self, kind : WidgetKind, min : Int32, max : Int32) -> NativeHandle raise UiError
  fn destroy_widget(Self, NativeHandle) -> Unit raise UiError
  fn set_widget_text(Self, NativeHandle, String) -> Unit raise UiError
  fn widget_text(Self, NativeHandle) -> String raise UiError
  fn set_widget_checked(Self, NativeHandle, Bool) -> Unit raise UiError
  fn widget_checked(Self, NativeHandle) -> Bool raise UiError
  /// 内边距下发（§51 的 MenuRow）：文字按内边距缩进的**绘制语义**归后端，
  /// **测量账**（加 padding 即背景长大 = 固有尺寸加 insets）归 Core 统一记——
  /// `to_layout_spec` 一处加，后端不重复记账。与 `set_widget_style` 不同源：
  /// 样式是"后端当下持有的事实"，测量反映它；insets 是 Core 自己的属性，
  /// 测量不走后端持有那条路。没有 getter：同 `set_widget_style`，回读只是把
  /// 同一份数据搬两次。豁免（同 `set_widget_style`）：样式那份豁免写在
  /// `backends/native-common/backend.mbt` 的实现里（原生后端有意不读样式）；
  /// insets 在原生后端没有豁免——MenuRow 的缩进真由适配器画（libui 那份曾是
  /// "最小标准按钮形状、绘制不消费"，`T82` 删）。
  fn set_widget_insets(Self, NativeHandle, EdgeInsets) -> Unit raise UiError
  /// 数值属性（§13）：Slider / Spinbox / Progress 的当前值。
  /// Progress 的约定：0–100，传 -1 表示"不定进度"（沿 libui 的约定）。
  fn set_widget_value(Self, NativeHandle, Int32) -> Unit raise UiError
  fn widget_value(Self, NativeHandle) -> Int32 raise UiError
  /// 改范围。只有 Slider 有这条（沿 libui 的事实口径，见 create_ranged_widget）。
  fn set_widget_range(Self, NativeHandle, min : Int32, max : Int32) -> Unit raise UiError
  /// 条目属性：ComboBox / RadioButtons 的选项与选中下标（§13）。
  fn append_widget_option(Self, NativeHandle, String) -> Unit raise UiError
  fn set_widget_selected(Self, NativeHandle, Int32) -> Unit raise UiError
  fn widget_selected(Self, NativeHandle) -> Int32 raise UiError
  /// 日期时间属性（DatePicker）：值以 `"YYYY-MM-DD HH:MM:SS"` 文本进出。
  /// 不并进 `set_widget_text`：原生层的值是 `struct tm`，不是窗口文本，
  /// 这两个通道在 C 侧是两套调用，MoonBit 侧分开就不会串。
  fn set_widget_datetime(Self, NativeHandle, String) -> Unit raise UiError
  fn widget_datetime(Self, NativeHandle) -> String raise UiError
  fn set_widget_visible(Self, NativeHandle, Bool) -> Unit raise UiError
  fn widget_visible(Self, NativeHandle) -> Bool raise UiError
  fn set_widget_enabled(Self, NativeHandle, Bool) -> Unit raise UiError
  fn widget_enabled(Self, NativeHandle) -> Bool raise UiError
  /// 不透明度下发（`T84` 动画通道）：0.0–1.0，1.0 全显、0.0 全隐。
  ///
  /// 与 `set_widget_style` 分开一条，是 `T84` 破 §32 豁免的那一笔：透明度是
  /// 动画逐帧推进的值，激活期每帧都要单独推、退场帧推精确落点，不能塞在
  /// "整张样式重排才推一次"的通道里。样式那份（颜色/圆角/字体）照走豁免
  /// 不动（原生后端有意不读，豁免注释已在 `backends/native-common/backend.mbt`
  /// 同步改写为"除 opacity 这条动画通道外"）。
  ///
  /// 契约同 bounds 那一族：Core 发逻辑值（这里是 0..1 的 Double），物理换算
  /// 归实现侧（native 半乘 1000 换千分比整数过 FFI）。没有 getter：透明度
  /// 的唯一事实来源是 Core 的 shown 账（动画泵推进），回读只是把同一份数据
  /// 搬两次——与样式同一条理由。
  fn set_widget_opacity(Self, NativeHandle, Double) -> Unit raise UiError
  /// 样式下发（§15/§16）：Core 把 `Widget::resolved_style` 沿祖先链算完的生效值
  /// 交给后端。自绘后端据此绘制配色、字体、圆角与透明度。
  ///
  /// 契约：**先推样式，再测量**。`widget_intrinsic_size` 反映后端当下持有的样式，
  /// Core 不再把 `Style` 当参数传进测量——否则"控件现在长什么样"这条事实在两个
  /// 地方各说一遍，改一处漏一处。原生控件库里也是同一个顺序：Win32 的
  /// `WM_SETFONT` 先发给控件，控件自己重算尺寸，之后量到的才是新值。
  /// `Window::relayout` 走的就是这个顺序（§14）。
  ///
  /// 没有对应的 getter：层叠由 Core 计算，解析结果本来就在 Core 手里，
  /// 向后端回读只是把同一份数据搬两次。
  ///
  /// 原生控件后端有权完全不读这份样式——§32 要保住系统原生外观，AppKit 也不给
  /// button/label per-control 的字体接口。这条豁免写在 `backends/native-common/backend.mbt` 的实现里，不是隐藏行为。
  fn set_widget_style(Self, NativeHandle, Style) -> Unit raise UiError
  /// 图标（皮肤账）：按钮/控件换图形图标（mac 半 SF Symbols，名字与
  /// systemImage 同名；Windows 半缺席）。设了图标的原生按钮摘掉系统
  /// bezel，成平面图标钮。装饰性事实——后端给不出就静默缺席（原生按钮
  /// 保持文本外观），不 raise（图标不是任何判据的输入）。
  fn set_widget_icon(Self, NativeHandle, String) -> Unit raise UiError
  /// 主题底样式（皮肤账）：层叠的起点，每次重排先于 set_widget_style 推。
  /// 原生后端拿它做"继承 vs 显式"的分野——样式字段与底样式同值视为继承
  /// （Button 这类保原生外观的 kind 不消费），不同值才是应用显式要的。
  fn set_theme_base(Self, Style) -> Unit raise UiError
  /// 把 §32 的无障碍语义推给后端（`T41`）：Role / Label / Description / State
  /// 四样，载荷是 Core 现算的 `Accessibility`。与 `set_widget_style` 同一条
  /// 顺序契约——都在 `Widget::apply_styles` 里下发，`Window::relayout` 先样式
  /// 后语义再 `do_layout`。Actions 也在这份结构里，但它的翻译（原生层把
  /// "执行"接给读屏器）留到 Actions 那半，后端先不读它。
  ///
  /// 显式声明了角色的纯布局节点没有 `NativeHandle`，走不到这里——它们进得了
  /// `accessibility_tree`（Core 自己展开的视图），却挂不到任何原生对象上；
  /// 给它们造原生 a11y 元素是 §17 自定义控件那一格的事。
  fn set_widget_accessibility(Self, NativeHandle, Accessibility) -> Unit raise UiError
  fn set_widget_bounds(Self, NativeHandle, LogicalRect) -> Unit raise UiError
  fn widget_bounds(Self, NativeHandle) -> LogicalRect raise UiError
  /// 固有尺寸由后端测量：字体度量属于原生层，Core 不猜（§18）。
  fn widget_intrinsic_size(Self, NativeHandle) -> LogicalSize raise UiError
  /// 重画一块自定义绘制面（`T101`，§17 的 CustomWidget）：`dl` 是 Core 调完
  /// 绘制回调得到的一整份清单，坐标是**控件局部**的逻辑像素（原点左上、y 向下）。
  ///
  /// 契约：
  /// - 后端按自己的 Scale 换物理，并且**只换一次**（`DrawList` 里的数是逻辑，
  ///   与 `poll_event` 的坐标口径同一条）；
  /// - 整份替换，不是增量——上一帧的画面不留；
  /// - 这条只在 `WidgetKind::Custom` 的句柄上被调用；其它句柄是调用方的错。
  ///
  /// 为什么不像 `set_widget_bounds` 那样"推一项属性"：绘制清单是一次性的、
  /// 整份的，与"后端当下持有的状态"不是同一种东西——照属性那样存下来反而
  /// 会留一份没人读的旧帧。
  fn draw_custom(Self, NativeHandle, DrawList) -> Unit raise UiError
  /// 量一段文字（宽, 高），逻辑像素（`T101` 的绘制回调要用；画布 ABI 的
  /// `moonui_canvas_measure_text` 就是它的 mac 实现）。
  ///
  /// 为什么单独开一条而不是塞进 `widget_intrinsic_size`：后者量的是"某个控件
  /// 该多大"，带样式、带内边距；这里是"这段文字在这个字号下多宽"，与控件无关。
  /// 自定义控件的绘制回调里做居中/换行算的就是后者。
  fn measure_text(Self, String, size : Double, bold : Bool) -> (Double, Double) raise UiError
  /// 原生父子挂接：控件必须属于窗口才会显示（§8）。
  /// Row/Column 这类容器在 Core 里算绝对边界、不占原生对象（§14），
  /// 所以后端的挂接目标只有窗口。
  fn attach_widget(Self, window : NativeHandle, child : NativeHandle) -> Unit raise UiError
  /// 挂进**容器控件**（`T74`：Scroll 占用原生对象，子树挂进它的文档区）。
  /// `container` 是滚动视口的句柄；与 `attach_widget` 分开，因为两边的
  /// 原生语义不同（窗口 vs 容器的文档视图），后端各译各的。
  fn attach_widget_to(Self, container : NativeHandle, child : NativeHandle) -> Unit raise UiError
  /// 滚动行程（`T74`）：`size` 是内容按完整尺寸量出来的大小（可以超出视口），
  /// 后端据此给文档视图定尺寸并按主轴配滚动条；视口自己的矩形走
  /// `set_widget_bounds`，和叶子同一条通道。
  fn set_scroll_content(
    Self,
    scroll : NativeHandle,
    axis : Axis,
    size : LogicalSize,
  ) -> Unit raise UiError
  fn detach_widget(Self, child : NativeHandle) -> Unit raise UiError
  /// 层叠（§14 的 Stack）：把控件提到所在窗口子窗口列表的最上层。
  ///
  /// 为什么不并进 `attach_widget`：挂载只能给出"顺序"这一件事，而原生层的视觉层叠
  /// 与键盘 Tab 走的是同一份 z-order，两者方向相反（先挂的在 Tab 链前面，后挂的
  /// 画在上层）。Stack 的契约是"数组靠后的画在上层"，所以由 Core 在挂载之后按
  /// 数组顺序逐个 raise，把视觉顺序钉死——代价写在 window.mbt 的 `apply_layers`。
  fn raise_widget(Self, child : NativeHandle) -> Unit raise UiError
  /// 整窗的绘画顺序（`T29`）：`order` 是这只窗口所有叶子控件**从顶层到底层**的
  /// 完整列表，Core 在挂载之后算好、整份推下来。
  ///
  /// 为什么有这条而不是只靠 `raise_widget`：`raise_widget` 假定"层叠 = 原生 z-order"，
  /// 自绘后端（§51 的 Backend #2）根本没有 z-order 这回事，它要的正是这份"谁画在谁
  /// 上面"的列表。原生控件后端把它翻译成自己的 z-order（原生后端按倒序逐个
  /// `raise_widget` 就到位——形状沿 libui 那份，`T82` 删），自绘后端存下来当绘制顺序用。Core 因此只说"顺序是什么"，
  /// 不说"怎么摆"——层叠从"原生层的事"变成"Core 算、后端落"。
  fn set_paint_order(Self, window : NativeHandle, order : Array[NativeHandle]) -> Unit raise UiError
  /// 整窗的焦点链（`T29`）：`chain` 是这只窗口所有叶子控件**按声明顺序**（先序）的
  /// 完整列表，Core 在挂载之后算好、整份推下来，后端把原生焦点机制（macOS 的
  /// `nextKeyView` 链）接成这条顺序，于是键盘 Tab 走的是声明顺序。
  ///
  /// 为什么和 `set_paint_order` 分开：原生层里绘画和 Tab 常常共用同一份顺序（Win32 的
  /// z-order 一份管两件事），但 Stack 的契约要的是"数组靠后的画在上层"——绘画顺序因此
  /// 是声明顺序的**倒序**，而 Tab 不该跟着倒。把两条链都交给 Core 算、后端各自落，
  /// 层叠和焦点才解耦：Stack 里 Tab 走声明顺序、绘画走倒序，两者不再互相绑架。
  /// 不含 Stack 的树两条链同值，行为与旧实现一致。
  fn set_focus_chain(Self, window : NativeHandle, chain : Array[NativeHandle]) -> Unit raise UiError
  /// 自绘面的键盘焦点参与（`T102` 第十一刀）：`on=true` 时这块面可以成为
  /// first responder，点了就拿到焦点、Tab 也停得住，于是 `KeyDown` 会派给
  /// 它（`T102` 第十刀的键盘导航在真窗上要靠这一条）。
  ///
  /// 为什么是逐控件的显式 opt-in、而不是让自绘面一律接受焦点：自绘面是裸
  /// `NSView`，恒 `YES` 会把每一个"只是画点东西"的面塞进 Tab 链，还会在
  /// 点击时从文本框手里抢走焦点——画布式控件通常没有键盘语义，抢焦点是
  /// 用户能直接感知的破坏。默认关，需要键盘的那块面自己声明。
  ///
  /// 只对 `WidgetKind::Custom` 有意义；别的 kind 上调用是空操作（原生控件
  /// 的焦点由系统按类决定，不归这条管）。
  fn set_custom_focusable(Self, NativeHandle, Bool) -> Unit raise UiError
  fn clipboard_text(Self) -> String? raise UiError
  fn set_clipboard_text(Self, String) -> Unit raise UiError
  /// 对话框（§24）。同步语义：真实后端在这里阻塞自己的事件循环子轮次。
  fn show_message(Self, title : String, text : String) -> Unit raise UiError
  /// 确认框，返回用户是否选择"是"。
  fn confirm(Self, title : String, text : String) -> Bool raise UiError
  /// 文件/文件夹选择，用户取消返回 `None`。
  fn open_file(Self, title : String) -> String? raise UiError
  fn save_file(Self, title : String, default_name : String) -> String? raise UiError
  fn select_folder(Self, title : String) -> String? raise UiError
  /// 菜单栏（§25）。真实后端在这里把 Core 的菜单树换成原生菜单（Win32 的 HMENU、
  /// Cocoa 的 NSMenu）；用户点击通过 `Event::MenuSelect` 回流，Core 不轮询菜单状态。
  ///
  /// 整棵替换，没有增量修改的入口：`MenuBar` 在 Core 侧是不可变结构（改一项就得
  /// 重新装一遍），而原生层两边都只给了"重建"这条路（见 TODO 的 `T22`）。
  fn set_menu_bar(Self, MenuBar) -> Unit raise UiError
  /// 把 Core 改掉的勾选态推给刚安装的那棵原生菜单（§25 / §48-20）。
  ///
  /// 为什么是"推"而不是让后端回读：按 §25 勾选状态只存在 Core（原生菜单项没有可靠
  /// 的读回口），后端如果自己也存一份树，两份状态迟早分叉。所以 Core 在
  /// `App::click_menu_item` 里改完就当场推一次，后端只负责把那个勾画出来。
  ///
  /// `id` 是 `MenuBar::all_items()` 给的菜单项 id，和窗口/控件的句柄 id 是两个编号
  /// 空间（§25）。id 不在已安装的菜单栏里必须 `raise`：写错的菜单 id 是用户看不见、
  /// Core 也回读不出的那类错（§33），不许静默忽略。
  fn set_menu_item_checked(Self, id : Int32, checked : Bool) -> Unit raise UiError
  /// 应用图标（§26）。参数是**不带扩展名的文件名**（stem）：mac 侧补 `.png`、
  /// Windows 侧补 `.ico`，调用方只写一份路径。相对进程 CWD 解析，建议在
  /// `create_window` 之前调用——之后新建的窗口才会带着这份图标。
  fn set_app_icon(Self, name : String) -> Unit raise UiError
  /// 控件级右键上下文菜单（`T86①`）：把 Core 配置的一份菜单弹出来（在按下
  /// 右键的控件上方、鼠标当下的位置）。选中的语义沿 `T22` 现账：勾选态改在
  /// Core（`MenuBar::click` 那一套）、回调当场跑——弹窗是同步阻塞的嵌套循环，
  /// 选中的解析发生在循环内（`T86①` 落地注记），不像菜单栏那样回流成
  /// `MenuSelect` 事件（上下文菜单的条目不属于安装的菜单栏，事件路由接不住
  /// 它们）。回调里的异常就地吞掉（异常跨 C 帧未定义，worker 同一条纪律）。
  fn show_context_menu(Self, menu : Menu) -> Unit raise UiError
  /// 窗口态下发（`T86②`）：最小化与最大化两条 setter 加一条读回。读回口径是
  /// "读当下态"而不是推送式（`T86②` 落地注记）：批三的窗口持久化（`T86⑦`）
  /// 要的是"存档时刻窗口是什么态"，问一次拿一份快照正合适。
  fn set_window_minimized(Self, NativeHandle, Bool) -> Unit raise UiError
  fn set_window_maximized(Self, NativeHandle, Bool) -> Unit raise UiError
  fn window_state(Self, NativeHandle) -> WindowState raise UiError
  /// 图像源（`T86⑤`，解码归平台——开工决策）：按路径/按字节两条加载通道，
  /// 解码与绘制都是原生层的事（mac 半 NSImage + NSImageView）。两条都是整源
  /// 替换：后一次调用覆盖前一次，没有"清空图像源"的第三条（装空串报错）。
  fn set_widget_image_path(Self, NativeHandle, String) -> Unit raise UiError
  fn set_widget_image_bytes(Self, NativeHandle, Bytes) -> Unit raise UiError
  /// 系统托盘（`T86⑥`）：图标 + 菜单，托盘是进程级单例（一个应用一只），
  /// 不占句柄表——弹托盘一个 MoonUI 句柄都不建，与剪贴板/对话框同一条理由。
  /// 图标参数沿 `set_app_icon` 的 stem 约定；菜单选中的语义同 `show_context_menu`
  /// （同步解析，`T86⑥` 落地注记），点击动作/气泡的第一版不做（欠账）。
  fn set_tray_icon(Self, name : String) -> Unit raise UiError
  fn set_tray_menu(Self, menu : Menu) -> Unit raise UiError
  /// 系统通知（`T86⑥`）：一条 `notify(title, body)`，投出去即返回（投递是
  /// 异步的）；点击动作第一版不做（欠账）。
  fn notify(Self, title : String, body : String) -> Unit raise UiError
}

///|
/// `Backend` 的无头实现：不依赖任何 GUI 库，用于 §37 第一/第二层测试，
/// 也让 CI 在没有原生 GUI 库的环境下照样能跑完整生命周期。
pub struct MockWindow {
  mut title : String
  mut size : LogicalSize
  mut origin : LogicalPoint
  mut visible : Bool
  mut resizable : Bool
  mut fullscreen : Bool
  /// 客户区最小尺寸（§12），`None` = 没设过。mock 只记录状态，测试靠它断言
  /// "`Window::set_min_size` 真的推到了后端"（这条要是只存在 Core 里，用户拖
  /// 窗格时谁也拦不住）。
  mut min_size : LogicalSize?
  /// 拖拽改尺寸的实时重排开关（live redraw），默认开。mock 只记录状态；
  /// `push_live_resize` 拿它决定同步直达还是入队。
  mut live_redraw : Bool
  /// 窗口态（`T86②`）。mock 只记录状态；最小化/最大化的窗口管理是原生层的
  /// 事实，测试靠 `window_state` 往返断言"调用真的到了后端"。
  mut minimized : Bool
  mut maximized : Bool
  /// 标题栏样式（§12）。mock 只记录状态，测试靠它断言"调用真的到了后端"。
  mut titlebar_style : TitlebarStyle
  /// 自绘顶条的拖动带高（`T116`），逻辑像素，0 = 没有。mock 只记录状态。
  mut drag_band : Double
  /// 红绿灯位置（§12），关闭按钮左上角相对窗口左上角的逻辑像素。mock 只记录状态。
  mut traffic_light_position : LogicalPoint
  mut scale : Scale
  /// 这只窗口所在那块屏的工作区，`None` = 测试没设过，退回"整块虚拟屏就是可用区"
  /// （单屏机器的形状，所以既有断言的数不变）。驱动 `Window::center` 的多屏那一半（`T42`）。
  mut work_area : LogicalRect?
  /// 子控件的层叠顺序，**从顶层到底层**——和 Win32 `EnumChildWindows` 的返回顺序
  /// 同向，所以 mock 里写下的层叠断言能原样搬到真后端上（§14、§48-15）。
  mut z_order : Array[NativeHandle]
  /// 焦点链，**按声明顺序**（先序）——Core 算好整份推下来（`T29`）。mock 没有原生
  /// 焦点机制，这份列表就是它的全部焦点状态，测试靠 `focus_chain` 读它断言"声明顺序
  /// 真的到了后端"。和 `z_order` 分开存：Stack 里两者不同（层叠倒序、焦点声明序）。
  mut focus_chain : Array[NativeHandle]
} derive(Debug, Eq)

///|
pub struct MockBackend {
  handles : HandleTable
  windows : Array[MockWindow]
  widgets : Array[MockWidget]
  /// 事件队列（`push_event` 注入、`poll_event` 排空）。`mut` 是 `push_live_resize`
  /// 合并旧 Resize 要换整份（数组字段本体仍只被 mock 自己碰）。
  mut queue : Array[Event]
  mut screen : LogicalSize
  mut appearance : Theme
  /// 宿主血统的注入底座（`HostPlatform` 的段注）。默认 `Unknown`——既有测试
  /// 站在"没有系统窗口钮"的基线上，与 Windows 同一条分支。
  mut host : HostPlatform
  // `T87`②/③ 进程级偏好的注入底座（沿 `T40` 的进程级覆盖先例——外观是
  // `set_appearance` 注入的同一形状）。默认 false = 偏好关：既有测试一个
  // 字不改就站在"没开偏好"的基线上（reduced-motion 判据的负控制）。
  mut prefers_reduced_motion : Bool
  mut prefers_high_contrast : Bool
  mut cursor : Int32
  mut clipboard : String?
  // §24 的脚本化对话框：请求日志 + 两条按序消费的应答队列
  dialog_log : Array[String]
  confirm_replies : Array[Bool]
  mut confirm_cursor : Int32
  path_replies : Array[String?]
  mut path_cursor : Int32
  // §25 的菜单栏快照、安装次数，与 Core 推给后端的勾选态流水（§48-20）
  mut menu_bar : MenuBar?
  mut menu_installs : Int32
  menu_checks : Array[(Int32, Bool)]
  // 最后一次 set_app_icon 的 stem 快照（§26），None = 没设过图标
  mut app_icon : String?
  // `T86①` 上下文菜单的 API 调用账：弹过几次 + 最后一份配置的菜单快照
  mut context_menu_installs : Int32
  mut context_menu_last : Menu?
  // `T86⑥` 托盘/通知的 API 调用账：图标 stem、最后一份托盘菜单、装过几次，
  // 通知按投递顺序记 "notify:标题|正文"（与 dialog_log 同形）
  mut tray_icon : String?
  mut tray_menu : Menu?
  mut tray_installs : Int32
  notify_log : Array[String]
  // 主题底样式（皮肤账）：set_theme_base 记账，原生后端拿它分"继承 vs 显式"。
  mut theme_base : Style?
  // 实时直达通道（live dispatch）：`App::new` 装 `fn(ev) { app.dispatch(ev) }`。
  // `push_live_resize` / `push_window_moved` 分流时用它；None = 没人接，照旧入队。
  mut live_dispatch : ((Event) -> Unit raise UiError)?
  // T84 判据③的读数底座：bounds / opacity 的推送流水，按推送顺序记
  // (句柄 id, 值)。mock 本无屏幕，流水只为"激活期每帧恰好一批推送、退场后
  // 零推送"可断言——既有断言一个字不依赖它，不加这两条行为不变。
  bounds_log : Array[(Int32, LogicalRect)]
  opacity_log : Array[(Int32, Double)]
  // `T152`：等待上限的当前值与推送流水。mock 不阻塞，所以这两个只为
  // "Core 把到期时刻真的推下来了、空账又收回去了"可断言——既有断言不依赖它。
  mut wait_cap : Int32
  wait_cap_log : Array[Int32]
  /// `T152`：`poll_event` 进门时回调一次。判"任务改的文案有没有在睡着之前
  /// 落成帧"只能在这一刻读数——`flush_layout` 放在 `poll_event` 之前还是之后，
  /// 一圈跑完的终态完全一样，只有进门那一瞬分得开。
  mut poll_probe : (() -> Unit)?
  /// `T154`：模拟"原生侧请求退出"（mac 默认菜单的 ⌘Q、Win32 的 WM_CLOSE
  /// 兜底都是这条路——它们不知道 Core 存在）。判据点它一下，`quit_pending`
  /// 就开始答 `true`。
  mut native_quit_requested : Bool
  mut initialized : Bool
}

///|
pub fn MockBackend::new() -> MockBackend {
  MockBackend::{
    handles: HandleTable::new(),
    windows: [],
    widgets: [],
    queue: [],
    screen: LogicalSize(1920.0, 1080.0),
    // 默认固定为 Light，测试才能对配色做稳定断言（§16）
    appearance: Light,
    host: Unknown,
    prefers_reduced_motion: false,
    prefers_high_contrast: false,
    cursor: 0,
    clipboard: None,
    dialog_log: [],
    confirm_replies: [],
    confirm_cursor: 0,
    path_replies: [],
    path_cursor: 0,
    menu_bar: None,
    menu_installs: 0,
    menu_checks: [],
    app_icon: None,
    context_menu_installs: 0,
    context_menu_last: None,
    tray_icon: None,
    tray_menu: None,
    tray_installs: 0,
    notify_log: [],
    theme_base: None,
    live_dispatch: None,
    bounds_log: [],
    opacity_log: [],
    wait_cap: -1,
    wait_cap_log: [],
    poll_probe: None,
    native_quit_requested: false,
    initialized: false,
  }
}

///|
/// 测试侧设置虚拟屏幕尺寸，驱动 `Window::center`。
pub fn MockBackend::set_screen_size(
  self : MockBackend,
  size : LogicalSize,
) -> Unit {
  self.screen = size.non_negative()
}

///|
/// 测试侧设置"这只窗口所在那块屏的工作区"，驱动多屏那半的 `Window::center`（`T42`）。
/// 真实后端没有这条：那块屏是系统的事实，mock 里它是注入的，两者都由"窗口摆位用的
/// 那套坐标"来解释。origin 不夹非负——Win32 上副屏在主屏左边或上边时绝对坐标就是负的。
pub fn MockBackend::set_window_work_area(
  self : MockBackend,
  h : NativeHandle,
  area : LogicalRect,
) -> Unit raise UiError {
  let w = self.window(h)
  w.work_area = Some(LogicalRect(area.origin, area.size.non_negative()))
}

///|
/// 测试侧注入系统外观，驱动 `Theme::System` 的解析（§16）。
pub fn MockBackend::set_appearance(self : MockBackend, t : Theme) -> Unit {
  self.appearance = t
}

///|
/// 测试侧注入"减少动态效果"偏好（`T87`③ 判据的 Mock 可模拟点，`T40`
/// 进程级覆盖先例）：开着后动画泵把激活账当圈推精确落点（判据在
/// `animation_test.mbt` 的 `T87` 块）。默认 false = 偏好关，既有测试不站在
/// 注入过的基线上。
pub fn MockBackend::set_prefers_reduced_motion(
  self : MockBackend,
  v : Bool,
) -> Unit {
  self.prefers_reduced_motion = v
}

///|
/// 测试侧注入"增强对比度"偏好（`T87`②）。首版只做读口与这条注入口，
/// 消费点（主题读数档）第二版接。
pub fn MockBackend::set_prefers_high_contrast(
  self : MockBackend,
  v : Bool,
) -> Unit {
  self.prefers_high_contrast = v
}

///|
/// 脚本化确认框应答（§24）：按入队顺序依次消费，队列空时答"否"。
pub fn MockBackend::push_confirm_reply(self : MockBackend, v : Bool) -> Unit {
  self.confirm_replies.push(v)
}

///|
/// 脚本化文件/文件夹选择应答；`None` 表示用户取消。
pub fn MockBackend::push_path_reply(self : MockBackend, path : String?) -> Unit {
  self.path_replies.push(path)
}

///|
/// 已经弹出的对话框请求，形如 `confirm:标题|正文`，供集成断言（§37）。
pub fn MockBackend::dialog_requests(self : MockBackend) -> Array[String] {
  self.dialog_log
}

///|
/// 未被消费的脚本应答条数；Demo 用它断言"该问的都问了、没多问"。
pub fn MockBackend::pending_dialog_replies(self : MockBackend) -> Int32 {
  self.confirm_replies.length() -
  self.confirm_cursor +
  (self.path_replies.length() - self.path_cursor)
}

///|
/// 注入一个事件，模拟原生回调（§9 的 trampoline 落点）。
pub fn MockBackend::push_event(self : MockBackend, ev : Event) -> Unit {
  self.queue.push(ev)
}

///|
/// 模拟**用户拖拽**改尺寸（与程序化 `set_window_size` 相对——那条是应用自己改
/// 的，不算"拖"）。先落尺寸，再按实时重排开关分流，与真后端 `push_resize`
/// 同一套语义：
/// - 开关开 + 装了实时通道 → 同步直达 dispatch（拖拽跑在系统模态循环里，
///   `App::step` 泵不动队列，走队列就得等松手——那正是"拖的时候内容不跟手"）；
/// - 其余 → 入队等 `step` 排空，且**把同目标还没排走的旧 Resize 合并掉**：
///   关掉实时的复杂应用要的是"松手后重排一次"，不是"松手后重排 N 次"。
///
/// 处理器的失败就地吞掉（真后端的原生回调栈上没有传出 `UiError` 的路，
/// mock 保持同一条纪律）。
pub fn MockBackend::push_live_resize(
  self : MockBackend,
  h : NativeHandle,
  size : LogicalSize,
) -> Unit {
  try {
    let w = self.window(h)
    w.size = size.non_negative()
    let target = EventTarget::of(h)
    let ev = Resize(target, w.size)
    match self.live_dispatch {
      Some(f) =>
        if w.live_redraw {
          f(ev) catch {
            _ => ()
          }
          return
        }
      None => ()
    }
    let kept : Array[Event] = []
    for e in self.queue {
      let stale = match e {
        Resize(t, _) => t == target
        _ => false
      }
      if !stale {
        kept.push(e)
      }
    }
    self.queue = kept
    self.queue.push(ev)
  } catch {
    _ => ()
  }
}

///|
/// 模拟**用户拖动窗口**到 `p`（与程序化 `set_window_position` 相对——那条是
/// 应用自己摆的，不算"拖"）。先把窗口的落点改掉，再按与真后端 `push_move`
/// 同一条口径分流：
/// - 装了实时通道（`App::new` 会装）→ 同步直达 dispatch（拖拽跑在系统模态
///   循环里，`App::step` 泵不动队列，走队列就得等松手——那正是"拖的时候
///   吸附联动延迟跟"）；
/// - 其余 → 入队等 `step` 排空，且**把同目标还没排走的旧 Moved 合并掉**：
///   松手后一次性追上。
///
/// 处理器的失败就地吞掉（真后端的原生回调栈上没有传出 `UiError` 的路，
/// mock 保持同一条纪律）。
///
/// 程序化 `set_window_position` 不发这条，正因为原生侧把程序化移动的回声
/// 抑制掉了（`suppress_move`，见 adapter.h 的 on_moved 契约）。
pub fn MockBackend::push_window_moved(
  self : MockBackend,
  h : NativeHandle,
  p : LogicalPoint,
) -> Unit {
  try {
    let w = self.window(h)
    w.origin = p
    let target = EventTarget::of(h)
    let ev = Moved(target, p)
    match self.live_dispatch {
      Some(f) => {
        f(ev) catch {
          _ => ()
        }
        return
      }
      None => ()
    }
    let kept : Array[Event] = []
    for e in self.queue {
      let stale = match e {
        Moved(t, _) => t == target
        _ => false
      }
      if !stale {
        kept.push(e)
      }
    }
    self.queue = kept
    self.queue.push(ev)
  } catch {
    _ => ()
  }
}

///|
/// 模拟**用户拖了一段滑块**：控件自己的值先落，再发 `Change`（原生侧的次序
/// 就是"内层值已由 AppKit / Trackbar 更新 → fire"，见 mac 半 `-sliderMoved:`）。
///
/// 与真后端 `NativeBackend::push_value_change` 同一条口径（`T149`）：滑块拖动
/// 跑在控件自己的模态跟踪循环里，`App::step` 泵不动队列——装了实时通道就同步
/// 直达 dispatch，没装照旧入队。勾选框/下拉/日期选择器**没有**这条（它们不在
/// 模态循环里，入队下一圈就派发），所以 mock 也只给滑块这一支。
///
/// 处理器的失败就地吞掉：原生回调栈上没有能把 `UiError` 传出去的路。
pub fn MockBackend::push_value_change(
  self : MockBackend,
  h : NativeHandle,
  v : Int32,
) -> Unit {
  try {
    let w = self.widget(h)
    match w.kind {
      Slider => w.value = v
      _ => ()
    }
    let ev = Change(EventTarget::of(h))
    match self.live_dispatch {
      Some(f) => f(ev) catch { _ => () }
      None => self.queue.push(ev)
    }
  } catch {
    _ => ()
  }
}

///|
/// 模拟"用户点了菜单项 N"：等价于原生层送来 MenuSelect（§25）。
pub fn MockBackend::push_menu_select(self : MockBackend, id : Int32) -> Unit {
  self.queue.push(MenuSelect(EventTarget::{ id, generation: 0, }))
}

///|
/// 当前安装在后端侧的菜单栏。未初始化时抛错，和别的读取一样。
pub fn MockBackend::installed_menu_bar(
  self : MockBackend,
) -> MenuBar? raise UiError {
  self.check_initialized()
  self.menu_bar
}

///|
/// `set_menu_bar` 被调用过几次（重复安装是允许的，真实后端会整棵重建）。
pub fn MockBackend::menu_install_count(self : MockBackend) -> Int32 {
  self.menu_installs
}

///|
/// Core 推给后端的勾选态，按推送顺序记 `(菜单项 id, 新状态)`（§48-20）。
/// 集成测试用它断言"用户点了一下，原生那边确实被告知了"，而不必依赖对象身份；
/// Radio 一次点击会来一组（同组全推，见 `App::sync_menu_checks`）。
pub fn MockBackend::menu_check_log(self : MockBackend) -> Array[(Int32, Bool)] {
  self.menu_checks
}

///|
/// 最后一次 `set_app_icon` 传入的 stem（§26），None = 没设过图标。
pub fn MockBackend::app_icon(self : MockBackend) -> String? {
  self.app_icon
}

///|
/// `T86①` 判据的读数口：上下文菜单弹过几次（重复弹是允许的，每次右键都弹）。
pub fn MockBackend::context_menu_install_count(self : MockBackend) -> Int32 {
  self.context_menu_installs
}

///|
/// 最后一次 `show_context_menu` 收到的菜单快照，None = 没弹过。
pub fn MockBackend::context_menu_last(self : MockBackend) -> Menu? {
  self.context_menu_last
}

///|
/// 最后一次 `set_tray_icon` 收到的 stem（`T86⑥`），None = 没设过。
pub fn MockBackend::tray_icon(self : MockBackend) -> String? {
  self.tray_icon
}

///|
/// 最后一次 `set_tray_menu` 收到的菜单快照（`T86⑥`），None = 没装过。
pub fn MockBackend::tray_menu(self : MockBackend) -> Menu? {
  self.tray_menu
}

///|
/// `set_tray_menu` 被调用过几次。
pub fn MockBackend::tray_install_count(self : MockBackend) -> Int32 {
  self.tray_installs
}

///|
/// `T86⑥` 判据的读数口：按投递顺序的通知流水，形如 `"notify:标题|正文"`。
pub fn MockBackend::notify_log(self : MockBackend) -> Array[String] {
  self.notify_log
}

///|
/// T84 判据③读数口：`set_widget_bounds` 的推送流水 `(句柄 id, 矩形)`，按
/// 推送顺序。动画测试拿它断言"激活期每帧恰好一批推送、退场后零推送"；
/// 拿流水不要快照记条数比较（`log.length()` 的差值就是那几圈的推送数）。
pub fn MockBackend::bounds_push_log(
  self : MockBackend,
) -> Array[(Int32, LogicalRect)] {
  self.bounds_log
}

///|
/// T84 opacity 通道的推送流水 `(句柄 id, 0..1 值)`，口径同 bounds 流水：
/// "激活期每帧恰好一批、退场帧推精确落点"靠它逐值断言。
pub fn MockBackend::opacity_push_log(
  self : MockBackend,
) -> Array[(Int32, Double)] {
  self.opacity_log
}

///|
/// 存活的句柄总数（窗口 + 控件），泄漏检查用。
pub fn MockBackend::live(self : MockBackend) -> Int32 {
  self.handles.live()
}

///|
/// `T152` 测试用：读回当前等待上限与整条推送流水（字段对包外不可读）。
/// 流水是判据的尺子——"有定时账时推了、空账时收回来了"靠它断言。

///|
/// `T154`：模拟原生侧的退出请求。真机上是 mac 默认「应用」菜单的 ⌘Q 直呼
/// `moonui_native_quit()`、Win32 的 `WM_CLOSE` 兜底那一类——**不经过 Core**，
/// 所以 `App::quit` 那条账一个字都不会动。判据拿它复现"只有后端知道要退出"。
pub fn MockBackend::request_native_quit(self : MockBackend) -> Unit {
  self.native_quit_requested = true
}

///|
/// `T152`：装 `poll_event` 进门探针（判"文案在睡着之前就落成帧"用，见字段注）。
pub fn MockBackend::set_poll_probe(
  self : MockBackend,
  f : (() -> Unit)?,
) -> Unit {
  self.poll_probe = f
}

///|
pub fn MockBackend::wait_caps(self : MockBackend) -> (Int32, Array[Int32]) {
  (self.wait_cap, self.wait_cap_log)
}

///|
/// 读回某只窗的最小尺寸（测试用——`MockWindow` 的字段对包外不可读，
/// 示例与跨包用例走这条）。没设过是 `None`。
pub fn MockBackend::window_min_size(
  self : MockBackend,
  h : NativeHandle,
) -> LogicalSize? raise UiError {
  self.window(h).min_size
}

///|
/// 读回这只窗的实时重排开关（测试用——字段对包外不可读）。默认开。
pub fn MockBackend::window_live_redraw(
  self : MockBackend,
  h : NativeHandle,
) -> Bool raise UiError {
  self.window(h).live_redraw
}

///|
/// 句柄表统计读数（`T88①`）：live + 高水位成对读出。与 `live` 并存——
/// 单点读数沿旧账，成对读数给"峰值多少、当下多少"的泄漏排查。原生后端
/// 的表在 native-common 的 ffi 半（全局 `handles`），要暴露读数时按同一
/// 形状接（`T88` 落地注记：判据在 Mock 上闭环，原生半零动）。
pub fn MockBackend::handle_stats(self : MockBackend) -> HandleStats {
  self.handles.stats()
}

///|
/// 读取窗口状态，句柄失效或指向控件时抛 `InvalidHandle`。
pub fn MockBackend::window(
  self : MockBackend,
  h : NativeHandle,
) -> MockWindow raise UiError {
  self.check_initialized()
  let index = self.window_slot(h)
  let w = match self.windows_at(index) {
    Some(w) => w
    None => raise InvalidHandle
  }
  w
}

///|
/// 读取控件状态，句柄失效或指向窗口时抛 `InvalidHandle`。
pub fn MockBackend::widget(
  self : MockBackend,
  h : NativeHandle,
) -> MockWidget raise UiError {
  self.check_initialized()
  let index = self.widget_slot(h)
  let w = match self.widgets_at(index) {
    Some(w) => w
    None => raise InvalidHandle
  }
  w
}

///|
/// 自定义绘制面最近一次的整份绘制清单（`T101` 的断言口，`T107` 起被
/// `packages/widgets` 的判据消费）；`None` = 还没画过。
///
/// 为什么需要这个口子：清单只交给后端、Core 不缓存（见 `paint_custom` 段注），
/// 而 `MockWidget` 的字段对包外不可见——控件包要断言"这一帧画了什么"就只剩
/// 这一条路。与 `scroll_content_of` 同一条思路：mock 的账本得能被读，否则
/// "画对了没有"就只能靠肉眼看窗口。
pub fn MockBackend::drawn(
  self : MockBackend,
  h : NativeHandle,
) -> DrawList? raise UiError {
  self.widget(h).custom_draw
}

///|
/// 这块自绘面声明了要键盘焦点没有（`T102` 第十一刀）。与 `drawn` 同一条
/// 理由：`MockWidget` 的字段包外看不见，控件包要断言"我的面真的 opt-in 了"
/// 就只剩这一条读口。
pub fn MockBackend::custom_focusable(
  self : MockBackend,
  h : NativeHandle,
) -> Bool raise UiError {
  self.widget(h).focusable
}

///|
/// 窗口的子控件层叠顺序，从顶层到底层（§14、§48-15）。真后端上同一个顺序由
/// `EnumChildWindows` 给出，所以两边的断言能对上。
pub fn MockBackend::child_z_order(
  self : MockBackend,
  window : NativeHandle,
) -> Array[NativeHandle] raise UiError {
  self.window(window).z_order
}

///|
/// 窗口的焦点链，按声明顺序（先序）（`T29`）。和 `child_z_order` 分开读：Stack 里
/// 层叠是倒序、焦点是声明序，两者不同。
pub fn MockBackend::focus_chain(
  self : MockBackend,
  window : NativeHandle,
) -> Array[NativeHandle] raise UiError {
  self.window(window).focus_chain
}

///|
/// 摘掉一个句柄后的 z-order；不在列表里就原样返回。
fn z_order_without(
  order : Array[NativeHandle],
  h : NativeHandle,
) -> Array[NativeHandle] {
  let rest : Array[NativeHandle] = []
  for x in order {
    if x != h {
      rest.push(x)
    }
  }
  rest
}

///|
/// `to_top` = 提到最上层，否则落到最底层，两种都先把已在列表里的摘掉。
/// 语义照抄 Win32 的 `SetWindowPos(HWND_TOP / HWND_BOTTOM)`。
fn z_order_move(
  order : Array[NativeHandle],
  h : NativeHandle,
  to_top : Bool,
) -> Array[NativeHandle] {
  let rest = z_order_without(order, h)
  let out : Array[NativeHandle] = []
  if to_top {
    out.push(h)
  }
  for x in rest {
    out.push(x)
  }
  if !to_top {
    out.push(h)
  }
  out
}

///|
/// 句柄 -> 槽位。mock 把"指针"编码成 `槽位下标 * 2 + 类型位`
/// （0 是窗口，1 是控件），于是窗口和控件能共用一张句柄表，
/// `EventTarget.id` 因此全局唯一；类型位不符就是句柄用错了对象。
fn MockBackend::slot_of(
  self : MockBackend,
  h : NativeHandle,
  want_widget : Bool,
) -> Int32 raise UiError {
  let NativePtr(ptr) = self.handles.resolve(h)
  let is_widget = ptr % 2 == 1
  if is_widget != want_widget {
    raise InvalidHandle
  }
  (ptr / 2).to_int()
}

///|
fn MockBackend::window_slot(
  self : MockBackend,
  h : NativeHandle,
) -> Int32 raise UiError {
  self.slot_of(h, false)
}

///|
fn MockBackend::widget_slot(
  self : MockBackend,
  h : NativeHandle,
) -> Int32 raise UiError {
  self.slot_of(h, true)
}

///|
fn MockBackend::windows_at(self : MockBackend, index : Int32) -> MockWindow? {
  if index >= 0 && index < self.windows.length() {
    Some(self.windows[index])
  } else {
    None
  }
}

///|
fn MockBackend::widgets_at(self : MockBackend, index : Int32) -> MockWidget? {
  if index >= 0 && index < self.widgets.length() {
    Some(self.widgets[index])
  } else {
    None
  }
}

///|
fn MockBackend::check_initialized(self : MockBackend) -> Unit raise UiError {
  if !self.initialized {
    raise InitializationFailed("Backend 尚未初始化")
  }
}

///|
pub impl Backend for MockBackend with fn init(self) {
  self.initialized = true
}

///|
pub impl Backend for MockBackend with fn terminate(self) {
  // 遗留窗口在这里统一注销，保证 §47 风险 2 的"退出时句柄表归零"可断言
  for h in self.handles.alive_handles() {
    self.handles.unregister(h) catch {
      _ => ()
    }
  }
  self.initialized = false
}

///|
pub impl Backend for MockBackend with fn poll_event(self) -> Event? {
  // `T152`：进门那一刻的探针（见字段注）。先跑再取，探针里读到的是"睡前"
  // 的帐——真后端在这里一睡就是几百毫秒，帧没落定就露出去了。
  match self.poll_probe {
    Some(f) => f()
    None => ()
  }
  let ev = if self.cursor < self.queue.length() {
    Some(self.queue[self.cursor])
  } else {
    None
  }
  match ev {
    Some(_) => self.cursor = self.cursor + 1
    None => ()
  }
  ev
}

///|
/// `T152`：Core 推下来的等待上限。mock 的 `poll_event` 本来就不阻塞（队列空
/// 即返回 `None`），所以这里只记账——判据靠 `wait_cap_log` 断言"Core 真的
/// 把到期时刻交下来了、没有定时账时又收回去了"。
pub impl Backend for MockBackend with fn set_wait_cap(self, ms) -> Unit {
  self.wait_cap = ms
  self.wait_cap_log.push(ms)
}

///|
/// `T154`：注入值读回，与 `host_platform` 同一条形状（问一次拿一份快照）。
pub impl Backend for MockBackend with fn quit_pending(self) -> Bool {
  self.native_quit_requested
}

///|
/// 自绘后端的续命信号（`T31`）：请求后下一圈 `poll_event` 能取到一条 `Frame`。
/// 这里直接入队，target 用这只窗口的句柄（id + generation 一起带走，`T49`）。
pub impl Backend for MockBackend with fn request_redraw(self, h) -> Unit raise UiError {
  let _w = self.window(h)
  self.queue.push(Frame(EventTarget::of(h)))
}

///|
pub impl Backend for MockBackend with fn create_window(self, title, size) -> NativeHandle raise UiError {
  self.check_initialized()
  let index = self.windows.length()
  self.windows.push(MockWindow::{
    title,
    size: size.non_negative(),
    origin: LogicalPoint(0.0, 0.0),
    visible: false,
    resizable: true,
    fullscreen: false,
    min_size: None,
    live_redraw: true,
    minimized: false,
    maximized: false,
    titlebar_style: TitlebarStyle::Standard,
    drag_band: 0.0,
    traffic_light_position: LogicalPoint(0.0, 0.0),
    scale: Scale::one(),
    work_area: None,
    z_order: [],
    focus_chain: [],
  })
  let h = self.handles.register(NativePtr((index * 2).to_int64()))
  h
}

///|
pub impl Backend for MockBackend with fn destroy_window(self, h) -> Unit raise UiError {
  self.check_initialized()
  let _ = self.window_slot(h)
  self.handles.unregister(h)
}

///|
pub impl Backend for MockBackend with fn set_window_title(self, h, title) -> Unit raise UiError {
  let w = self.window(h)
  w.title = title
}

///|
pub impl Backend for MockBackend with fn set_window_size(self, h, size) -> Unit raise UiError {
  let w = self.window(h)
  w.size = size.non_negative()
}

///|
/// mock 只记录；真后端才把这条落成系统级钳位（mac `contentMinSize`、
/// Win32 `WM_GETMINMAXINFO`）。
pub impl Backend for MockBackend with fn set_window_min_size(self, h, size) -> Unit raise UiError {
  let w = self.window(h)
  w.min_size = size
}

///|
/// mock 只记录；真后端拿它在 `push_resize` 里决定拖拽时实时重排还是照旧入队。
pub impl Backend for MockBackend with fn set_window_live_redraw(self, h, on) -> Unit raise UiError {
  let w = self.window(h)
  w.live_redraw = on
}

///|
/// 实时直达通道记账（mock）。`App::new` 装的就是 `fn(ev) { app.dispatch(ev) }`。
pub impl Backend for MockBackend with fn set_live_dispatch(self, f) -> Unit {
  self.live_dispatch = f
}

///|
pub impl Backend for MockBackend with fn show_window(self, h) -> Unit raise UiError {
  let w = self.window(h)
  w.visible = true
}

///|
pub impl Backend for MockBackend with fn hide_window(self, h) -> Unit raise UiError {
  let w = self.window(h)
  w.visible = false
}

///|
pub impl Backend for MockBackend with fn window_scale(self, h) -> Scale raise UiError {
  let w = self.window(h)
  w.scale
}

///|
pub impl Backend for MockBackend with fn screen_size(self) -> LogicalSize raise UiError {
  self.check_initialized()
  self.screen
}

///|
/// 没设过就是"整块虚拟屏都是可用区"，也就是单屏机器的形状（`T42`）。
pub impl Backend for MockBackend with fn window_work_area(self, h) -> LogicalRect raise UiError {
  self.check_initialized()
  let w = self.window(h)
  match w.work_area {
    Some(a) => a
    None => LogicalRect(LogicalPoint(0.0, 0.0), self.screen)
  }
}

///|
pub impl Backend for MockBackend with fn system_theme(self) -> Theme raise UiError {
  self.check_initialized()
  self.appearance
}

///|
/// mock 的宿主血统默认 `Unknown`（= 没有系统窗口钮，与 Windows 同一条分支），
/// `set_host_platform` 可以注入成 `Macos` 去验另一支。这里**不**查初始化：
/// 血统是编译期常量，没 init 也答得出来（这条不 raise，`check_initialized`
/// 也进不来）。
pub impl Backend for MockBackend with fn host_platform(self) -> HostPlatform {
  self.host
}

///|
/// 注入宿主血统（`HostPlatform`）。示例里"按平台决定要不要画窗口钮"的分支
/// 因此可以在 mock 上验两支：默认 `Unknown`（自绘那一支），设成 `Macos`
/// 之后同一棵树就长成"只有红绿灯、没有自绘钮"的样子。
pub fn MockBackend::set_host_platform(
  self : MockBackend,
  host : HostPlatform,
) -> Unit {
  self.host = host
}

///|
/// 进程级偏好读数（`T87`②/③）：mock 里就是注入值读回，与 `system_theme`
/// 同一条形状——问一次拿一份快照。
pub impl Backend for MockBackend with fn get_prefers_reduced_motion(self) -> Bool raise UiError {
  self.check_initialized()
  self.prefers_reduced_motion
}

///|
pub impl Backend for MockBackend with fn get_prefers_high_contrast(self) -> Bool raise UiError {
  self.check_initialized()
  self.prefers_high_contrast
}

///|
pub impl Backend for MockBackend with fn window_size(self, h) -> LogicalSize raise UiError {
  let w = self.window(h)
  w.size
}

///|
pub impl Backend for MockBackend with fn set_window_position(self, h, origin) -> Unit raise UiError {
  let w = self.window(h)
  w.origin = origin
}

///|
pub impl Backend for MockBackend with fn window_position(self, h) -> LogicalPoint raise UiError {
  let w = self.window(h)
  w.origin
}

///|
pub impl Backend for MockBackend with fn set_window_resizable(self, h, v) -> Unit raise UiError {
  let w = self.window(h)
  w.resizable = v
}

///|
pub impl Backend for MockBackend with fn set_window_fullscreen(self, h, v) -> Unit raise UiError {
  let w = self.window(h)
  // mock 只记录状态；全屏时窗口尺寸由系统接管，这里不动 size
  w.fullscreen = v
}

///|
pub impl Backend for MockBackend with fn set_window_titlebar_style(
  self,
  h,
  style,
) -> Unit raise UiError {
  let w = self.window(h)
  // mock 只记录状态；沉浸式那半（内容铺满、红绿灯浮在内容上）是原生层的事
  w.titlebar_style = style
}

///|
pub impl Backend for MockBackend with fn set_window_traffic_light_position(
  self,
  h,
  p,
) -> Unit raise UiError {
  let w = self.window(h)
  // mock 只记录状态；把红绿灯整簇挪过去（含 resize 时重新断言）是原生层的事
  w.traffic_light_position = p
}

///|
pub impl Backend for MockBackend with fn set_window_drag_band(self, h, height) -> Unit raise UiError {
  let w = self.window(h)
  // mock 只记录状态；"这一条竖带算标题栏、能拖着搬窗"是原生层的命中判定
  w.drag_band = height
}

///|
/// 测试侧设置缩放，模拟 HiDPI 屏幕。
pub fn MockBackend::set_window_scale(
  self : MockBackend,
  h : NativeHandle,
  scale : Scale,
) -> Unit raise UiError {
  let w = self.window(h)
  w.scale = scale
}

///|
pub impl Backend for MockBackend with fn clipboard_text(self) -> String? raise UiError {
  self.check_initialized()
  self.clipboard
}

///|
pub impl Backend for MockBackend with fn set_clipboard_text(self, text) -> Unit raise UiError {
  self.check_initialized()
  self.clipboard = Some(text)
}

///|
pub impl Backend for MockBackend with fn show_message(self, title, text) -> Unit raise UiError {
  self.check_initialized()
  self.dialog_log.push("message:" + title + "|" + text)
}

///|
pub impl Backend for MockBackend with fn confirm(self, title, text) -> Bool raise UiError {
  self.check_initialized()
  self.dialog_log.push("confirm:" + title + "|" + text)
  self.take_confirm()
}

///|
pub impl Backend for MockBackend with fn open_file(self, title) -> String? raise UiError {
  self.check_initialized()
  self.dialog_log.push("open:" + title)
  self.take_path()
}

///|
pub impl Backend for MockBackend with fn save_file(self, title, default_name) -> String? raise UiError {
  self.check_initialized()
  self.dialog_log.push("save:" + title + "|" + default_name)
  self.take_path()
}

///|
pub impl Backend for MockBackend with fn select_folder(self, title) -> String? raise UiError {
  self.check_initialized()
  self.dialog_log.push("folder:" + title)
  self.take_path()
}

///|
pub impl Backend for MockBackend with fn set_menu_bar(self, bar) -> Unit raise UiError {
  self.check_initialized()
  self.menu_bar = Some(bar)
  self.menu_installs = self.menu_installs + 1
}

///|
pub impl Backend for MockBackend with fn set_app_icon(self, name) -> Unit raise UiError {
  self.check_initialized()
  self.app_icon = Some(name)
}

///|
/// 只记流水，不真的弹——mock 没有屏幕。判据是调用账：右键路由到控件之后，
/// 框架确实按控件配的菜单请求了弹出（读数口在上面 `context_menu_install_count`
/// / `context_menu_last`）。
pub impl Backend for MockBackend with fn show_context_menu(self, menu) -> Unit raise UiError {
  self.check_initialized()
  self.context_menu_last = Some(menu)
  self.context_menu_installs = self.context_menu_installs + 1
}

///|
/// `T86②` 判据的存取半：只记状态，mock 没有窗口管理器。读回半在
/// `window_state` 里照原样吐——往返由测试钉。
pub impl Backend for MockBackend with fn set_window_minimized(self, h, v) -> Unit raise UiError {
  self.window(h).minimized = v
}

///|
pub impl Backend for MockBackend with fn set_window_maximized(self, h, v) -> Unit raise UiError {
  self.window(h).maximized = v
}

///|
pub impl Backend for MockBackend with fn window_state(self, h) -> WindowState raise UiError {
  let w = self.window(h)
  WindowState::{ minimized: w.minimized, maximized: w.maximized, }
}

///|
/// `T86⑤` 判据的记账半：图像源按 kind 拦（与 value/checked/datetime 同一条
/// 规矩——哪种控件有哪种属性），记最后一次的路径与字节数。
pub impl Backend for MockBackend with fn set_widget_image_path(self, h, path) -> Unit raise UiError {
  let w = self.widget(h)
  if w.kind != WidgetKind::Image {
    raise Unsupported("只有 Image 控件有图像源")
  }
  w.image_path = path
}

///|
pub impl Backend for MockBackend with fn set_widget_image_bytes(self, h, data) -> Unit raise UiError {
  let w = self.widget(h)
  if w.kind != WidgetKind::Image {
    raise Unsupported("只有 Image 控件有图像源")
  }
  w.image_len = data.length()
}

///|
/// `T86⑥` 判据的调用账：托盘是进程级单例（不占句柄表），mock 只记快照。
pub impl Backend for MockBackend with fn set_tray_icon(self, name) -> Unit raise UiError {
  self.check_initialized()
  self.tray_icon = Some(name)
}

///|
pub impl Backend for MockBackend with fn set_tray_menu(self, menu) -> Unit raise UiError {
  self.check_initialized()
  self.tray_menu = Some(menu)
  self.tray_installs = self.tray_installs + 1
}

///|
pub impl Backend for MockBackend with fn notify(self, title, body) -> Unit raise UiError {
  self.check_initialized()
  self.notify_log.push("notify:" + title + "|" + body)
}

///|
/// 只记流水，不改任何显示状态——mock 没有屏幕。它唯一尽的职责是句柄式的校验：
/// id 不在已安装的菜单栏里就报错（契约见 trait 的那段注释）。真后端把同一条校验
/// 放在原生层（找不到那个 id 就是没装上），所以两边的失败形态是一样的。
pub impl Backend for MockBackend with fn set_menu_item_checked(
  self,
  id,
  checked,
) -> Unit raise UiError {
  self.check_initialized()
  let found = match self.menu_bar {
    None => false
    Some(bar) =>
      match bar.find(id) {
        None => false
        Some(_) => true
      }
  }
  if !found {
    raise OperationFailed("菜单项 \{id} 不在已安装的菜单栏里")
  }
  self.menu_checks.push((id, checked))
}

///|
/// 按入队顺序取确认框应答；没有脚本时返回"否"——测试里的默认必须是安全的那一侧。
/// 走兜底分支时不推进游标，这样 `pending_dialog_replies` 始终等于未消费的脚本条数，
/// 不会因为多调了一次而变成负数。
fn MockBackend::take_confirm(self : MockBackend) -> Bool {
  if self.confirm_cursor < self.confirm_replies.length() {
    let v = self.confirm_replies[self.confirm_cursor]
    self.confirm_cursor = self.confirm_cursor + 1
    v
  } else {
    false
  }
}

///|
fn MockBackend::take_path(self : MockBackend) -> String? {
  if self.path_cursor < self.path_replies.length() {
    let v = self.path_replies[self.path_cursor]
    self.path_cursor = self.path_cursor + 1
    v
  } else {
    None
  }
}

///|
/// 显式把 `Backend` 的方法开放为点号方法。不写这条的话，测试里
/// `b.create_window(...)` 依赖的是已被标记为过时的隐式提升。
pub extend MockBackend with Backend::{
  init,
  terminate,
  poll_event,
  set_wait_cap,
  quit_pending,
  create_window,
  destroy_window,
  set_window_title,
  set_window_size,
  show_window,
  hide_window,
  window_scale,
  screen_size,
  window_work_area,
  window_size,
  set_window_position,
  window_position,
  set_window_resizable,
  set_window_fullscreen,
  set_window_titlebar_style,
  set_window_traffic_light_position,
  create_widget,
  create_ranged_widget,
  destroy_widget,
  set_widget_text,
  widget_text,
  set_widget_checked,
  widget_checked,
  set_widget_insets,
  set_widget_value,
  widget_value,
  set_widget_range,
  append_widget_option,
  set_widget_selected,
  widget_selected,
  set_widget_datetime,
  widget_datetime,
  set_widget_visible,
  widget_visible,
  set_widget_enabled,
  widget_enabled,
  set_widget_opacity,
  set_widget_style,
  set_widget_icon,
  set_theme_base,
  set_widget_accessibility,
  set_widget_bounds,
  widget_bounds,
  widget_intrinsic_size,
  attach_widget,
  detach_widget,
  raise_widget,
  set_paint_order,
  set_focus_chain,
  set_custom_focusable,
  clipboard_text,
  set_clipboard_text,
  system_theme,
  host_platform,
  get_prefers_reduced_motion,
  get_prefers_high_contrast,
  show_message,
  confirm,
  open_file,
  save_file,
  select_folder,
  set_menu_bar,
  set_menu_item_checked,
  show_context_menu,
  set_window_minimized,
  set_window_maximized,
  window_state,
  set_widget_image_path,
  set_widget_image_bytes,
  set_tray_icon,
  set_tray_menu,
  notify,
}

///|
test "MockBackend 生命周期：未初始化就创建窗口会失败" {
  let b = MockBackend::new()
  let msg = try {
    let _ = b.create_window("x", LogicalSize(100.0, 80.0))
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
  Backend::init(b)
  let h = b.create_window("x", LogicalSize(100.0, 80.0))
  assert_eq(b.live(), 1)
  Backend::destroy_window(b, h)
  assert_eq(b.live(), 0)
}

///|
test "MockBackend 窗口状态读写走句柄表" {
  let b = MockBackend::new()
  Backend::init(b)
  let h = b.create_window("MoonUI", LogicalSize(800.0, 600.0))
  assert_eq(b.window(h).title, "MoonUI")
  assert_false(b.window(h).visible)
  Backend::show_window(b, h)
  assert_true(b.window(h).visible)
  Backend::set_window_title(b, h, "MoonUI — 改名")
  assert_eq(b.window(h).title, "MoonUI — 改名")
  Backend::set_window_size(b, h, LogicalSize(640.0, 480.0))
  assert_eq(b.window(h).size.width, 640.0)
  // 负尺寸按零处理，原生层不会收到非法尺寸
  Backend::set_window_size(b, h, LogicalSize(-5.0, 10.0))
  assert_eq(b.window(h).size, LogicalSize(0.0, 10.0))
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "已销毁窗口的句柄不会命中新窗口" {
  let b = MockBackend::new()
  Backend::init(b)
  let first = b.create_window("A", LogicalSize(10.0, 10.0))
  Backend::destroy_window(b, first)
  let second = b.create_window("B", LogicalSize(20.0, 20.0))
  assert_eq(second.id, first.id)
  let msg = try {
    let _ = b.window(first)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("无效的原生句柄"))
  assert_eq(b.window(second).title, "B")
}

///|
test "事件队列按注入顺序取出且取空返回 None" {
  let b = MockBackend::new()
  Backend::init(b)
  let target = EventTarget::{ id: 7, generation: 0, }
  b.push_event(Click(target, Left))
  b.push_event(Close(target))
  assert_eq(Backend::poll_event(b), Some(Click(target, Left)))
  assert_eq(Backend::poll_event(b), Some(Close(target)))
  assert_eq(Backend::poll_event(b), None)
  // 队列空了之后再注入，仍可继续读取
  b.push_event(Change(target))
  assert_eq(Backend::poll_event(b), Some(Change(target)))
}

///|
test "剪贴板与 HiDPI 缩放因子" {
  let b = MockBackend::new()
  Backend::init(b)
  assert_eq(Backend::clipboard_text(b), None)
  Backend::set_clipboard_text(b, "界面")
  assert_eq(Backend::clipboard_text(b), Some("界面"))
  let h = b.create_window("x", LogicalSize(100.0, 100.0))
  assert_eq(Backend::window_scale(b, h), Scale::one())
  MockBackend::set_window_scale(b, h, Scale::{ x: 2.0, y: 2.0, })
  assert_eq(
    Backend::window_scale(b, h).to_physical_size(LogicalSize(100.0, 50.0)),
    PhysicalSize(200, 100),
  )
}

///|
test "窗口位置、可调整与全屏状态可读写" {
  let b = MockBackend::new()
  Backend::init(b)
  let h = b.create_window("Pos", LogicalSize(400.0, 300.0))
  assert_eq(Backend::window_position(b, h), LogicalPoint(0.0, 0.0))
  Backend::set_window_position(b, h, LogicalPoint(120.0, 60.0))
  assert_eq(Backend::window_position(b, h), LogicalPoint(120.0, 60.0))
  assert_eq(Backend::window_size(b, h), LogicalSize(400.0, 300.0))
  assert_true(b.window(h).resizable)
  Backend::set_window_resizable(b, h, false)
  assert_false(b.window(h).resizable)
  Backend::set_window_fullscreen(b, h, true)
  assert_true(b.window(h).fullscreen)
  // 标题栏样式（§12）：默认 Standard，设成 Immersive 后读回，再切回 Standard
  assert_eq(b.window(h).titlebar_style, TitlebarStyle::Standard)
  Backend::set_window_titlebar_style(b, h, TitlebarStyle::Immersive)
  assert_eq(b.window(h).titlebar_style, TitlebarStyle::Immersive)
  Backend::set_window_titlebar_style(b, h, TitlebarStyle::Standard)
  assert_eq(b.window(h).titlebar_style, TitlebarStyle::Standard)
  // 红绿灯位置（§12）：默认 (0,0)，设一个非零值后读回
  assert_eq(b.window(h).traffic_light_position, LogicalPoint(0.0, 0.0))
  Backend::set_window_traffic_light_position(b, h, LogicalPoint(12.0, 8.0))
  assert_eq(b.window(h).traffic_light_position, LogicalPoint(12.0, 8.0))
  assert_eq(Backend::screen_size(b), LogicalSize(1920.0, 1080.0))
  MockBackend::set_screen_size(b, LogicalSize(1000.0, 700.0))
  assert_eq(Backend::screen_size(b), LogicalSize(1000.0, 700.0))
  Backend::terminate(b)
  let msg = try {
    let _ = Backend::screen_size(b)
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
}

///|
test "terminate 回收未显式销毁的窗口" {
  let b = MockBackend::new()
  Backend::init(b)
  let _ = b.create_window("A", LogicalSize(10.0, 10.0))
  let _ = b.create_window("B", LogicalSize(10.0, 10.0))
  assert_eq(b.live(), 2)
  Backend::terminate(b)
  assert_eq(b.live(), 0)
  Backend::init(b)
  let h = b.create_window("C", LogicalSize(10.0, 10.0))
  assert_eq(b.live(), 1)
  Backend::destroy_window(b, h)
  assert_eq(b.live(), 0)
}

///|
/// `T86①` 判据（右键事件的命中路由 + 框架按配置弹上下文菜单）：右键按下到达
/// 这只控件时，控件自己的订阅命中一次，框架沿 `set_context_menu` 配的菜单
/// 请求弹出——调用账读回"弹过几次 + 弹的是哪份菜单"。事件到达与路由是判据
/// 的主体，弹出是同一发里顺带钉住的那格。
test "右键按下路由到控件且框架按配置请求弹出上下文菜单（T86①判据）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let win = app.create_window("ctx", LogicalSize(300.0, 200.0))
  let btn = Widget::button(b, "右键我")
  let _ = win.set_content(btn)
  win.show()
  let item = MenuItem::new("新建")
  let _ = item.on(fn(_) { () })
  let menu = Menu::new("文件", [Item(item)])
  btn.set_context_menu(menu)
  let mut routed_hits = 0
  let _ = btn.on(
    ev => {
      match ev {
        MouseDown(_, Right, _) => true
        _ => false
      }
    },
    fn(_) { routed_hits = routed_hits + 1 },
  )
  // 模拟原生层送来的右键按下：命中反查在 C（adapter 的 mouse_target），mock 里
  // 事件直接按 target 注入，路由与弹出都在同一发 dispatch 里。控件级 fire 的
  // 命中数不进 dispatch 的返回值（既有语义），判据由 routed_hits 与弹出账承担。
  let _ = app.dispatch(MouseDown(btn.target(), Right, LogicalPoint(12.0, 34.0)))
  assert_eq(routed_hits, 1)
  assert_eq(b.context_menu_install_count(), 1)
  match b.context_menu_last() {
    Some(m) => assert_eq(m.title(), "文件")
    None => fail("上下文菜单没有请求弹出")
  }
  // 重复配置不叠框架订阅：换一份菜单再右键，弹的还是恰好一次。
  let other = Menu::new("编辑", [Item(MenuItem::new("粘贴"))])
  btn.set_context_menu(other)
  let _ = app.dispatch(MouseDown(btn.target(), Right, LogicalPoint(1.0, 2.0)))
  assert_eq(b.context_menu_install_count(), 2)
  match b.context_menu_last() {
    Some(m) => assert_eq(m.title(), "编辑")
    None => fail("上下文菜单没有请求弹出")
  }
}

///|
/// `T86②` 判据（窗口态读回的存取往返）：两条 setter 写进去、`window_state`
/// 照原样吐出来——mock 只记账，往返由这条钉住。
test "窗口态读回的存取往返（T86②判据）" {
  let b = MockBackend::new()
  Backend::init(b)
  let h = b.create_window("态", LogicalSize(400.0, 300.0))
  // 初始两个位都是未按下
  let st0 = Backend::window_state(b, h)
  assert_false(st0.minimized)
  assert_false(st0.maximized)
  // 写进去再读回：mock 只记账，往返由这条钉住
  Backend::set_window_minimized(b, h, true)
  let st1 = Backend::window_state(b, h)
  assert_true(st1.minimized)
  assert_false(st1.maximized)
  Backend::set_window_maximized(b, h, true)
  let st2 = Backend::window_state(b, h)
  assert_true(st2.minimized && st2.maximized)
  Backend::set_window_minimized(b, h, false)
  Backend::set_window_maximized(b, h, false)
  let st3 = Backend::window_state(b, h)
  assert_false(st3.minimized || st3.maximized)
  Backend::terminate(b)
}

///|
/// `T86③` 判据（拖入路径事件的到达与内容）：外部文件拖入经 `FileDrop` 到达，
/// target 是接住的窗口、路径数组原样携带。
test "拖入路径事件的到达与内容（T86③判据）" {
  let b = MockBackend::new()
  Backend::init(b)
  let win = b.create_window("drop", LogicalSize(500.0, 400.0))
  let target = EventTarget::of(win)
  b.push_event(FileDrop(target, ["/Users/me/Desktop/a.png", "/tmp/b.md"]))
  match Backend::poll_event(b) {
    Some(FileDrop(t, paths)) => {
      assert_eq(t, target)
      assert_eq(paths, ["/Users/me/Desktop/a.png", "/tmp/b.md"])
    }
    Some(_) => fail("队列头不是 FileDrop")
    None => fail("事件没到达")
  }
  assert_true(Backend::poll_event(b) is None)
  Backend::terminate(b)
}

///|
/// `T86⑤` 判据（Image kind 的属性账）：图像控件走通用创建通道，源按两条
/// 通道装（记账半），错种类按 kind 拦在前头（与 value/checked 同一条规矩）。
test "Image kind 的属性账（T86⑤判据）" {
  let b = MockBackend::new()
  Backend::init(b)
  let img = Widget::image(b)
  let h = match img.handle {
    Some(h) => h
    None => fail("Image 控件必须有原生句柄")
  }
  assert_eq(b.widget(h).kind, WidgetKind::Image)
  img.set_image_path("/tmp/a.png")
  assert_eq(b.widget(h).image_path, "/tmp/a.png")
  img.set_image_bytes(b"\x89PNG")
  assert_eq(b.widget(h).image_len, 4)
  // 错种类：Image 专属的属性在别的控件上必须拦住。
  let lbl = Widget::label(b, "x")
  let msg = try {
    lbl.set_image_path("/tmp/b.png")
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("不支持的操作：只有 Image 控件有图像源"))
  Backend::terminate(b)
}

///|
/// `T86⑥` 判据（托盘/通知的 API 调用账）：托盘图标、托盘菜单按 stem/快照
/// 记账，通知按投递顺序记流水；未初始化的拒绝同既有语义。
test "托盘与通知的 API 调用账（T86⑥判据）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  let item = MenuItem::new("退出")
  let _ = item.on(fn(_) { () })
  app.set_tray_icon("moonui")
  app.set_tray_menu(Menu::new("托盘", [Item(item), Separator]))
  app.notify("同步完成", "今天也是 42 个任务")
  assert_eq(b.tray_icon(), Some("moonui"))
  assert_eq(b.tray_install_count(), 1)
  match b.tray_menu() {
    Some(m) => {
      assert_eq(m.title(), "托盘")
      assert_eq(m.item_count(), 1)
    }
    None => fail("托盘菜单没有记账")
  }
  assert_eq(b.notify_log(), ["notify:同步完成|今天也是 42 个任务"])
  // 未初始化的拒绝与既有读取同一条语义。
  Backend::terminate(b)
  let msg = try {
    app.notify("x", "y")
    None
  } catch {
    e => Some(UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
}
