///|
/// lunamusic 真窗壳（原生后端半）：装配在 ../lunamusic-shell，音频与宿主能力
/// 在 ../lunamusic-host（`T253` 后共享壳不再 import 后端），这里只构造原生
/// 后端并把三样东西接起来。
/// `moon run examples/lunamusic-native` 打开一比一复刻的云音乐本地播放
/// 窗口（Backend #2，原生控件 + 皮肤）。
fn main raise {
  let app = @moonui-app.new_app()
  let host = @lunamusic-host.app_host()
  @lunamusic-shell.launch(app, host, @lunamusic-host.audio_engine())
}
