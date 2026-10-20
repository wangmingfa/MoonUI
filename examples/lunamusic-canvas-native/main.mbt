///|
/// lunamusic 自绘壳（Backend #3，§52.5 分期③）：装配与原生壳共用
/// （../lunamusic-shell 的 launch），这里只构造自绘后端。
/// `moon run examples/lunamusic-canvas-native` 打开画布绘制的云音乐窗。
fn main raise {
  let b = @canvas-macos.CanvasBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  // 帧钟接线（与原生壳 new_app() 对齐）：动画模块靠这套时钟插值，anim_clock
  // 缺省 None 时动画根本不启动。canvas 后端不持事件循环，预算经 set_frame_budget
  // 转发到内嵌的原生 inner（poll_event 的等待预算 -1↔8ms）。
  app.set_anim_clock(@native-common.native_time_ms)
  app.set_anim_wake(fn(active : Bool) { b.set_frame_budget(active) })
  @lunamusic-shell.launch(app)
}
