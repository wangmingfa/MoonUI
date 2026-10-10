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
