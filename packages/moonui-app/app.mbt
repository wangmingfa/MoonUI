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
  @moonui.App::new(b)
}
