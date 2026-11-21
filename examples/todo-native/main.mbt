///|
/// Todo 的原生后端壳（Backend #2）：`moon run examples/todo-native`。
///
/// `T340`：对标本地 TODO GUI 的 2C 标杆（Things 3 的信息架构与视觉层级），
/// 从 demo 树（`TodoList::demo`，`demo.mbt`，8 处测试引用、保持不动）升级成
/// 壳侧自持的完整应用。这一版刻意压测框架的日常通道：
///
/// - 侧栏视图切换（未完成 / 全部 / 已完成）+ 计数徽标：`for_list` 键控 diff
///   在**过滤视图**下的表现（键 = id，切视图是整表 diff 而非增删）；
/// - 皮肤通道全面下发：标题/正文/弱化色、侧栏底色、强调色（`set_style`）；
/// - 右键删除走控件上下文菜单（`set_context_menu` + `MenuItem::on`）；
/// - 空态引导（`set_visible`）；回车连续录入（`Shortcut("Enter")`，同
///   `TodoList::wire` 的既有形状）。
///
/// UI 形状（Things 3 的两段式）：
/// ```text
/// ┌────────┬────────────────────────┐
/// │ 未完成 2 │  未完成          2 项    │
/// │ 全部   5 ├────────────────────────┤
/// │ 已完成 3的前 Headers 不占位：⏸     │
/// │        ├────────────────────────┤
/// │        ├────────────────────────┤
/// │        │  [新待办…         ] [添加] │
/// └────────┴────────────────────────┘
/// ```

///|
/// 单条待办。事实源是数组，`visible_sig` 只是视图过滤的派生。
#derive(Eq)
pub(all) struct Item {
  id : Int32
  text : String
  done : Bool
}

///|
/// 视图：未完成（Things 的"今天"位，按本应用的任务模型就是"待办"）、
/// 全部、已完成。
#derive(Eq)
pub(all) enum View {
  Today
  All
  Done
}

///|
fn View::title(self : View) -> String {
  match self {
    Today => "未完成"
    All => "全部"
    Done => "已完成"
  }
}

///|
/// 视图过滤：未完成 = 待办。
fn View::keep(self : View, it : Item) -> Bool {
  match self {
    Today => !it.done
    All => true
    Done => it.done
  }
}

///|
/// 应用状态：信号与视图位在**建树之前**就位，行构建闭包与事件回调都捕获
/// 这一个对象；窗口与树句柄建好后回填（mut Option）。
pub(all) struct TodoApp[B] {
  app : @moonui.App[B]
  items_sig : @moonui.Signal[Array[Item]]
  visible_sig : @moonui.Signal[Array[Item]]
  done_sigs : Map[Int32, @moonui.Signal[Bool]]
  input_sig : @moonui.Signal[String]
  title_sig : @moonui.Signal[String]
  sub_sig : @moonui.Signal[String]
  mut next_id : Int32
  mut view : View
  mut view_rows : Map[Int32, @moonui.Widget[B]]?
  mut empty : @moonui.Widget[B]?
  mut window : @moonui.Window[B]?
}

///|
/// Things 3 的强调蓝。侧栏底 / 强调 / 正文 / 弱化全部显式下发（皮肤通道的
/// 消费面，`T339` 同一条纪律：不设才是系统默认）。
fn accent() -> @moonui.Color {
  @moonui.Color::rgb(0x47, 0x7E, 0xF3)
}

///|
fn sidebar_bg() -> @moonui.Color {
  @moonui.Color::rgb(0xF5, 0xF5, 0xF7)
}

///|
fn text_primary() -> @moonui.Color {
  @moonui.Color::rgb(0x2A, 0x2A, 0x2C)
}

///|
fn text_secondary() -> @moonui.Color {
  @moonui.Color::rgb(0x8A, 0x8A, 0x8E)
}

///|
/// 侧栏视图行的文案：「未完成  2」。
fn view_label(title : String, n : Int32) -> String {
  title + "  " + n.to_string()
}

