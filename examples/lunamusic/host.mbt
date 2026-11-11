///|
/// 应用侧主机能力束（`T253`）：共享装配壳（`examples/lunamusic-shell`）要的五件
/// "宿主才有"的能力，但它的形状必须与具体后端无关。这里只声明类型，实现在
/// native 边缘包（`examples/lunamusic-host` 的 `app_host()`）。
///
/// 为什么不是框架 trait：`now_ms` / `worker_run` / `walk_dir` / `snapshot_all`
/// 是应用自带的宿主能力，不是 GUI 后端的义务；`probe_track` / `loudness_*` 更是
/// 音频半的专属入口（`T237` 的裁决：音频由应用自担，框架不设门面）。把它们的
/// **类型**放进应用本体，换后端时共享壳一行不用改，新后端只需提供一个同形的
/// `AppHost`。
///
/// `worker_run` 的 `B` 只出现在 `App` 参数上：调用点按 App 的实际后端类型推断
/// （两个 native 壳在构造 host 的同一作用域里把它交给 `launch`）。
pub(all) struct AppHost[B] {
  now_ms : () -> Int32
  worker_run : (@moonui.App[B], () -> Unit, () -> Unit raise @moonui.UiError) -> Unit raise @moonui.UiError
  walk_dir : (String) -> Array[String]
  snapshot_all : (String) -> Int32
  probe_track : (String) -> Track
  loudness_start : (String) -> Int32
  loudness_on : (((Int32) -> Unit)?) -> Unit
}
