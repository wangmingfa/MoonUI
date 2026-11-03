///|
/// 测试用的一份暗色自定义配色（五个 token 各不相同，判据里认错了格看得出来）。
fn test_palette() -> Palette {
  Palette::{
    background: Color::rgb(10, 10, 14),
    surface: Color::rgb(18, 18, 24),
    text: Color::rgb(240, 240, 245),
    accent: Color::rgb(255, 120, 0),
    border: Color::rgb(60, 60, 70),
  }
}

///|
/// `T199`：`set_palette` 把配色钉住并**下发**——生效配色、窗口底样式、后端
/// 持有的那份一起换（只改 Core 字段不推给后端，界面上不会变）；`clear_palette`
/// 回主题；`set_theme` 顺手把钉住的清掉——否则 `set_theme(Dark)` 在视觉上会
/// 变成一句空操作。
test "set_palette 下发底样式，clear_palette 与 set_theme 收回（T199）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  b.set_appearance(Light)
  let win = app.create_window("配色", LogicalSize(200.0, 100.0))
  let label = Widget::label(b, "Ab")
  win.set_content(Widget::column(b, 0.0, [label]))
  let h = check_nonnull(label.handle(), "叶子控件必须有原生对象")
  let p = test_palette()
  app.set_palette(p)
  assert_eq(app.palette(), p)
  assert_eq(app.custom_palette(), Some(p))
  assert_eq(win.style_base.background, Some(p.surface))
  // Label 不下发继承来的底色（`T139`），所以这里比前景色——它来自底样式
  let pushed = check_nonnull(b.widget(h).style, "换配色必须重推")
  assert_eq(pushed.foreground, Some(p.text))
  // 系统是浅色、钉的色板底色是暗的：外观按**色板**判，不再报主题那半
  assert_eq(app.appearance(), Dark)
  // 撤掉：回主题解析（系统浅色 → 浅色配色），底样式跟着回去
  app.clear_palette()
  assert_eq(app.custom_palette(), None)
  assert_eq(app.palette(), Theme::light_palette())
  assert_eq(win.style_base.background, Some(Theme::light_palette().surface))
  assert_eq(
    check_nonnull(b.widget(h).style, "").foreground,
    Some(Theme::light_palette().text),
  )
  assert_eq(app.appearance(), Light)
  // 再钉一次，然后换主题：钉住的被清掉，配色跟着主题走
  app.set_palette(p)
  app.set_theme(Dark)
  assert_eq(app.custom_palette(), None)
  assert_eq(app.palette(), Theme::dark_palette())
  assert_eq(
    check_nonnull(b.widget(h).style, "").foreground,
    Some(Theme::dark_palette().text),
  )
}

///|
/// `T199`：钉住配色之后，系统主题变化是**幂等重排**——事件照来、窗口照刷
/// （它报告的是系统主题变了，不是生效外观），但刷回去的还是钉住那份，用户
/// 自己的色板不会被系统切换冲掉。
test "钉住配色时系统主题变化不冲掉色板（T199）" {
  let app = App::new(MockBackend::new())
  let b = app.backend()
  Backend::init(b)
  b.set_appearance(Light)
  let win = app.create_window("钉住", LogicalSize(120.0, 60.0))
  let label = Widget::label(b, "Ab")
  win.set_content(Widget::column(b, 0.0, [label]))
  let h = check_nonnull(label.handle(), "叶子控件必须有原生对象")
  let p = test_palette()
  app.set_palette(p)
  // 系统切到深色（App 这边没钉主题，本来会跟着变）
  b.set_appearance(Dark)
  assert_eq(app.dispatch(ThemeChanged(win.target(), Dark)), 1)
  assert_eq(app.palette(), p)
  assert_eq(win.style_base.background, Some(p.surface))
  assert_eq(check_nonnull(b.widget(h).style, "").foreground, Some(p.text))
  // 反方向也一样：系统切回浅色，色板还是那份
  b.set_appearance(Light)
  assert_eq(app.dispatch(ThemeChanged(win.target(), Light)), 1)
  assert_eq(app.palette(), p)
}
