///|
/// `T359` 自绘下拉判据。跑在 MockBackend 上——浮层栈、选中回写、点外部关闭
/// 都不依赖真机。几何期望独立手算（criteria.md：不复用被测实现那份账）。

///|
/// 造一套 app + owner + 下拉的公共形状。
fn combo_fixture() -> (
  @moonui.App[@moonui.MockBackend],
  @moonui.Window[@moonui.MockBackend],
  @widgets.UiComboBox[@moonui.MockBackend],
) raise @moonui.UiError {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let owner = app.create_window("combo", @moonui.LogicalSize(400.0, 300.0))
  let combo = @widgets.UiComboBox::UiComboBox(
    app,
    owner,
    ["红", "绿", "蓝"],
    selected=1,
  )
  owner.set_content(combo.view())
  (app, owner, combo)
}

///|
/// 初值夹取 + 设值不回调。
test "自绘下拉：初值与程序设值（T359）" {
  let (_app, _owner, combo) = combo_fixture()
  assert_eq(combo.selected(), 1)
  assert_true(!combo.is_open())
  let fired : Array[Int32] = [0]
  combo.on_change(fn(i) { fired[0] = i + 10 })
  combo.set_selected(2)
  assert_eq(combo.selected(), 2)
  assert_eq(fired[0], 0) // 程序设值不回调
  combo.set_selected(999)
  assert_eq(combo.selected(), 2) // 夹到末项
}

