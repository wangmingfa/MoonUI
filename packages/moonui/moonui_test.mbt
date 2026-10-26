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
  let window = app.create_window("MoonUI", @moonui.LogicalSize(800.0, 600.0))
  window.set_content(@moonui.Widget::column(backend, 16.0, [message, button]))
  window.show()
  // 窗口 + 两个叶子控件；Column 是纯布局节点，不占原生对象（§14）
  assert_eq(b.live(), 3)
  assert_eq(message.text(), "Hello MoonUI")
  let _ = button.fire(Click(button.target(), Left))
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
  let window = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
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
  let window = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
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
) -> Int32 {
  match win.widget_at(p) {
    None => -1
    Some(w) => w.target().id catch { _ => -2 }
  }
}

///|
fn center_of(r : @moonui.LogicalRect) -> @moonui.LogicalPoint {
  @moonui.LogicalPoint(
    r.origin.x + r.size.width / 2.0,
    r.origin.y + r.size.height / 2.0,
  )
}

///|
/// `Window::widget_at`（§10 的鼠标路由在 Core 这一侧的公共查询版，`T39` 那一格里
/// "这个点上是谁"由 Core 答的那一半）。取点一律用**叶子自己的 frame**，不写死坐标：
/// mock 的度量将来怎么调，这些点之间的关系（中心、两叶之间的缝、最后一片之下）都不变。
///
/// - 落在叶子里 → 就是那只叶子。
/// - 两叶之间的缝、内容区右下角 → `None`。不猜"最近的那只"，和后端在 C 里退不到 owner
///   标记就整条丢掉是同一条判据（`backends/native-common/adapter.h` 的 target 那一段）。
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
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(column)
  let f = first.frame()
  let s = second.frame()
  assert_eq(hit_id(win, center_of(f)), first.target().id)
  assert_eq(hit_id(win, center_of(s)), second.target().id)
  // 两叶之间那 40 逻辑像素的正中：不在任何叶子里
  assert_eq(
    hit_id(
      win,
      @moonui.LogicalPoint(f.origin.x + 1.0, f.origin.y + f.size.height + 20.0),
    ),
    -1,
  )
  // 内容区右下角：Column 在这里，叶子不在
  assert_eq(hit_id(win, @moonui.LogicalPoint(399.0, 299.0)), -1)
  // 换一棵只有 Stack 的树：两片共用同一个原点，重叠处取靠后那层
  let stack_win = app.create_window(
    "MoonUI Stack",
    @moonui.LogicalSize(400.0, 300.0),
  )
  let base = @moonui.Widget::label(backend, "Base layer")
  let top = @moonui.Widget::label(backend, "T")
  stack_win.set_content(@moonui.Widget::stack(backend, [base, top]))
  let bf = base.frame()
  let tf = top.frame()
  assert_eq(bf.origin, tf.origin)
  assert_eq(hit_id(stack_win, center_of(tf)), top.target().id)
  // 底层比顶层宽出来的那一截：只属于底层
  assert_eq(
    hit_id(
      stack_win,
      @moonui.LogicalPoint(
        bf.origin.x + tf.size.width + 1.0,
        bf.origin.y + bf.size.height / 2.0,
      ),
    ),
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
  let window = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
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
/// 注意这条只钉 MockBackend / 自绘后端的语义：原生真后端上 set_style 有意
/// 不生效（§32 保原生外观，`T30` 的豁免），标脏照挂、那个度量不理它。
test "set_style 之后下一轮 step 自动重排：字号按新度量给矩形" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "Size me")
  let window = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
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
/// 定宽/定高覆盖进测量账（`T94`）：`.width(100.0)` 存进自层样式后，
/// `leaf_intrinsic` 用它盖掉后端报的固有值——存值只标脏、frame 在下一轮
/// step 追上（同 set_text 那条的读法），落点逐位精确。真窗（原生后端）
/// 同账：Core 的测量与 frame 全在 `leaf_intrinsic` 一处，不立第二把尺。
test "width/height 覆盖之后下一轮 step frame 逐位追上（T94）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "Size me")
  let window = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  window.set_content(@moonui.Widget::column(backend, 0.0, [label]))
  // 固有宽 64.0（"Size me" 7 码元 × 8.0 + 8.0）
  assert_eq(label.bounds().size.width, 64.0)
  let _ = label.width(100.0)
  // 存值只标脏：重排在下一轮 step
  assert_eq(label.bounds().size.width, 64.0)
  let _ = app.step()
  assert_eq(label.bounds().size.width, 100.0)
  // 读回与摆出同一个账：intrinsic_size 读回的也是覆盖值
  assert_eq(label.intrinsic_size().width, 100.0)
  // 定高同形，且两条覆盖可并存
  let _ = label.height(20.0)
  let _ = app.step()
  assert_eq(label.bounds().size, @moonui.LogicalSize(100.0, 20.0))
  // MenuRow 同一语义（评审中项钉住）：覆盖生效时定宽就是最终宽，
  // insets 不再往上叠——insets 只在未覆盖时加进固有值
  let menu = @moonui.Widget::menu_row(backend, "一行", false)
  let _ = menu.width(120.0)
  assert_eq(menu.intrinsic_size().width, 120.0)
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
  // ComboBox / RadioButtons 走选项通道；没选中是 -1（沿 libui 的哨兵）
  let combo = @moonui.Widget::combobox(backend, ["苹果", "香蕉", "樱桃"])
  assert_eq(combo.selected(), -1)
  combo.set_selected(1)
  assert_eq(combo.selected(), 1)
  combo.append_option("榴莲")
  assert_eq(combo.selected(), 1)
  let radio = @moonui.Widget::radio_buttons(backend, ["红", "绿"])
  radio.set_selected(0)
  assert_eq(radio.selected(), 0)
  // DatePicker 走日期文本通道；mock 原样收发，解析是后端适配器的事
  let dp = @moonui.Widget::date_picker(backend)
  dp.set_datetime_text("2026-10-12 08:30:00")
  assert_eq(dp.datetime_text(), "2026-10-12 08:30:00")
  // Separator 只是一根线：文本、数值、选项、日期全都拦下
  let line = @moonui.Widget::separator(backend)
  assert_eq(line.kind(), Separator)
  // VSeparator 同一根线的竖向版，拦截同款
  let vline = @moonui.Widget::vseparator(backend)
  assert_eq(vline.kind(), VSeparator)
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
  // Spinbox 改范围：沿 libui 的口径没有这条原生入口（T82 删 libui），Core 先拦
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
  let win = app.create_window("W", @moonui.LogicalSize(400.0, 300.0))
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
/// `OperationFailed` 那一半在 mac 真窗口测试里钉（`backends/native-macos` 的 native_test）。
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
  let window = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  // 请求前队列是空的
  assert_eq(@moonui.Backend::poll_event(b), None)
  @moonui.Backend::request_redraw(b, window.handle())
  // 请求后下一圈恰好一条 Frame，target 是这只窗口
  let ev = @moonui.Backend::poll_event(b)
  assert_true(ev is Some(Frame(t)) && t == window.target())
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
/// 这两条和真窗口测试（`backends/libui-macos` / `libui-windows` 的"层叠的两个方向"，
/// `T82` 删 libui 时一并删了）量的是同一件事，只是这里不依赖原生 z-order，自绘后端也能跑。
test "set_content 把整窗绘画顺序推给后端：Row 先序、Stack 倒序" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  // Row：先序、数组顺序
  let row_win = app.create_window(
    "MoonUI 层叠-Row",
    @moonui.LogicalSize(400.0, 300.0),
  )
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
  let stack_win = app.create_window(
    "MoonUI 层叠-Stack",
    @moonui.LogicalSize(400.0, 300.0),
  )
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

