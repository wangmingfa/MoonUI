///|
/// lunamusic 真窗壳（原生后端半）：装配全部在
/// ../lunamusic-shell（音频 ABI + 装配，双壳共用），这里只构造原生后端。
/// `moon run examples/lunamusic-native` 打开一比一复刻的云音乐本地播放
/// 窗口（Backend #2，原生控件 + 皮肤）。
fn main raise {
  let app = @moonui-app.new_app()
  @lunamusic-shell.launch(app)
}
