///|
/// lunamusic 自绘壳（Backend #3，§52.5 分期③）：装配与原生壳共用
/// （../lunamusic-shell 的 launch），这里只构造自绘后端。
/// `moon run examples/lunamusic-canvas-native` 打开画布绘制的云音乐窗。
fn main raise {
  let b = @canvas-macos.CanvasBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  @lunamusic-shell.launch(app)
}