///|
/// 重算视图过滤源 + 侧栏计数/选中态 + 空态可见性。增删勾、切视图都汇到
/// 这一处——状态派生只有一口。
fn[B : @moonui.Backend] TodoApp::refresh(
  self : TodoApp[B],
) -> Unit raise @moonui.UiError {
  let arr = self.items_sig.get()
  let visible : Array[Item] = []
  for it in arr {
    if self.view.keep(it) {
      visible.push(it)
    }
  }
  self.visible_sig.set(visible)
  let mut n_today = 0
  for it in arr {
    if !it.done {
      n_today = n_today + 1
    }
  }
  let n_all = arr.length()
  let n_done = n_all - n_today
  self.title_sig.set(self.view.title())
  self.sub_sig.set(n_all.to_string() + " 项")
  match self.empty {
    Some(e) => e.set_visible(n_all == 0)
    None => ()
  }
  match self.view_rows {
    Some(rows) =>
      for i in [0, 1, 2] {
        let row = rows[i]
        let selected = match (i, self.view) {
          (0, Today) => true
          (1, All) => true
          (2, Done) => true
          _ => false
        }
        let title = match i {
          0 => "未完成"
          1 => "全部"
          _ => "已完成"
        }
        let n = match i {
          0 => n_today
          1 => n_all
          _ => n_done
        }
        let _ = row.set_text(view_label(title, n))
        if selected {
          let _ = row.set_style(
            Some(
              @moonui.style(
                foreground=Some(accent()),
                font_size=Some(13.0),
                font_weight=Some(Bold),
              ),
            ),
          )
        } else {
          let _ = row.set_style(
            Some(
              @moonui.style(
                foreground=Some(text_primary()),
                font_size=Some(13.0),
              ),
            ),
          )
        }
      }
    None => ()
  }
}

///|
/// 添加一条（回车 / 加号钮共用）。空文案不动——Things 的输入框对空回车
/// 就是无操作，不弹状态条。
fn[B : @moonui.Backend] TodoApp::add_from_input(
  self : TodoApp[B],
) -> Unit raise @moonui.UiError {
  let text = self.input_sig.get()
  if text.length() == 0 {
    return
  }
  let id = self.next_id
  self.next_id = id + 1
  let arr = self.items_sig.get()
  arr.push(Item::{ id, text, done: false, })
  self.done_sigs[id] = @moonui.Signal(false)
  self.items_sig.set(arr)
  self.input_sig.set("")
  self.refresh()
}

