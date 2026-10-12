// Blackbox tests run against the package's public API. Use `@moonui` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
/// README 里那段示例必须真的能编译，所以把它放在这里而不是只写在文档里：
/// 它是唯一从包外验证公共 API 够不够用测试——只碰导出名字，不碰 Core 内部 helper。
test "README 示例：从包外拼出 Hello 界面并点一次" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let message = @moonui.Widget::label(backend, "Hello MoonUI")
  let button = @moonui.Widget::button(backend, "Click Me")
  let _ = button.on_click(fn() raise @moonui.UiError {
    message.set_text("Clicked!")
  })
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  window.set_content(@moonui.Widget::column(backend, 16.0, [message, button]))
  window.show()
  // 窗口 + 两个叶子控件；Column 是纯布局节点，不占原生对象（§14）
  assert_eq(b.live(), 3)
  assert_eq(message.text(), "Hello MoonUI")
  let _ = button.fire(
    @moonui.Event::Click(button.target(), @moonui.MouseButton::Left),
  )
  assert_eq(message.text(), "Clicked!")
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// §15 的覆盖必须沿树往下走：纯布局节点不占原生对象、自己不收样式（§14），
/// 但它设的字号要进到子控件的度量里。"hi" 是 2 个码元：
/// 基准 2×8+8 = 24.0，字号 24.0 下 2×8×2+8 = 40.0。
test "容器上的字号进叶子：Column 的覆盖要影响子控件宽度" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "hi")
  let column = @moonui.Widget::column(backend, 0.0, [label])
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  window.set_content(column)
  assert_eq(label.bounds().size.width, 24.0)
  column.set_style(Some(@moonui.style(font_size=Some(24.0))))
  window.relayout()
  assert_eq(label.bounds().size.width, 40.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// §15/§16 的样式必须进到测量，否则公共 API 上的 `set_style` 就是只写字段。
/// 数值是 mock 的确定性度量（`mock_widget.mbt`：文字宽度 = 码元数 × 8.0 × 字号/12.0，
/// 外加不随字号缩放的控件内边距），"Size me" 是 7 个码元：
/// 无字号时 7×8+8 = 64.0，字号 24.0（相对 12.0 的两倍）下 7×8×2+8 = 120.0。
test "字号进布局：set_style 之后重排要按新度量给矩形" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "Size me")
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  window.set_content(@moonui.Widget::column(backend, 0.0, [label]))
  assert_eq(label.bounds().size.width, 64.0)
  label.set_style(Some(@moonui.style(font_size=Some(24.0))))
  window.relayout()
  assert_eq(label.bounds().size.width, 120.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 那个点落在谁身上，答成句柄号：命不中给 `-1`，命中一只已经没了的控件给 `-2`。
///
/// 断言比的是 `target()` 里的号而不是 Widget 对象本身——`Widget` 没派生 `Eq`，按结构比
/// 会把一整棵树的字段都比一遍（那些字段还是 mutable 的），而这里要问的只有一件事：
/// 路由交出来的那只控件是不是预期那一只。句柄号就是那件事的号。
fn hit_id(
  win : @moonui.Window[@moonui.MockBackend],
  p : @moonui.LogicalPoint,
) -> Int {
  match win.widget_at(p) {
    None => -1
    Some(w) => w.target().id catch { _ => -2 }
  }
}

///|
fn center_of(r : @moonui.LogicalRect) -> @moonui.LogicalPoint {
  @moonui.LogicalPoint::{
    x: r.origin.x + r.size.width / 2.0,
    y: r.origin.y + r.size.height / 2.0,
  }
}

///|
/// `Window::widget_at`（§10 的鼠标路由在 Core 这一侧的公共查询版，`T39` 那一格里
/// "这个点上是谁"由 Core 答的那一半）。取点一律用**叶子自己的 frame**，不写死坐标：
/// mock 的度量将来怎么调，这些点之间的关系（中心、两叶之间的缝、最后一片之下）都不变。
///
/// - 落在叶子里 → 就是那只叶子。
/// - 两叶之间的缝、内容区右下角 → `None`。不猜"最近的那只"，和后端在 C 里退不到 owner
///   标记就整条丢掉是同一条判据（`backends/libui-common/adapter.h` 的 target 那一段）。
/// - 那个点确实在 Column 撑出来的区域里，而 Column 自己不是答案：纯布局节点没有句柄、
///   没有 id，收不到原生事件（§14），查询把它返回出去就造出一条"查得到却派不发"的路由。
///   上面那条缝隙点同时钉住这两件事。
/// - `Stack` 两层重叠 → 数组靠后那只（§14 的绘制顺序）。这一条钉 `hit_test` 里"留最后一个
///   含住这个点的叶子"那一行：改成留第一个，重叠这一档当场红；而下面那句"只属于底层那一截"
///   钉反面——一路只返回最后遍历到的那只的话，那一句也红。
test "widget_at：命中叶子，缝隙与布局节点返回 None，Stack 取靠后那层" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let first = @moonui.Widget::label(backend, "First")
  let second = @moonui.Widget::label(backend, "Second")
  let column = @moonui.Widget::column(backend, 40.0, [first, second])
  let win = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  win.set_content(column)
  let f = first.frame()
  let s = second.frame()
  assert_eq(hit_id(win, center_of(f)), first.target().id)
  assert_eq(hit_id(win, center_of(s)), second.target().id)
  // 两叶之间那 40 逻辑像素的正中：不在任何叶子里
  assert_eq(
    hit_id(win, @moonui.LogicalPoint::{
      x: f.origin.x + 1.0,
      y: f.origin.y + f.size.height + 20.0,
    }),
    -1,
  )
  // 内容区右下角：Column 在这里，叶子不在
  assert_eq(hit_id(win, @moonui.LogicalPoint::{ x: 399.0, y: 299.0, }), -1)
  // 换一棵只有 Stack 的树：两片共用同一个原点，重叠处取靠后那层
  let stack_win = app.create_window("MoonUI Stack", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  let base = @moonui.Widget::label(backend, "Base layer")
  let top = @moonui.Widget::label(backend, "T")
  stack_win.set_content(@moonui.Widget::stack(backend, [base, top]))
  let bf = base.frame()
  let tf = top.frame()
  assert_eq(bf.origin, tf.origin)
  assert_eq(hit_id(stack_win, center_of(tf)), top.target().id)
  // 底层比顶层宽出来的那一截：只属于底层
  assert_eq(
    hit_id(stack_win, @moonui.LogicalPoint::{
      x: bf.origin.x + tf.size.width + 1.0,
      y: bf.origin.y + bf.size.height / 2.0,
    }),
    base.target().id,
  )
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `set_text` 的重排契约（2026-10-10 Counter 截字那笔账）：文案一变固有尺寸就变，
/// Core 的 frame 只在布局时写回后端，所以 `set_text` 必须把窗口标脏、由下一轮
/// `App::step` 统一重排。数值是 mock 的确定性度量（码元数 × 8.0 + 内边距 8.0）：
/// "Count: 0" 是 8 个码元 = 72.0，"Count: 15" 是 9 个 = 80.0。
test "set_text 之后下一轮 step 自动重排：标签按新文案的度量给矩形" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "Count: 0")
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  window.set_content(@moonui.Widget::column(backend, 0.0, [label]))
  assert_eq(label.bounds().size.width, 72.0)
  label.set_text("Count: 15")
  // 标脏本身不动 frame：重排发生在下一轮 step，不在 setter 里同步做
  // （setter 可能在原生回调栈里，那时重排是重入）
  assert_eq(label.bounds().size.width, 72.0)
  let _ = app.step()
  assert_eq(label.bounds().size.width, 80.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `set_style` 的自动重排（`T55`，set_text 那条的同形）：字号进了 mock 的度量
/// （码元数 × 8.0 × 字号/12.0 + 内边距 8.0），所以改字号必须标脏、下一轮
/// `step` 补排——不标的话这条就是红的（存值之后 frame 纹丝不动）。
/// 注意这条只钉 MockBackend / 自绘后端的语义：libui 真后端上 set_style 有意
/// 不生效（§32 保原生外观，`T30` 的豁免），标脏照挂、那个度量不理它。
test "set_style 之后下一轮 step 自动重排：字号按新度量给矩形" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "Size me")
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  window.set_content(@moonui.Widget::column(backend, 0.0, [label]))
  // "Size me" 7 码元 × 8.0 + 8.0 = 64.0（字号没给，按 12.0 基准）
  assert_eq(label.bounds().size.width, 64.0)
  label.set_style(Some(@moonui.style(font_size=Some(24.0))))
  // 标脏本身不动 frame，重排在下一轮 step（同 set_text 那条的读法）
  assert_eq(label.bounds().size.width, 64.0)
  let _ = app.step()
  // 24.0 是 12.0 的两倍：7 × 8.0 × 2 + 8.0 = 120.0
  assert_eq(label.bounds().size.width, 120.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 0.2 批九种新控件的公共 API 在 mock 上的端到端（§13）：构造 → 读写 → 销毁，
/// 每种控件至少一条只属于它的属性断言。种类不符的属性访问必须报
/// `Unsupported`，而不是静默无效——和 mock_widget.mbt 那几条错误路径同一条规矩。
test "扩展控件：九种的构造、专属属性与种类拦截" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  // PasswordInput / MultilineEntry 走通用文本通道
  let pw = @moonui.Widget::password_input(backend, "secret")
  assert_eq(pw.text(), "secret")
  pw.set_text("changed")
  assert_eq(pw.text(), "changed")
  let ml = @moonui.Widget::multiline(backend, "第一行\n第二行")
  assert_eq(ml.text(), "第一行\n第二行")
  // Slider / Spinbox / Progress 走数值通道；范围只在构造时给
  let slider = @moonui.Widget::slider(backend, 0, 100)
  assert_eq(slider.value(), 0)
  slider.set_value(42)
  assert_eq(slider.value(), 42)
  let spin = @moonui.Widget::spinbox(backend, -5, 5)
  assert_eq(spin.value(), -5)
  spin.set_value(3)
  assert_eq(spin.value(), 3)
  let bar = @moonui.Widget::progress(backend)
  bar.set_value(30)
  assert_eq(bar.value(), 30)
  // 改范围只有 Slider 能做；mock 不存范围本身，但会把越界的当前值夹回去
  slider.set_range(10, 40)
  assert_eq(slider.value(), 40)
  // ComboBox / RadioButtons 走选项通道；没选中是 -1（libui 的哨兵）
  let combo = @moonui.Widget::combobox(backend, ["苹果", "香蕉", "樱桃"])
  assert_eq(combo.selected(), -1)
  combo.set_selected(1)
  assert_eq(combo.selected(), 1)
  combo.append_option("榴莲")
  assert_eq(combo.selected(), 1)
  let radio = @moonui.Widget::radio_buttons(backend, ["红", "绿"])
  radio.set_selected(0)
  assert_eq(radio.selected(), 0)
  // DatePicker 走日期文本通道；mock 原样收发，解析是 libui 后端的事
  let dp = @moonui.Widget::date_picker(backend)
  dp.set_datetime_text("2026-10-12 08:30:00")
  assert_eq(dp.datetime_text(), "2026-10-12 08:30:00")
  // Separator 只是一根线：文本、数值、选项、日期全都拦下
  let line = @moonui.Widget::separator(backend)
  assert_eq(line.kind(), @moonui.WidgetKind::Separator)
  // 种类拦截：Label 没有数值/选项/日期属性
  let label = @moonui.Widget::label(backend, "x")
  let msg = try {
    label.set_value(1)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg, Some("不支持的操作：该控件没有数值属性"))
  let msg2 = try {
    let _ = label.selected()
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg2, Some("不支持的操作：该控件没有选项属性"))
  let msg3 = try {
    let _ = label.datetime_text()
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(
    msg3,
    Some("不支持的操作：只有 DatePicker 有日期时间属性"),
  )
  // Spinbox 改范围：libui 没有这条原生入口，Core 先拦
  let msg4 = try {
    spin.set_range(0, 10)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg4, Some("不支持的操作：只有 Slider 能改范围"))
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 条目控件的度量随选项表走（mock_options_intrinsic）：追加一个更长的选项，
/// 下一轮 step 重排后宽度要跟上去——"选项变化必须触发重算"这条规矩的可观察面。
test "扩展控件：ComboBox 的度量跟最长选项走" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let combo = @moonui.Widget::combobox(backend, ["短", "长长长长"])
  let win = app.create_window("W", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  win.set_content(@moonui.Widget::column(backend, 0.0, [combo]))
  // "长长长长" 4 码元 × 8.0 + 内边距 24.0 = 56.0
  assert_eq(combo.bounds().size.width, 56.0)
  combo.append_option("更长的选项")
  let _ = app.step()
  // "更长的选项" 5 码元 × 8.0 + 24.0 = 64.0
  assert_eq(combo.bounds().size.width, 64.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 九种新种类的无障碍默认角色（§32）：数值调节报 SliderRole、进度报
/// ProgressRole、条目类按容器语义报、分隔线没有角色（读屏器跳过装饰物）。
test "扩展控件：默认无障碍角色" {
  assert_eq(@moonui.WidgetKind::Slider.default_role(), Some(@moonui.SliderRole))
  assert_eq(
    @moonui.WidgetKind::Spinbox.default_role(),
    Some(@moonui.SliderRole),
  )
  assert_eq(
    @moonui.WidgetKind::Progress.default_role(),
    Some(@moonui.ProgressRole),
  )
  assert_eq(
    @moonui.WidgetKind::PasswordInput.default_role(),
    Some(@moonui.TextBox),
  )
  assert_eq(
    @moonui.WidgetKind::MultilineEntry.default_role(),
    Some(@moonui.TextBox),
  )
  assert_eq(
    @moonui.WidgetKind::DatePicker.default_role(),
    Some(@moonui.TextBox),
  )
  assert_eq(@moonui.WidgetKind::ComboBox.default_role(), Some(@moonui.List))
  assert_eq(
    @moonui.WidgetKind::RadioButtons.default_role(),
    Some(@moonui.Group),
  )
  assert_eq(@moonui.WidgetKind::Separator.default_role(), None)
}

///|
/// 应用图标（§26）：stem（不带扩展名的文件名）原样进后端——扩展名由各平台
/// 的原生层自己补（mac `.png`、Windows `.ico`），Core 不掺和；没初始化就调用
/// 和其它后端方法一样按 §33 报错，而不是静默吞掉。真实后端的读文件、上报
/// `OperationFailed` 那一半在 mac 真窗口测试里钉（`backends/libui-macos`）。
test "set_icon：stem 原样记进后端，未初始化按 §33 报错" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  assert_eq(b.app_icon(), None)
  app.set_icon("assets/logo/moonui")
  assert_eq(b.app_icon(), Some("assets/logo/moonui"))
  // 重复调用是允许的：后者赢
  app.set_icon("icons/app")
  assert_eq(b.app_icon(), Some("icons/app"))
  @moonui.Backend::terminate(b)
  let outcome = try {
    app.set_icon("assets/logo/moonui")
    "没有报错"
  } catch {
    @moonui.InitializationFailed(m) => m
    _ => "别的错"
  }
  assert_eq(outcome, "Backend 尚未初始化")
}

///|
/// 重绘信号（`T31`）：自绘后端靠 `request_redraw` 在空闲时续命——请求后下一圈
/// `poll_event` 要能取到一条 `Frame`，target 是那只窗口的句柄（id + generation
/// 一起带走，`T49`）。这里钉 MockBackend 的契约：请求前队列是空的（`poll_event`
/// 返回 `None`），请求后恰好吐出一条 `Frame`，再取就空了。
test "request_redraw：请求后下一圈 poll_event 吐一条 Frame，target 是那只窗口" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let window = app.create_window("MoonUI", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  // 请求前队列是空的
  assert_eq(@moonui.Backend::poll_event(b), None)
  @moonui.Backend::request_redraw(b, window.handle())
  // 请求后下一圈恰好一条 Frame，target 是这只窗口
  let ev = @moonui.Backend::poll_event(b)
  assert_true(ev is Some(@moonui.Event::Frame(t)) && t == window.target())
  // 再取就空了——契约只钉"能取到一条"，不钉"恰好一条"，但 Mock 不合并
  assert_eq(@moonui.Backend::poll_event(b), None)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 层叠收到 Core（`T29`）：`set_content` 之后，Core 把整窗的**绘画顺序**（从顶层到
/// 底层）算好、整份推给后端，不再靠 attach/raise 的增量去凑。这里钉 MockBackend 存下
/// 的那份顺序（`child_z_order` 读的就是它）：
/// - Row：先序、数组顺序——先声明的画在上层，`[first, second, third]`。
/// - Stack：子树叶子倒序——数组靠后的画在上层，`[top, badge, back]`。
/// 这两条和真窗口测试（`backends/libui-macos` / `libui-windows` 的"层叠的两个方向"）
/// 量的是同一件事，只是这里不依赖原生 z-order，自绘后端也能跑。
test "set_content 把整窗绘画顺序推给后端：Row 先序、Stack 倒序" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  // Row：先序、数组顺序
  let row_win = app.create_window("MoonUI 层叠-Row", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  let first = @moonui.Widget::label(backend, "Ab")
  let second = @moonui.Widget::label(backend, "Abcd")
  let third = @moonui.Widget::label(backend, "A")
  row_win.set_content(@moonui.Widget::row(backend, 6.0, [first, second, third]))
  assert_eq(b.child_z_order(row_win.handle()), [
    first.handle().unwrap(),
    second.handle().unwrap(),
    third.handle().unwrap(),
  ])
  // Stack：子树叶子倒序，数组靠后的画在上层
  let stack_win = app.create_window("MoonUI 层叠-Stack", @moonui.LogicalSize::{
    width: 400.0,
    height: 300.0,
  })
  let back = @moonui.Widget::label(backend, "Ab")
  let badge = @moonui.Widget::button(backend, "Ok")
  let top = @moonui.Widget::label(backend, "A")
  stack_win.set_content(@moonui.Widget::stack(backend, [back, badge, top]))
  assert_eq(b.child_z_order(stack_win.handle()), [
    top.handle().unwrap(),
    badge.handle().unwrap(),
    back.handle().unwrap(),
  ])
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}
