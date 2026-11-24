///|
/// `T359` 浮层抽象判据。全部跑在 @moonui.MockBackend 上——点外部关闭、Esc 关闭、
/// owner 归属、负控制都不依赖真机。几何/焦点按"读被测行为写下的可观测状态"
/// 验（criteria.md：不复用被测实现那份账）。

///|
/// 判据前提：浮层内容树与 `@moonui.App.windows` 里那只是**同一份**（Window 可变字段共享）。
/// 若 MoonBit struct 是值拷贝，这条会立刻红——那正是要先钉死的语义。
test "浮层内容树挂在 @moonui.App 上，事件能路由进去（T359）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(180.0, 120.0))
  assert_eq(app.popup_count(), 1)
  let cell = @moonui.Widget::label(b, "item")
  let fired : Array[Int32] = [0]
  let _ = cell.on_click(fn() { fired[0] = fired[0] + 1 })
  popup.window().set_content(cell)
  // 事件 target 是浮层里的控件，@moonui.App 应能在浮层窗里找到它并派发 @moonui.Click。
  let _ = app.dispatch(@moonui.Click(cell.target(), @moonui.Left))
  assert_eq(fired[0], 1)
}

///|
/// owner 归属：create_popup_window 必须把 owner 句柄推到后端（不是随便建只窗）。
/// 负控制见下方——换成 create_window 这条会红。
test "浮层把 owner 句柄推给后端（T359）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(180.0, 120.0))
  let mw = b.window(popup.window().handle())
  match mw.popup_owner {
    Some(h) => assert_eq(h, host.handle())
    None => assert_true(false)
  }
  // 普通窗不是浮层：owner 为空。
  let hw = b.window(host.handle())
  match hw.popup_owner {
    None => ()
    Some(_) => assert_true(false)
  }
}