///|
/// 删除一条（右键菜单）。事实源数组就地删，勾选信号记账同步清。
fn[B : @moonui.Backend] TodoApp::remove(
  self : TodoApp[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  let arr = self.items_sig.get()
  let mut found = -1
  for j = 0; j < arr.length(); j = j + 1 {
    if arr[j].id == id {
      found = j
      break
    }
  }
  if found >= 0 {
    let _ = arr.remove(found)
    self.items_sig.set(arr)
    let _ = self.done_sigs.remove(id)
    self.refresh()
  }
}

///|
/// 勾选切换：就地改事实源（引用共享），视图过滤重算。
fn[B : @moonui.Backend] TodoApp::toggle(
  self : TodoApp[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  let arr = self.items_sig.get()
  for j = 0; j < arr.length(); j = j + 1 {
    if arr[j].id == id {
      arr[j] = Item::{ id, text: arr[j].text, done: !arr[j].done, }
      break
    }
  }
  self.items_sig.set(arr)
  self.refresh()
}

///|
/// 切视图：只改视图位 + 重算（行实例由键控 diff 收拾）。
fn[B : @moonui.Backend] TodoApp::set_view(
  self : TodoApp[B],
  v : View,
) -> Unit raise @moonui.UiError {
  self.view = v
  self.refresh()
}

///|
/// 构建整棵 UI 树（main 与 wbtest 共用：真窗壳与 mock 判据走同一份代码）。
pub fn[B : @moonui.Backend] TodoApp::build(
  app : @moonui.App[B],
) -> TodoApp[B] raise @moonui.UiError {
  let b = app.backend()
  let todo = TodoApp::{
    app,
    items_sig: @moonui.Signal([]),
    visible_sig: @moonui.Signal([]),
    done_sigs: Map([]),
    input_sig: @moonui.Signal(""),
    title_sig: @moonui.Signal("未完成"),
    sub_sig: @moonui.Signal("0 项"),
    next_id: 0,
    view: Today,
    view_rows: None,
    empty: None,
    window: None,
  }
  let window = app.create_window(
    "MoonUI Todo",
    @moonui.LogicalSize(720.0, 480.0),
  )
  window.set_corner_radius(Some(12.0))
  todo.window = Some(window)
  // ——侧栏——
  let sidebar_items : Array[@moonui.Widget[B]] = []
  sidebar_items.push(
    @moonui.Widget::label(b, "MoonUI Todo")
    .foreground(text_primary())
    .font_size(15.0)
    .font_weight(Bold),
  )
  let view_rows : Map[Int32, @moonui.Widget[B]] = Map([])
  for (i, title) in [(0, "未完成"), (1, "全部"), (2, "已完成")] {
    let row = @moonui.Widget::button(b, view_label(title, 0))
      .foreground(text_primary())
      .font_size(13.0)
    let i = i
    let _ = row.on_click(fn() raise @moonui.UiError {
      todo.set_view(
        match i {
          0 => Today
          1 => All
          _ => Done
        },
      )
    })
    view_rows[i] = row
    sidebar_items.push(row)
  }
  todo.view_rows = Some(view_rows)
  let sidebar = @moonui.Widget::panel(
    b,
    @moonui.Widget::column(b, 6.0, sidebar_items),
  )
  let _ = sidebar.set_style(Some(@moonui.style(background=Some(sidebar_bg()))))
  let sidebar_box = @moonui.Widget::sized(b, Some(170.0), None, sidebar)
  // ——主区：头部 / 列表 / 空态 / 底部输入行——
  let title = @moonui.Widget::label(b, "未完成")
    .foreground(text_primary())
    .font_size(17.0)
    .font_weight(Bold)
  let _ = title.bind_text(todo.title_sig)
  let sub = @moonui.Widget::label(b, "0 项")
    .foreground(text_secondary())
    .font_size(12.0)
  let _ = sub.bind_text(todo.sub_sig)
  let header = @moonui.Widget::row(b, 8.0, [title.with_expand(true), sub])
  let empty = @moonui.Widget::label(
      b, "没有待办——在下方输入框添加一条",
    )
    .foreground(text_secondary())
    .font_size(13.0)
  todo.empty = Some(empty)
  let list = @moonui.Widget::for_list(
    b,
    todo.visible_sig,
    fn(it) { it.id },
    fn(it) raise @moonui.UiError {
      let box = @moonui.Widget::checkbox(b, it.text, it.done)
        .foreground(text_primary())
        .font_size(13.0)
      let _ = box.bind_checked(todo.done_sigs[it.id])
      let _ = box.on_change(fn() raise @moonui.UiError { todo.toggle(it.id) })
      let del = @moonui.MenuItem("删除")
      let _ = del.on(fn(_) raise @moonui.UiError { todo.remove(it.id) })
      let _ = box.set_context_menu(@moonui.Menu("行", [@moonui.Item(del)]))
      @moonui.Widget::row(b, 8.0, [box]).cross_align(Center)
    },
    4.0,
  )
  list.set_expand(true)
  let input = @moonui.Widget::text_input(b, "")
    .with_expand(true)
    .font_size(13.0)
  let _ = input.bind_input(todo.input_sig)
  let add_button = @moonui.Widget::button(b, "添加")
    .foreground(accent())
    .font_size(13.0)
  let _ = add_button.on_click(fn() raise @moonui.UiError {
    todo.add_from_input()
  })
  let enter = @moonui.Shortcut::Shortcut("Enter")
  let _ = input.on(
    fn(ev) {
      match ev {
        @moonui.KeyDown(_, kp) => enter.matches(kp)
        _ => false
      }
    },
    fn(_) raise @moonui.UiError { todo.add_from_input() },
  )
  let input_row = @moonui.Widget::row(b, 8.0, [input, add_button])
  let main = @moonui.Widget::column(b, 10.0, [
    header,
    @moonui.Widget::separator(b),
    list,
    empty,
    input_row,
  ])
  let main_body = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::all(16.0),
    main,
  )
  let root = @moonui.Widget::row(b, 0.0, [
    sidebar_box,
    main_body.with_expand(true),
  ])
  window.set_content(root)
  window.show()
  todo.refresh()
  todo
}

///|
fn main raise {
  let app = @moonui-app.new_app()
  app.set_icon("assets/logo/moonui")
  let _ = TodoApp::build(app)
  app.run()
}