///|
/// 焦点链收到 Core（`T29`）：`set_content` 之后，Core 把整窗的**焦点链**（声明顺序，
/// 先序）算好、整份推给后端，后端把原生焦点机制接成这条顺序，于是键盘 Tab 走声明
/// 顺序。这里钉 MockBackend 存下的那份（`focus_chain` 读的就是它）：
/// - Row：声明顺序，`[first, second, third]`——和绘画顺序同值（不含 Stack 的树两者一致）。
/// - Stack：声明顺序 `[back, badge, top]`，而绘画顺序是倒序 `[top, badge, back]`
///   （上一条钉的）。**两条链在这里分道**：Tab 走声明顺序、绘画走倒序，Stack 内部
///   的 Tab 不再跟着层叠翻成数组倒序——这正是 `T29` 要解的那条代价。
test "set_content 把整窗焦点链推给后端：声明顺序，Stack 里与层叠分道" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  // Row：焦点链 = 声明顺序，和绘画顺序同值
  let row_win = app.create_window(
    "MoonUI 焦点-Row",
    @moonui.LogicalSize(400.0, 300.0),
  )
  let first = @moonui.Widget::label(backend, "Ab")
  let second = @moonui.Widget::label(backend, "Abcd")
  let third = @moonui.Widget::label(backend, "A")
  row_win.set_content(@moonui.Widget::row(backend, 6.0, [first, second, third]))
  assert_eq(b.focus_chain(row_win.handle()), [
    first.handle().unwrap(),
    second.handle().unwrap(),
    third.handle().unwrap(),
  ])
  // Stack：焦点链 = 声明顺序，和层叠（倒序）分道
  let stack_win = app.create_window(
    "MoonUI 焦点-Stack",
    @moonui.LogicalSize(400.0, 300.0),
  )
  let back = @moonui.Widget::label(backend, "Ab")
  let badge = @moonui.Widget::button(backend, "Ok")
  let top = @moonui.Widget::label(backend, "A")
  stack_win.set_content(@moonui.Widget::stack(backend, [back, badge, top]))
  // 焦点链是声明顺序
  assert_eq(b.focus_chain(stack_win.handle()), [
    back.handle().unwrap(),
    badge.handle().unwrap(),
    top.handle().unwrap(),
  ])
  // 层叠是倒序——两条链不同，Tab 不再跟着层叠翻
  assert_eq(b.child_z_order(stack_win.handle()), [
    top.handle().unwrap(),
    badge.handle().unwrap(),
    back.handle().unwrap(),
  ])
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// 行增删后焦点链重推（`T66`）：`add_child` 不经过 `set_content`，链曾经
/// 过期——真窗上 Tab 还会走到已销毁的行、漏掉新行。现在 `relayout` 每轮把
/// 层叠与焦点链整份重算重推，后端整份替换，过期顺序不留。后挂控件的挂接
/// 归调用方（`T74` 先例），这条按那个分工模拟。
test "add_child 之后 relayout 重推焦点链，新行进链（T66）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let column = @moonui.Widget::column(backend, 0.0, [])
  let first = @moonui.Widget::label(backend, "Ab")
  let _ = column.add_child(first)
  let win = app.create_window(
    "MoonUI 焦点-增删",
    @moonui.LogicalSize(400.0, 300.0),
  )
  win.set_content(column)
  assert_eq(b.focus_chain(win.handle()), [first.handle().unwrap()])
  // 动态加一行：Core 树 add_child + 后端挂接（调用方的职责）
  let second = @moonui.Widget::label(backend, "Abcd")
  let _ = column.add_child(second)
  @moonui.Backend::attach_widget(b, win.handle(), second.handle().unwrap())
  // 此刻链还是旧的——重排在 relayout，两条链一起新鲜
  win.relayout()
  assert_eq(b.focus_chain(win.handle()), [
    first.handle().unwrap(),
    second.handle().unwrap(),
  ])
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "三层树 capture 自根向叶、冒泡自叶向根（T86⑨判据）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let leaf = @moonui.Widget::button(backend, "叶")
  let mid = @moonui.Widget::row(backend, 0.0, [leaf])
  let root = @moonui.Widget::column(backend, 0.0, [mid])
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(root)
  let log : Array[String] = []
  let _ = root.on_capture(fn(_) { true }, fn(_) {
    log.push("根-capture")
    true
  })
  let _ = mid.on_capture(fn(_) { true }, fn(_) {
    log.push("中-capture")
    true
  })
  let _ = leaf.on_capture(fn(_) { true }, fn(_) {
    log.push("叶-capture")
    true
  })
  let _ = leaf.on_bubble(fn(_) { true }, fn(_) { log.push("叶-bubble") })
  let _ = mid.on_bubble(fn(_) { true }, fn(_) { log.push("中-bubble") })
  let _ = root.on_bubble(fn(_) { true }, fn(_) { log.push("根-bubble") })
  let hits = app.dispatch(Click(leaf.target(), Left))
  // 顺序账：capture 根→中→叶；target 直派（这棵树没有直派订阅，语义见下一条）；
  // 冒泡叶→中→根
  assert_eq(log, [
    "根-capture", "中-capture", "叶-capture", "叶-bubble", "中-bubble", "根-bubble",
  ])
  // 直派语义没改：直派命中不进 dispatch 的返回值（旧账同值，第三段订阅才计）
  assert_eq(hits, 0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "拦截返回 false 后 target 直派与冒泡都不跑（T86⑨判据）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let leaf = @moonui.Widget::button(backend, "叶")
  let mid = @moonui.Widget::row(backend, 0.0, [leaf])
  let root = @moonui.Widget::column(backend, 0.0, [mid])
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(root)
  let log : Array[String] = []
  let intercept = [true]
  // 直派订阅（既有账）：没被拦下时它必须跑
  let _ = leaf.on_click(fn() { log.push("叶-直派") })
  let _ = root.on_capture(fn(_) { true }, fn(_) {
    log.push("根-capture")
    true
  })
  // 中层拦截：开关开的时候返回 false 停止后续阶段；关了放行——同一颗拦截口
  // 两个沿都钉（拦截是这条口的语义，放行证明它不额外改写路径）
  let _ = mid.on_capture(fn(_) { true }, fn(_) {
    log.push(if intercept[0] { "中-capture(拦)" } else { "中-capture(放)" })
    if intercept[0] {
      false
    } else {
      true
    }
  })
  let _ = leaf.on_capture(fn(_) { true }, fn(_) {
    log.push("叶-capture")
    true
  })
  let _ = leaf.on_bubble(fn(_) { true }, fn(_) { log.push("叶-bubble") })
  let hits = app.dispatch(Click(leaf.target(), Left))
  // capture 根→中到中层即停：叶的 capture、直派、冒泡全部缺席
  assert_eq(log, ["根-capture", "中-capture(拦)"])
  assert_eq(hits, 0)
  // 开关关上（放行）之后一切照旧
  intercept[0] = false
  log.clear()
  let _ = app.dispatch(Click(leaf.target(), Left))
  assert_eq(log, [
    "根-capture", "中-capture(放)", "叶-capture", "叶-直派", "叶-bubble",
  ])
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "无拦截树行为与旧账逐位同值（T86⑨判据·既有直派零改写）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let leaf = @moonui.Widget::button(backend, "叶")
  let mid = @moonui.Widget::row(backend, 0.0, [leaf])
  let root = @moonui.Widget::column(backend, 0.0, [mid])
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(root)
  let direct : Array[@moonui.Event] = []
  let log : Array[String] = []
  let _ = leaf.on_any(fn(ev) {
    direct.push(ev)
    log.push("叶-直派")
  })
  // app 级订阅照旧收（旧账第三段：派发之后通知观察者）
  let seen : Array[@moonui.Event] = []
  let _ = app.on_event(leaf.target(), fn(ev) { seen.push(ev) })
  let ev = @moonui.Event::Click(leaf.target(), @moonui.MouseButton::Left)
  let hits = app.dispatch(ev)
  // 直派恰好一次、事件本体逐位同值；订阅恰好一次——两段旧账一条没动
  assert_eq(direct, [ev])
  assert_eq(seen, [ev])
  assert_eq(hits, 1)
  // 冒泡口装上也不改直派：没装拦截口，capture 阶段恒空不喊停——
  // 直派照跑、冒泡在其后（加法可见、旧账不变）
  let _ = mid.on_bubble(fn(_) { true }, fn(_) { log.push("中-bubble") })
  let _ = leaf.on_bubble(fn(_) { true }, fn(_) { log.push("叶-bubble") })
  log.clear()
  let _ = app.dispatch(ev)
  assert_eq(log, ["叶-直派", "叶-bubble", "中-bubble"])
  assert_eq(direct.length(), 2)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "长按判据：按下 400ms 到期补发、399ms 不发（T86⑧）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let now = [0]
  app.set_anim_clock(fn() { now[0] })
  let btn = @moonui.Widget::button(backend, "按住")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(@moonui.Widget::column(backend, 0.0, [btn]))
  let press : Array[@moonui.Event] = []
  let _ = btn.on_any(fn(ev) {
    match ev {
      LongPress(_) => press.push(ev)
      _ => ()
    }
  })
  // 注入按下：识别账记下（t=0），当圈不发
  now[0] = 0
  b.push_event(MouseDown(btn.target(), Left, @moonui.LogicalPoint(10.0, 10.0)))
  assert_true(app.step())
  assert_eq(press.length(), 0)
  // 时刻推进 399：还没到期（判据是 >= 400）
  now[0] = 399
  assert_false(app.step())
  assert_eq(press.length(), 0)
  // 推进 400：这一圈补发，target 就是收到 MouseDown 的那只
  now[0] = 400
  assert_true(app.step())
  assert_eq(press, [LongPress(btn.target())])
  // 到期即清账：同窗不重复补发
  now[0] = 800
  assert_false(app.step())
  assert_eq(press.length(), 1)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "长按判据：阈值内抬起无长按（T86⑧）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let now = [0]
  app.set_anim_clock(fn() { now[0] })
  let btn = @moonui.Widget::button(backend, "点")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(@moonui.Widget::column(backend, 0.0, [btn]))
  let press : Array[@moonui.Event] = []
  let _ = btn.on_any(fn(ev) {
    match ev {
      LongPress(_) => press.push(ev)
      _ => ()
    }
  })
  // 按下（t=0）→ 100ms 时抬起：抬起清账，之后怎么推进都不补发
  now[0] = 0
  b.push_event(MouseDown(btn.target(), Left, @moonui.LogicalPoint(10.0, 10.0)))
  let _ = app.step()
  now[0] = 100
  b.push_event(MouseUp(btn.target(), Left, @moonui.LogicalPoint(10.0, 10.0)))
  let _ = app.step()
  now[0] = 1000
  assert_false(app.step())
  assert_eq(press.length(), 0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "长按判据：移动超阈取消、阈内不取消（T86⑧）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let now = [0]
  app.set_anim_clock(fn() { now[0] })
  let btn = @moonui.Widget::button(backend, "按住")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(@moonui.Widget::column(backend, 0.0, [btn]))
  let press : Array[@moonui.Event] = []
  let _ = btn.on_any(fn(ev) {
    match ev {
      LongPress(_) => press.push(ev)
      _ => ()
    }
  })
  // 按下后在 8pt 阈内挪一下（~7.07pt）：识别继续，到期照发
  now[0] = 0
  b.push_event(MouseDown(btn.target(), Left, @moonui.LogicalPoint(10.0, 10.0)))
  let _ = app.step()
  now[0] = 50
  b.push_event(MouseMove(btn.target(), @moonui.LogicalPoint(17.0, 11.0)))
  let _ = app.step()
  now[0] = 400
  assert_true(app.step())
  assert_eq(press.length(), 1)
  // 重来一遍：这次挪出阈（10pt > 8pt）——当场取消，推进到 1000 也不发
  press.clear()
  now[0] = 0
  b.push_event(MouseDown(btn.target(), Left, @moonui.LogicalPoint(10.0, 10.0)))
  let _ = app.step()
  now[0] = 60
  b.push_event(MouseMove(btn.target(), @moonui.LogicalPoint(20.0, 10.0)))
  let _ = app.step()
  now[0] = 1000
  assert_false(app.step())
  assert_eq(press.length(), 0)
  // 移动判据量的是"离开按下点多远"（起点距离，非增量）——挪回去不再回账
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "长按判据：只认左键、没注入时钟识别整体缺席（T86⑧负控制）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  // 没时钟：按下记账无从谈起（推不出"按了多久"），派发照旧、识别缺席
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let btn = @moonui.Widget::button(backend, "右键档")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(@moonui.Widget::column(backend, 0.0, [btn]))
  let kinds : Array[@moonui.Event] = []
  let _ = btn.on_any(fn(ev) { kinds.push(ev) })
  b.push_event(MouseDown(btn.target(), Right, @moonui.LogicalPoint(10.0, 10.0)))
  let _ = app.step()
  // 时钟注上也不补发右键：长按是左键手势
  let now = [0]
  app.set_anim_clock(fn() { now[0] })
  now[0] = 1000
  assert_false(app.step())
  // 直派照旧（MouseDown 到达过那只控件），LongPress 一条没有
  assert_eq(kinds.length(), 1)
  assert_true(kinds[0] is MouseDown(_, _, _))
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "长按判据：默认常量记案（T86⑧）" {
  assert_eq(@moonui.LONG_PRESS_DURATION_MS, 400)
  assert_eq(@moonui.LONG_PRESS_MOVE_THRESHOLD, 8.0)
}

///|
/// `T87①` margin 进布局的 frame 挪账：容器摆子项 = 子项 + margin——子项在自己的
/// 槽位里被四周的 margin 拉开、槽位占用长大（同轴两向都计入），兄弟项跟着后挪。
/// 度量是 mock 的确定性账（"hi" = 2 码元 → 24×20）。
test "margin 消费后的 frame 挪账：子项被拉开、占用长大（T87①判据）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let first = @moonui.Widget::label(backend, "hi")
  let second = @moonui.Widget::label(backend, "hi")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(@moonui.Widget::row(backend, 8.0, [first, second]))
  // 基准（无 margin）：第一项贴槽位原点，第二项 = 24 + 8 间距
  assert_eq(
    first.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  assert_eq(second.bounds().origin.x, 32.0)
  // 第一项配 margin=8：它在槽位里被拉开到 (8,8)、尺寸保持固有；
  // 槽位主轴占用 8+24+8 = 40，第二项 = 40 + 8 间距 = 48
  first.set_style(
    Some(@moonui.style(margin=Some(@moonui.EdgeInsets::all(8.0)))),
  )
  win.relayout()
  assert_eq(
    first.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(8.0, 8.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  assert_eq(second.bounds().origin.x, 48.0)
  // 交叉轴同账：第二项没配 margin，贴自己的槽位原点（y=0），
  // 行的高度被 margin 项撑到 8+20+8 = 36——占用长大落在行上
  assert_eq(second.bounds().origin.y, 0.0)
  assert_eq(first.frame().size.height, 20.0)
  assert_eq(
    win.content().unwrap().measure(@moonui.BoxConstraints::loose(400.0, 300.0)).height,
    36.0,
  )
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "margin 变了下一轮 step 自动重排（T87①·T55 标脏语义同族）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let first = @moonui.Widget::label(backend, "hi")
  let second = @moonui.Widget::label(backend, "hi")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(@moonui.Widget::row(backend, 0.0, [first, second]))
  first.set_style(
    Some(@moonui.style(margin=Some(@moonui.EdgeInsets::all(8.0)))),
  )
  // 标脏本身不动 frame：重排发生在下一轮 step（同 set_text/set_style 那两条的读法）
  assert_eq(
    first.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  let _ = app.step()
  assert_eq(
    first.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(8.0, 8.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  // margin 改 16：还是只 step，账跟上（槽位 16+24+16 = 56，兄弟项 = 56）
  first.set_style(
    Some(@moonui.style(margin=Some(@moonui.EdgeInsets::all(16.0)))),
  )
  assert_eq(first.bounds().origin.x, 8.0)
  let _ = app.step()
  assert_eq(
    first.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(16.0, 16.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  assert_eq(second.bounds().origin.x, 56.0)
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "零 margin 与无 margin 的树逐位同值（T87①·旧账不变）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  // 一棵配了 margin=0 的样式、一棵什么都没配——消费口对全零不包节点，
  // 两棵树的布局账必须逐位一致（无 margin 的树布局账逐位不变的直接后果）
  let zero = @moonui.Widget::label(backend, "hi")
  let plain = @moonui.Widget::label(backend, "hi")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(
    @moonui.Widget::row(backend, 8.0, [
      @moonui.Widget::row(backend, 0.0, [zero]),
      @moonui.Widget::row(backend, 0.0, [plain]),
    ]),
  )
  zero.set_style(Some(@moonui.style(margin=Some(@moonui.EdgeInsets::zero()))))
  win.relayout()
  // 配 margin=0 的那只贴自己槽位原点 (0,0)——与"没包节点"的账逐位一致；
  // 没配的那只落在 (32,0) = 24 + 8 间距——同样没有多余的位移。两处数字
  // 都是消费口跳过全零 margin 的直接读数
  assert_eq(
    zero.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  assert_eq(
    plain.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(32.0, 0.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
test "margin 与 padding 各归各（T87①·条目原句）：内缩与外扩同框叠加" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let backend = app.backend()
  let label = @moonui.Widget::label(backend, "hi")
  let win = app.create_window("MoonUI", @moonui.LogicalSize(400.0, 300.0))
  win.set_content(
    @moonui.Widget::padding(
      backend,
      @moonui.EdgeInsets::all(10.0),
      @moonui.Widget::row(backend, 0.0, [label]),
    ),
  )
  // 容器把子项往里压 10（insets），margin 这一层再与周围拉开 8：
  // 两个账各归各、同框叠加——label 落在 (10+8, 10+8)，尺寸保持固有
  label.set_style(
    Some(@moonui.style(margin=Some(@moonui.EdgeInsets::all(8.0)))),
  )
  win.relayout()
  assert_eq(
    label.bounds(),
    @moonui.LogicalRect(
      @moonui.LogicalPoint(18.0, 18.0),
      @moonui.LogicalSize(24.0, 20.0),
    ),
  )
  @moonui.Backend::terminate(b)
  assert_eq(b.live(), 0)
}

///|
/// `T129`：标准快捷键按平台取形——mac 给 ⌘（meta），其余平台给 Ctrl；
/// `standard_menu_item` 挂好组合，Quit 自带退出回调，别的留给应用 `.on()`。
test "标准快捷键按平台取形，Quit 菜单项自带退出（T129）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  // 默认血统 Unknown（= 非 mac 分支）：Ctrl 形
  assert_eq(app.standard_shortcut(@moonui.Quit), @moonui.Shortcut::ctrl("q"))
  assert_eq(app.standard_shortcut(@moonui.Paste), @moonui.Shortcut::ctrl("v"))
  assert_eq(
    app.standard_shortcut(@moonui.SelectAll),
    @moonui.Shortcut::ctrl("a"),
  )
  // 注入 Macos 换一支：⌘ 形（meta）
  b.set_host_platform(@moonui.Macos)
  assert_eq(app.standard_shortcut(@moonui.Quit), @moonui.Shortcut::meta("q"))
  assert_eq(app.standard_shortcut(@moonui.Close), @moonui.Shortcut::meta("w"))
  let quit = app.standard_menu_item(@moonui.Quit, "退出")
  assert_eq(quit.shortcut_of(), Some(@moonui.Shortcut::meta("q")))
  // Quit 自带退出回调；Save 不带——语义是应用的，`.on()` 自己接
  assert_eq(quit.handler_count(), 1)
  let save = app.standard_menu_item(@moonui.Save, "保存")
  assert_eq(save.handler_count(), 0)
  @moonui.Backend::terminate(b)
}