///|
/// 点触发器开浮层，选中回写 + 回调 + 关浮层。
test "自绘下拉：点开、选中、回调、关浮层（T359）" {
  let (app, _owner, combo) = combo_fixture()
  let fired : Array[Int32] = [0]
  combo.on_change(fn(i) { fired[0] = i })
  let trig = combo.view()
  // 建出来时 frame 是 0（没经过 relayout）——给个显式 bounds 让命中/摆位可算。
  trig.set_bounds(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 20.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  let _ = app.dispatch(
    @moonui.MouseDown(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = app.dispatch(
    @moonui.MouseUp(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(combo.is_open())
  assert_eq(app.popup_count(), 1)
  match app.top_popup() {
    Some(popup) =>
      match popup.window().content() {
        Some(list) => {
          // 第三行（index 2）：局部 y 在 [2*row_h, 3*row_h) 中间。
          let row_h = 28.0
          let _ = app.dispatch(
            @moonui.MouseUp(
              list.target(),
              @moonui.Left,
              @moonui.LogicalPoint(10.0, 2.5 * row_h),
              @moonui.Mods::none(),
            ),
          )
        }
        None => assert_true(false)
      }
    None => assert_true(false)
  }
  assert_eq(combo.selected(), 2)
  assert_eq(fired[0], 2)
  assert_true(!combo.is_open())
  assert_eq(app.popup_count(), 0)
}

///|
/// 键盘 Down 开浮层；Esc 关浮层（Core 守卫），且关掉之后**还能再开**——
/// 这条钉的是"Core 关了窗、控件还以为开着，于是再也开不出来"那个 bug：
/// 只断言 `popup_count` 是抓不到的，必须读控件自己的 `is_open()`。
test "自绘下拉：键盘开、Esc 关、还能再开（T359）" {
  let (app, _owner, combo) = combo_fixture()
  let trig = combo.view()
  trig.set_bounds(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 20.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  let down = @moonui.KeyPress::{
    key: "Down",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let _ = app.dispatch(@moonui.KeyDown(trig.target(), down))
  assert_true(combo.is_open())
  assert_eq(app.popup_count(), 1)
  let esc = @moonui.KeyPress::{
    key: "Escape",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let _ = app.dispatch(@moonui.KeyDown(trig.target(), esc))
  assert_eq(app.popup_count(), 0)
  assert_true(!combo.is_open())
  // 再开一次：控件账与 Core 栈已重新一致，键盘这条路走得通。
  let _ = app.dispatch(@moonui.KeyDown(trig.target(), down))
  assert_true(combo.is_open())
  assert_eq(app.popup_count(), 1)
}

///|
/// 点外部（宿主窗口空白处）关浮层，然后点触发器**重新开**。
/// 与 Esc 那条互补：一条走 Core 守卫的吞事件分支，一条走"不吞、落到 owner"分支。
test "自绘下拉：点外部关闭后点触发器能重开（T359）" {
  let (app, owner, combo) = combo_fixture()
  let trig = combo.view()
  trig.set_bounds(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 20.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  let down = @moonui.KeyPress::{
    key: "Down",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let _ = app.dispatch(@moonui.KeyDown(trig.target(), down))
  assert_true(combo.is_open())
  // 点在宿主窗口上（浮层树外）：Core 关栈顶、不吞事件。
  let _ = app.dispatch(
    @moonui.MouseDown(
      owner.target(),
      @moonui.Left,
      @moonui.LogicalPoint(300.0, 250.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(app.popup_count(), 0)
  assert_true(!combo.is_open())
  // 再点触发器（按下 + 抬起）：应重新开。
  let _ = app.dispatch(
    @moonui.MouseDown(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = app.dispatch(
    @moonui.MouseUp(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(combo.is_open())
  assert_eq(app.popup_count(), 1)
}

///|
/// 关掉浮层的"成因"必须是触发器自己那一下点击，否则 Core 在 MouseDown 关、
/// MouseUp 又开，用户看到的是"点不掉"。这条钉真 toggle：开着时点触发器 →
/// 关且**保持关**；再点一次 → 才重新开。
test "自绘下拉：点触发器关掉（真 toggle，T359）" {
  let (app, _owner, combo) = combo_fixture()
  let trig = combo.view()
  trig.set_bounds(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 20.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  let down = @moonui.KeyPress::{
    key: "Down",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let _ = app.dispatch(@moonui.KeyDown(trig.target(), down))
  assert_true(combo.is_open())
  // 点触发器：MouseDown 由 Core 守卫关浮层，MouseUp 不许立刻重开。
  let _ = app.dispatch(
    @moonui.MouseDown(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = app.dispatch(
    @moonui.MouseUp(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(app.popup_count(), 0)
  assert_true(!combo.is_open())
  // 再点一次：这一次没有"刚被关掉"的因果，应正常开。
  let _ = app.dispatch(
    @moonui.MouseDown(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = app.dispatch(
    @moonui.MouseUp(
      trig.target(),
      @moonui.Left,
      @moonui.LogicalPoint(5.0, 5.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(combo.is_open())
  assert_eq(app.popup_count(), 1)
}

///|
/// 空选项直接报错。
test "自绘下拉：空选项报错（T359）" {
  let app = @moonui.App(@moonui.MockBackend())
  let b = app.backend()
  @moonui.Backend::init(b)
  let owner = app.create_window("combo", @moonui.LogicalSize(400.0, 300.0))
  let r = @widgets.UiComboBox::UiComboBox(app, owner, []) catch { _ => return }
  let _ = r
  assert_true(false)
}

///|
/// 焦点账（`T359①`）：点开下拉时焦点落在触发器上，Esc 关掉之后**仍是**触发器
/// ——开窗时快照成归还目标、关窗自动派回，控件不用管这一份。
test "自绘下拉：开合都不丢触发器焦点（T359①）" {
  let (app, _owner, combo) = combo_fixture()
  let trig = combo.view()
  trig.set_bounds(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(10.0, 20.0),
      @moonui.LogicalSize(120.0, 28.0),
    ),
  )
  let down = @moonui.KeyPress::{
    key: "Down",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let _ = app.dispatch(@moonui.KeyDown(trig.target(), down))
  assert_true(combo.is_open())
  assert_eq(app.focused_target(), Some(trig.target()))
  let esc = @moonui.KeyPress::{
    key: "Escape",
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
  let _ = app.dispatch(@moonui.KeyDown(trig.target(), esc))
  assert_true(!combo.is_open())
  assert_eq(app.focused_target(), Some(trig.target()))
}
