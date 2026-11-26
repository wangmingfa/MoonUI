///|
/// 自绘后端的 Windows 壳（`T391`）：实现只一份（../canvas-shared），本壳零逻辑。
/// 后端选择是编译期的（`App[B : Backend]` 静态分发），应用 import 本包就用
/// `@canvas-windows.CanvasBackend`。全部能力随别名来自共享半，见 moon.pkg 注。
///
/// 构造器用显式 `::` 调（`@canvas-windows.CanvasBackend::CanvasBackend()`）：
/// `pub type` 别名只带类型、**不带**同名构造器值，而 `pub fn CanvasBackend()`
/// 会被解析成在别名上定义方法（外来类型，禁止）——所以壳补不了值，调用方
/// 显式 `::` 即可（实测随别名可见）。其余关联函数与两个 trait impl 同理随
/// 别名可见，不用转发。
pub type CanvasBackend = @canvas-shared.CanvasBackend
