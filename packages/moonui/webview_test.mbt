// 平台 WebView 的 Core 侧行为判据（`T102` 第二十五刀，MockBackend）：创建与
// 声明尺寸（intrinsic 读 custom_size，负值钳零，与 Custom 同一条规矩）、装载
// 记账（URL 与 HTML 两条通道分开记、记最后一次）、kind 规矩（非 WebView 拒
// 装）。导航事件回流（Started / Done / Failed 的配对与 detail 口径）在 mac
// 真窗那组验——mock 里没有真 WebView，"装了什么"就是全部可观察事实。

///|
/// 创建与声明尺寸：`Widget::webview` 的 intrinsic 取声明值（不问后端），
/// 负值与零钳成零——布局不欠账。
test "webview：创建、声明尺寸、负值钳零（T102 第二十五刀）" {
  let app = api_app()
  let b = app.backend()
  let wv = @moonui.Widget::webview(b, @moonui.LogicalSize(320.0, 240.0))
  assert_true(wv.kind() is @moonui.WidgetKind::WebView)
  assert_eq(wv.intrinsic_size(), @moonui.LogicalSize(320.0, 240.0))
  let neg = @moonui.Widget::webview(b, @moonui.LogicalSize(-5.0, 0.0))
  assert_eq(neg.intrinsic_size(), @moonui.LogicalSize(0.0, 0.0))
  // 样式的 height 覆盖在 WebView 上同样生效（与普通叶子一条规矩）
  let fixed = @moonui.Widget::webview(b, @moonui.LogicalSize(320.0, 240.0))
  fixed.set_style(Some(@moonui.style(height=Some(100.0))))
  assert_eq(fixed.intrinsic_size(), @moonui.LogicalSize(320.0, 100.0))
}

///|
/// 装载记账：`load_url` 走 URL 通道、`load_html` 走 HTML 通道，mock 记最后
/// 一次的源与通道；销毁后再装报 Destroyed；非 WebView 拒装（与 Image 同一条
/// kind 规矩，同一个 Unsupported）。
test "webview：load 记账、Destroyed、非 WebView 拒装（T102 第二十五刀）" {
  let app = api_app()
  let b = app.backend()
  let wv = @moonui.Widget::webview(b, @moonui.LogicalSize(200.0, 120.0))
  let win = app.create_window("webview-load", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(wv)
  win.show()
  let _ = app.step()
  let h = wv.handle().unwrap()
  wv.load_url("https://example.com/x")
  wv.load_html("<p>hi</p>")
  let m = b.widget(h)
  assert_eq(m.webview_loads, 2)
  assert_eq(m.webview_source, "<p>hi</p>")
  assert_true(m.webview_is_html)
  // 销毁后再装：换 content 会把旧根整棵关掉（set_content 的所有权规矩），
  // 关掉后再装报 Destroyed——wv 与 dead 两任旧根都验到
  let dead = @moonui.Widget::webview(b, @moonui.LogicalSize(10.0, 10.0))
  win.set_content(dead)
  assert_eq(
    error_of(() => wv.load_url("https://example.com/y")),
    Some("对象已销毁"),
  )
  // 非 WebView 拒装（lbl 挂上这一步顺带把 dead 关掉）
  let lbl = @moonui.Widget::label(b, "文本")
  win.set_content(lbl)
  let _ = app.step()
  assert_eq(
    error_of(() => dead.load_url("https://example.com/y")),
    Some("对象已销毁"),
  )
  assert_eq(
    error_of(() => lbl.load_url("https://example.com/z")),
    Some("不支持的操作：只有 WebView 控件能装载内容"),
  )
}