///|
/// Esc 关栈顶：连开两层，Esc 只关最上面那只，且吞掉事件（hits == 0）。
test "Esc 关栈顶浮层并吞掉事件（T359）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let p1 = app.open_popup(host, @moonui.LogicalSize(100.0, 80.0))
  let _p2 = app.open_popup(host, @moonui.LogicalSize(100.0, 80.0))
  assert_eq(app.popup_count(), 2)
  let esc = @moonui.KeyPress::{
    key: "Escape",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let hits = app.dispatch(@moonui.KeyDown(host.target(), esc))
  assert_eq(hits, 0)
  assert_eq(app.popup_count(), 1)
  match app.top_popup() {
    Some(p) => assert_eq(p.window().handle(), p1.window().handle())
    None => assert_true(false)
  }
  // 非 Esc 键不关浮层。
  let other = @moonui.KeyPress::{
    key: "a",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let _ = app.dispatch(@moonui.KeyDown(host.target(), other))
  assert_eq(app.popup_count(), 1)
}

///|
/// 点外部关闭：@moonui.MouseDown 落在浮层树外 → 关栈顶；落在浮层控件上 → 不关。
test "点浮层外关闭，点浮层内保持（T359）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(180.0, 120.0))
  let item = @moonui.Widget::label(b, "item")
  popup.window().set_content(item)
  // 点在浮层控件上：不关。
  let _ = app.dispatch(
    @moonui.MouseDown(
      item.target(),
      @moonui.Left,
      @moonui.LogicalPoint(10.0, 10.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(app.popup_count(), 1)
  // 点在宿主窗口上（浮层树外）：关。
  let _ = app.dispatch(
    @moonui.MouseDown(
      host.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(app.popup_count(), 0)
  assert_true(popup.window().is_closed())
}

///|
/// 关浮层不误伤宿主：宿主仍活着，app 不因此退出。
test "关浮层不关宿主窗口（T359）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(180.0, 120.0))
  app.close_popup(popup)
  assert_eq(app.popup_count(), 0)
  assert_true(popup.window().is_closed())
  assert_true(!host.is_closed())
  assert_eq(app.live_window_count(), 1)
}

///|
/// 幂等：同一只浮层 close 两次不抛、不重复计数。
test "重复关浮层幂等（T359）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(180.0, 120.0))
  app.close_popup(popup)
  app.close_popup(popup)
  assert_eq(app.popup_count(), 0)
}

///|
/// 关闭回调：三条关闭路径（显式 / Esc / 点外部）都要触发，且**只触发一次**。
/// 这条是"控件以为自己还开着、于是再也开不出来"那个 bug 的判据——去掉
/// `close_popup` 里的回调调用，下面三个计数都会停在 0。
test "关闭回调在三条路径上各触发一次（T359）" {
  let esc = @moonui.KeyPress::{
    key: "Escape",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  // ① 显式 close_popup，然后重复关不得二次触发。
  {
    let app = @moonui.App(@moonui.MockBackend())
    let b = app.backend()
    @moonui.Backend::init(b)
    let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
    let popup = app.open_popup(host, @moonui.LogicalSize(100.0, 80.0))
    let n : Array[Int32] = [0]
    popup.on_close(fn() { n[0] = n[0] + 1 })
    app.close_popup(popup)
    assert_eq(n[0], 1)
    app.close_popup(popup)
    assert_eq(n[0], 1)
  }
  // ② Esc 关栈顶也要触发。
  {
    let app = @moonui.App(@moonui.MockBackend())
    let b = app.backend()
    @moonui.Backend::init(b)
    let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
    let popup = app.open_popup(host, @moonui.LogicalSize(100.0, 80.0))
    let n : Array[Int32] = [0]
    popup.on_close(fn() { n[0] = n[0] + 1 })
    let _ = app.dispatch(@moonui.KeyDown(host.target(), esc))
    assert_eq(n[0], 1)
    assert_eq(app.popup_count(), 0)
  }
  // ③ 点外部也要触发。
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(100.0, 80.0))
  let n : Array[Int32] = [0]
  popup.on_close(fn() { n[0] = n[0] + 1 })
  let _ = app.dispatch(
    @moonui.MouseDown(
      host.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(n[0], 1)
}

///|
/// 给控件挂一对 Focus/Blur 计数器。判据读这两个数，不读被测实现自己那份账。
fn count_focus(
  w : @moonui.Widget[@moonui.MockBackend],
  focus : Array[Int32],
  blur : Array[Int32],
) -> Unit raise @moonui.UiError {
  let _ = w.on(
    fn(e) {
      match e {
        @moonui.Focus(_) => true
        @moonui.Blur(_) => true
        _ => false
      }
    },
    fn(e) {
      match e {
        @moonui.Focus(_) => focus[0] = focus[0] + 1
        @moonui.Blur(_) => blur[0] = blur[0] + 1
        _ => ()
      }
    },
  )
}

///|
/// 焦点账（`T359①`）：`set_focus` 先给旧的派 `Blur`、再给新的派 `Focus`；
/// 与当下相同则一条事件都不发（否则皮肤账每帧闪一次）。
test "焦点账：set_focus 派 Blur→Focus，同值幂等（T359①）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let a = @moonui.Widget::label(b, "a")
  let c = @moonui.Widget::label(b, "c")
  let fa : Array[Int32] = [0]
  let ba : Array[Int32] = [0]
  let fc : Array[Int32] = [0]
  let bc : Array[Int32] = [0]
  count_focus(a, fa, ba)
  count_focus(c, fc, bc)
  host.set_content(@moonui.Widget::column(b, 0.0, [a, c]))
  assert_eq(app.focused_target(), None)
  app.set_focus(Some(a.target()))
  assert_eq(app.focused_target(), Some(a.target()))
  assert_eq([fa[0], ba[0], fc[0], bc[0]], [1, 0, 0, 0])
  // 同值：一条都不发
  app.set_focus(Some(a.target()))
  assert_eq([fa[0], ba[0], fc[0], bc[0]], [1, 0, 0, 0])
  // 换人：旧的 Blur、新的 Focus
  app.set_focus(Some(c.target()))
  assert_eq([fa[0], ba[0], fc[0], bc[0]], [1, 1, 1, 0])
  // 清空：只给旧的派 Blur
  app.set_focus(None)
  assert_eq(app.focused_target(), None)
  assert_eq([fc[0], bc[0]], [1, 1])
}

///|
/// 浮层开时把焦点交给内容树里**声明序第一个**可聚焦控件：跳过不可聚焦的
/// 兄弟，空树/没有可聚焦控件时如实返回 `false` 且账不动。
test "focus_popup 跳到声明序第一个可聚焦控件（T359①）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(200.0, 120.0))
  // 内容还没装：没有可交给的人。
  assert_true(!app.focus_popup(popup))
  assert_eq(app.focused_target(), None)
  let label = @moonui.Widget::label(b, "静态")
  let f1 = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(60.0, 20.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  let f2 = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(60.0, 20.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  popup.window().set_content(@moonui.Widget::column(b, 0.0, [label, f1, f2]))
  assert_true(app.focus_popup(popup))
  assert_eq(app.focused_target(), Some(f1.target()))
}

///|
/// 开窗时快照归还目标，关窗最后一步自动把焦点派回去——调用方不用再记一份。
test "开浮层记归还目标，关窗自动归还焦点（T359①）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let trig = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(80.0, 24.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  let ft : Array[Int32] = [0]
  let bt : Array[Int32] = [0]
  count_focus(trig, ft, bt)
  host.set_content(trig)
  app.set_focus(Some(trig.target()))
  assert_eq(ft[0], 1)
  let popup = app.open_popup(host, @moonui.LogicalSize(160.0, 90.0))
  let inner = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(60.0, 20.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  let fi : Array[Int32] = [0]
  let bi : Array[Int32] = [0]
  count_focus(inner, fi, bi)
  popup.window().set_content(inner)
  assert_true(app.focus_popup(popup))
  assert_eq(app.focused_target(), Some(inner.target()))
  assert_eq([bt[0], fi[0]], [1, 1])
  app.close_popup(popup)
  assert_eq(app.focused_target(), Some(trig.target()))
  // 归还就是再派一条 Focus 给触发器（皮肤账要重新亮起）。
  assert_eq(ft[0], 2)
}

///|
/// 焦点**真的到了后端**（`T359` ① 的写口）：`set_focus` 在派 `Focus` 之前调
/// `Backend::focus_widget`，mock 那份"原生焦点"（对应真后端的 first responder）
/// 跟着换人。不可聚焦的控件后端会拒——Core 的账照旧翻，皮肤与观察者不因为
/// 平台够不到键盘就变（`false` 不是失败）。
///
/// 负控制：摘掉 `set_focus` 里的 `move_native_focus` 调用 → `native_focus` 停在
/// `None`，第一条断言就红。
test "set_focus 把焦点交给后端，不可聚焦的控件被拒（T359①）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let label = @moonui.Widget::label(b, "静态")
  let face = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(80.0, 24.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  host.set_content(@moonui.Widget::column(b, 0.0, [label, face]))
  assert_eq(b.native_focus(), None)
  app.set_focus(Some(face.target()))
  assert_eq(b.native_focus(), Some(face.handle().unwrap()))
  // 不可聚焦：后端拒（流水第三个字段），Core 的账照翻、原生焦点原地不动。
  app.set_focus(Some(label.target()))
  assert_eq(app.focused_target(), Some(label.target()))
  assert_eq(b.native_focus(), Some(face.handle().unwrap()))
  let calls = b.focus_calls()
  assert_eq(calls.length(), 2)
  assert_true(calls[0].2)
  assert_false(calls[1].2)
}

///|
/// 写口落在**浮层那只窗**上，不是 owner 窗（`T359` ①）：`focus_popup` 交给后端
/// 的窗口句柄必须是浮层的——认错窗在真机上就是"键还归宿主那侧的 first
/// responder"，而这正是本条要修的东西。
///
/// 负控制：把 `focus_widget` 的窗口参数换成 `popup.owner()` → 第一条断言红。
test "focus_popup 的焦点写口落在浮层窗口上（T359①）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let host = app.create_window("host", @moonui.LogicalSize(400.0, 300.0))
  let popup = app.open_popup(host, @moonui.LogicalSize(180.0, 120.0))
  let f1 = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(60.0, 20.0),
    fn(_dl, _env) {  },
    focusable=true,
  )
  popup.window().set_content(f1)
  assert_true(app.focus_popup(popup))
  let calls = b.focus_calls()
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].0, popup.window().handle())
  assert_eq(calls[0].1, f1.handle().unwrap())
  // 关窗归还：写口再跑一次，这次落在 owner 窗上、目标是开窗前的焦点（无 → 不调，
  // 因为开窗前没有焦点，归还目标是 None）。
  app.close_popup(popup)
  assert_eq(b.focus_calls().length(), 1)
}
