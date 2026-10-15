///|
/// MoonUI 的前台门：构造 + init + `App::new` 三步一次做完。
///
/// `T82`（2026-10-15）删 libui 收敛单后端之前，这里是一个装箱枚举
/// `AnyBackend` 加 61 份 `Backend` trait 转发（moonc v0.10.15 上对象装箱各
/// 形状全部拒绝，枚举转发是保证可行的那条——经验记在 git log 里）；单后端
/// 之后枚举与转发全是恒等，门面缩成这一个函数，用户从此不 import
/// `native-common`、不构造后端结构、不管 init 时序。树代码拿到的
/// `App[NativeBackend]` 实现着 `@moonui.Backend`，`Gallery::demo(app)` 这类
/// 泛型调用一行不改。
///
/// ```moonbit nocheck
/// let app = @moonui_app.new_app()
/// let g = @moonui.Gallery::demo(app)
/// app.run()
/// ```
pub fn new_app() -> @moonui.App[@native-common.NativeBackend] raise @moonui.UiError {
  let b = @native-common.NativeBackend::new()
  b.init()
  let app = @moonui.App::new(b)
  // T84 帧钟接线（零 C——帧钟是 MoonBit 侧 pump 的账）：时刻从平台来
  // （现成的 native_time_ms，动画模块一行不读时钟）；激活期把 poll_event 的
  // 等待预算换成现成的 8ms 档，主循环每圈醒来推进插值，退场恢复 -1。
  // Mock 后端没有这条阻塞语义，帧钟在测试里是注入的参数。
  app.set_anim_clock(@native-common.native_time_ms)
  app.set_anim_wake(fn(active) { b.set_frame_budget(active) })
  app
}

///|
/// worker 与跨线程投递（`T85①`）：前台门的一条转发——门存在的意义就是用户不
/// import `native-common`，worker 这套机制也照这条规矩走。形状与契约见
/// backends/native-common/ffi.mbt 的 `worker_run`（adapter.h 的 worker 段注）：
/// `work` 在平台线程跑（不许 raise，worker 侧失败自己兜），`land` 被投回主循环
/// 泵消息那一刻的 UI 线程，落地动作是 `app.post(land)`——排队、下一圈执行、且
/// 排在原生事件之前（§27）。
pub fn worker_run(
  app : @moonui.App[@native-common.NativeBackend],
  work : () -> Unit,
  land : () -> Unit raise @moonui.UiError,
) -> Unit raise @moonui.UiError {
  @native-common.worker_run(app, work, land)
}
