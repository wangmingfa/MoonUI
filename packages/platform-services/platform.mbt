// `T231`（2026-11-08）：平台能力从 `Backend` 里拆出来，单独成 trait。
// `T239`（2026-11-08）：trait 连同实现与转发从 `packages/moonui` 迁到本包。
//
// 由来：DESIGN §19 原本只列 10 个概念方法，`Backend` 落地长到 93 个，最后
// 6 个（托盘 / 通知 / 媒体键 / 全局热键 / Now Playing）是 `lunamusic` 的应用
// 需求推进来的，与窗口、控件、绘制、事件这些 GUI 后端职责无关。代价不是
// 「接口多六行」，而是**每个新后端都必须实现整张表**——`CanvasBackend` 的
// 6 个 impl 全是转发给内嵌 `NativeBackend`，第三个真后端（Linux / GTK3）
// 要照抄整张表。
//
// 口径：**GUI 后端与平台能力分开，且能力不属于 Core**。`Backend` 只留 87 个
// GUI 本职方法，本 trait 是住在独立包里的**可选能力**——`Backend` 的实现义务
// 里不含这 6 条，纯 GUI 的第三后端可以完全不实现（编译期事实，由 detlint 的
// `backend-platform-capability` 与 `core-platform-leak` 两条基线 0 钉着）。
// 今天三份后端都实现了它，因为 `examples/lunamusic-canvas-native` 要跑
// lunamusic；**能力是否需要由应用决定，不由后端决定**，仓内没有「某后端
// 完全不实现」的实例，别把现状读成实证。
//
// 为什么 `: @moonui.Backend`（子 trait 而非并列）：MoonBit 无 `dyn`，应用侧
// `LunaMusicApp[B, A]` 的 B 是编译期泛型。若两者并列，应用要写
// `B : Backend + PlatformServices` 才会同时拿到两组方法，而 `--deny-warn` 下
// 多 bound 类型参数的点号调用会报 0083、约束还会沿调用链传染上百处签名。
// 让本 trait 继承 `Backend` 之后，需要平台服务的应用统一写**单约束**
// `B : PlatformServices` 就能同时拿到两组方法（87 + 6）；纯 GUI 应用继续用
// `B : Backend`。代价：实现本 trait 的类型必须先实现 `Backend`。
//
// 为什么 `App` 的三条转发是**自由函数**而不是方法（本包 `app.mbt`）：MoonBit
// 不允许给外部包的类型定义方法或 `extend`（4059 `Cannot define method ... for
// foreign type`，`/tmp` 最小探针实测）。`App::backend()` 是 Core 已有的公开
// 读数口，转发因此不需要在 Core 里新增任何 API。
//
// 音频播放**不在这里**：它是应用层 `AudioEngine` trait
// （`examples/lunamusic/engine.mbt`），由 `NativeAudioEngine` /
// `MockAudioEngine` 各自实现，直连 `@native-common.native_audio_*`。把应用层的
// 可替换实现硬塞进框架 trait 是反向扩张；换第三后端时这半会失联，见
// `API.md` §18 与 `TODO.md` `T237`。
//
// 实现者今天有三份：`@moonui.MockBackend`（实现落在本包 `mock.mbt`，因为 trait
// 在本包、类型在 Core——MoonBit 允许）、`NativeBackend`（转平台 C）、
// `CanvasBackend`（转发给内嵌 `NativeBackend`）。签名与 `T231` 时逐字一致。

///|
/// 系统托盘（`T86⑥`）：图标 + 菜单，托盘是进程级单例（一个应用一只），
/// 不占句柄表——弹托盘一个 MoonUI 句柄都不建，与剪贴板/对话框同一条理由。
/// 图标参数沿 `set_app_icon` 的 stem 约定；菜单选中的语义同 `show_context_menu`
/// （同步解析，`T86⑥` 落地注记），点击动作/气泡的第一版不做（欠账）。
pub(open) trait PlatformServices: @moonui.Backend {
  fn set_tray_icon(Self, name : String) -> Unit raise @moonui.UiError
  fn set_tray_menu(Self, menu : @moonui.Menu) -> Unit raise @moonui.UiError
  /// 系统通知（`T86⑥`）：一条 `notify(title, body)`，投出去即返回（投递是
  /// 异步的）；点击动作第一版不做（欠账）。
  fn notify(Self, title : String, body : String) -> Unit raise @moonui.UiError
  // ——媒体键与全局热键（`T181`）——
  // 命令码表（adapter.h 媒体键段同表，表外静默不猜）：
  //   0 = 播放/暂停切换   1 = 下一首   2 = 上一首
  /// 系统媒体键回调（耳机线控/键盘媒体键/控制中心）。重复调用换回调。
  /// **不 raise**：没接的平台（Windows 空桩）静默——回调永不触发就是"没接"
  /// 的形态，与 `set_rate` 的分量判断同一条；报错反而让每个启动点都得接住。
  fn on_media_key(Self, cb : (Int32) -> Unit) -> Unit
  /// 全局热键（窗口不在前台也收得到）。键位归平台半写死（mac：⌘⌥Space /
  /// ⌘⌥← / ⌘⌥→），MoonBit 侧只收上面的命令码——键位不是参数，配置 UI 不存在
  /// （owner 拍板）。**不 raise**，同上。
  fn set_global_hotkeys(Self, cb : (Int32) -> Unit) -> Unit
  /// 向系统「正在播放」（控制中心那块）推当前曲目。duration_ms <= 0 不推
  /// 时长；playing=false 时系统冻结进度。**推送时机归调用方**（签名边沿，
  /// 变了才推——心跳每拍调这里不假，推重的账在调用方）。**不 raise**，同上。
  fn set_now_playing(
    Self,
    title : String,
    artist : String,
    elapsed_ms : Int64,
    duration_ms : Int64,
    playing : Bool,
  ) -> Unit
}
