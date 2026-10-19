///|
/// 伴窗的顶条（Luna那四只窗——播放列表 / 均衡器 / 歌词秀 / 桌面歌词——
/// 顶上都有同一条：皮肤色底、上缘一条亮线、标题居左、右侧一颗关闭方块）。
///
/// 主控那条是自绘的沉浸式标题栏（红绿灯浮在上面，见 app 的 title_bar），
/// 这里这条是伴窗用的：高度固定 20，跟主控的 34 不是一回事——原版伴窗的标
/// 题条也确实更窄。
///
/// 为什么需要它：伴窗原来没有标题条，四只窗摆在一起像四个网页面板，跟主控
/// 那种"一整块皮肤"完全不是一个观感。加一条同色系的窄条，一排窗读起来才像
/// 同一个程序。
pub(all) struct CmStrip[B] {
  root : @moonui.Widget[B]
  title : @moonui.Widget[B]
  /// 关闭方块。mac 上不建（系统红绿灯已经有关闭），所以是 `Option`。
  close : @moonui.Widget[B]?
}

///|
pub fn[B : @moonui.Backend] CmStrip::new(
  b : B,
  title : String,
  on_close : () -> Unit,
) -> CmStrip[B] raise @moonui.UiError {
  let lbl = @moonui.Widget::label(b, title)
    .foreground(cm_text_light())
    .font_size(10.0)
    .font_weight(@moonui.FontWeight::Bold)
  // 顶条右侧那颗 ✕ 是 Windows 的做法（无边框窗没有系统按钮）。mac 的沉浸式
  // 标题栏自带红绿灯，再画一颗就是两个关闭按钮——所以整颗不建，同时左侧让
  // 出红绿灯的位置（整簇约 52pt，留 62 才不叠标题）。
  let mac = b.host_platform() == @moonui.HostPlatform::Macos
  if mac {
    let row = @moonui.Widget::row(b, 6.0, [
      @moonui.Widget::sized(b, Some(62.0), None, @moonui.Widget::spacer(b)),
      @moonui.Widget::sized(b, None, Some(13.0), lbl),
      @moonui.Widget::spacer(b).with_expand(true),
    ])
    let padded = @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(3.0, 6.0),
      row,
    )
    let mid = @moonui.Widget::panel(b, padded).background(cm_titlebar_bg())
    let root = cm_band(b, cm_strip_h(), mid)
    return { root, title: lbl, close: None, }
  }
  let close = @moonui.Widget::button(b, "✕")
  cm_btn_skin(close, cm_titlebar_bg(), cm_text_light(), 9.0)
  let _ = close.with_on_click(fn() { on_close() })
  let row = @moonui.Widget::row(b, 6.0, [
    @moonui.Widget::sized(b, None, Some(13.0), lbl),
    @moonui.Widget::spacer(b).with_expand(true),
    @moonui.Widget::sized(b, Some(18.0), Some(13.0), close),
  ])
  let padded = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(3.0, 6.0),
    row,
  )
  let mid = @moonui.Widget::panel(b, padded).background(cm_titlebar_bg())
  let root = cm_band(b, cm_strip_h(), mid)
  { root, title: lbl, close: Some(close), }
}

///|
/// 伴窗顶条的高度（上下 1px 倒角 + 中间 18pt 内容）。
///
/// 22 而不是 20：mac 的沉浸式标题栏下红绿灯（13pt 圆钮）浮在这条上面，20
/// 太挤，按钮会压到条的下缘。
pub fn cm_strip_h() -> Double {
  22.0
}

///|
/// 伴窗外壳 = 顶条 + 内容区（四边留 pad，透出皮肤的脸面色）。
/// 返回整窗根：底色是脸面蓝，内容自己决定里面是浅色卡片还是深色槽。
pub fn[B : @moonui.Backend] cm_window_shell(
  b : B,
  strip : @moonui.Widget[B],
  body : @moonui.Widget[B],
  pad : Double,
) -> @moonui.Widget[B] raise @moonui.UiError {
  let inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::all(pad),
    @moonui.Widget::sized(b, None, None, body).with_expand(true),
  )
  let col = @moonui.Widget::column(b, 0.0, [
    strip,
    @moonui.Widget::sized(b, None, None, inner).with_expand(true),
  ])
  let root = @moonui.Widget::panel(b, col)
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_page_bg()))))
  root
}
