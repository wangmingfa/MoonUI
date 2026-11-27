///|
/// OpenTodo 复刻件的壳与状态（`T409`）。
///
/// `main.mbt` 只建窗口与跑事件循环；这一层把信号、数据与控件树接起来：
/// 侧栏切视图 → `set_dest`；勾选环点击 → `toggle`；快速添加条回车 → `add_task`。
/// 事实源是 `tasks`（`Array[Task]`），`sections_sig` 是它的派生（分组 + 版本号），
/// 增删勾都汇到 `refresh` 这一口。
///
/// 键控重建：`Section.rev` 参与 `for_list` 的键，勾一条任务只让**它所在那一组**
/// 的键变，其余组原地不动——与网页"勾选不整屏重渲"同一行为。

///|
pub(all) struct TodoApp[B] {
  b : B
  p : Palette
  mut tasks : Array[Task]
  mut dest : String
  /// 快速添加条的占位文案随视图变
  mut ph : String
  sections_sig : @moonui.Signal[Array[Section]]
  input_sig : @moonui.Signal[String]
  mut next_id : Int32
  mut rev : Int32
  mut window : @moonui.Window[B]?
  /// Toast 卡（叠在主卡之上，需在挂窗后 `bring_to_front` 提到最上层）
  mut toast_wgt : @moonui.Widget[B]?
}

///|
/// 建壳并把整棵树挂进窗口。真窗与 mock 判据共用这一份（`T340` 同一条纪律）。
pub fn[B : @moonui.Backend] TodoApp::build(
  app : @moonui.App[B],
) -> TodoApp[B] raise @moonui.UiError {
  let b = app.backend()
  let p = Palette::light()
  let todo = TodoApp::{
    b,
    p,
    tasks: demo_tasks.copy(),
    dest: "today",
    ph: "添加今天的任务…",
    sections_sig: @moonui.Signal([]),
    input_sig: @moonui.Signal(""),
    next_id: 100,
    rev: 0,
    window: None,
    toast_wgt: None,
  }
  // 整窗钉浅色：原生控件（输入框 / 下拉）不该跟随系统深色主题
  app.set_theme(@moonui.Theme::Light)
  app.set_style_override(Some(painter_base(p)))
  let window = app.create_window("OpenTodo", @moonui.LogicalSize(1000.0, 700.0))
  todo.window = Some(window)
  let root = todo.build_root()
  window.set_content(root)
  window.show()
  todo.refresh()
  // Toast 卡叠在主卡之上：挂窗后把它的叶子提到窗口最上层（`raise_widget`
  // 假定"层叠 = 原生 z-order"，自绘面 / Scroll 内容在快照里会被主卡盖住）。
  match todo.toast_wgt {
    Some(t) => t.bring_to_front()
    None => ()
  }
  todo
}

///|
/// 跨平台的底样式：只铺底色与文字色，字号与字族交系统默认（`DrawList::Text`
/// 没有字族槽，设了也盖不到自绘面——两路都得是默认才自洽）。
fn painter_base(p : Palette) -> @moonui.Style {
  @moonui.style(background=Some(rgb(p.canvas)), foreground=Some(rgb(p.strong)))
}

///|
fn[B : @moonui.Backend] TodoApp::build_root(
  self : TodoApp[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  let b = self.b
  let p = self.p
  // 顶栏
  let top = @moonui.Widget::column(b, 0.0, [banner(b, p, 1000.0)])
  // —— 侧栏：随 `dest` 重建
  let sidebar = @moonui.Widget::reactive(b, fn() raise @moonui.UiError {
    let cur = self.dest
    let dests = destinations(cur, self.tasks)
    sidebar(b, p, 647.0, dests, side_groups(), fn(k) raise @moonui.UiError {
      self.set_dest(k)
    })
  })
  // —— 主卡
  let card = self.build_card()
  let card2 = @moonui.Widget::sized(b, Some(736.0), Some(647.0), card)
  let body = @moonui.Widget::row(b, 0.0, [sidebar, card2]).cross_align(
    @moonui.CrossAlign::Start,
  )
  let body2 = @moonui.Widget::sized(b, Some(1000.0), Some(655.0), body)
  // —— 顶栏之下的整块留白（网页 2x 实测，逐行量得）：顶栏 36px 浅蓝，
  // y36 起一条 1px 深蓝底边线（PNG y72..73），再 8px 画布灰，卡与侧栏压在它之下
  // ——卡自带的那条 1px 顶边就是网页 y45 的整幅分隔线，所以这里不再另画一条。
  // 原先卡直接顶着顶栏、少那条深蓝边线，快照里上半屏比网页矮一截。
  //
  // 整块自绘而不是一串 spacer：1px 高的面单独摆会落在半个像素上被反走样摊成
  // 4 行，量出来比网页的线厚一倍；把深蓝线与灰底画在同一块面里就能整行对齐。
  // 见 `T411`。
  let gutter = face(b, 1000.0, 8.0, fn(dl, _env) {
    dl.fill_rect(0.0, 0.0, 1000.0, 1.0, rgb=0x375FBA)
    dl.fill_rect(0.0, 1.0, 1000.0, 7.0, rgb=p.canvas)
  })
  let shell = @moonui.Widget::column(b, 0.0, [top, gutter, body2])
  // —— Toast 叠在最上层（默认不显示）；忽略钮真的把它收掉。
  let toast = toast(b, p, fn() raise @moonui.UiError {
    match self.toast_wgt {
      Some(w) => {
        let _ = w.set_visible(false)
      }
      None => ()
    }
  })
  // 用 Padding 把 Toast 钉到窗口右下角：作为叠放面的非弹性子项按自身尺寸摆放，
  // 内缩把卡推到 (632, 580)（网页实测：352×104，右/下各 16px 外边距）。
  let toast_pos = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::{ top: 580.0, end: 16.0, bottom: 16.0, start: 632.0, },
    toast,
  )
  self.toast_wgt = Some(toast)
  // 页面底色：网页版整块视口都是画布灰（#EEF0F2），主卡四周的留白由它铺出来。
  // 根 Panel 的底色在 mac 半铺不到没被子控件盖住的边角（快照里是透明像素），
  // 所以底色自己画一块满幅自绘面垫在最底——Stack 的层叠是子树倒序，先声明的
  // 就在最下，内容与其上的 Toast 都盖在它之上。
  let page_face = face(b, 1000.0, 700.0, fn(dl, _env) {
    dl.fill_rect(0.0, 0.0, 1000.0, 700.0, rgb=p.canvas)
  })
  let root = @moonui.Widget::stack(b, [
    page_face,
    @moonui.Widget::sized(b, Some(1000.0), Some(700.0), shell),
    toast_pos,
  ])
  let rp = @moonui.Widget::panel(b, root)
  rp.set_style(Some(@moonui.style(background=Some(rgb(p.canvas)))))
  rp
}

///|
/// 主卡：圆角 10 + 1px 边，上/右/下各 8px 外边距，内边距 32。
fn[B : @moonui.Backend] TodoApp::build_card(
  self : TodoApp[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  let b = self.b
  let p = self.p
  let w = 736.0
  // 头部（随 `dest` / `sections_sig` 重建）
  let head = @moonui.Widget::reactive(b, fn() raise @moonui.UiError {
    let hd = head_for(self.dest, self.tasks)
    let _ = self.sections_sig.get()
    card_head(b, p, hd, 670.0)
  })
  // 快速添加条：输入框句柄留在外面挂 `bind_input` 与回车
  let (qa, input) = quick_add(b, p, 670.0, self.ph)
  let _ = input.bind_input(self.input_sig)
  let _ = input.on(
    fn(ev) {
      match ev {
        @moonui.KeyDown(_, kp) =>
          @moonui.Shortcut::Shortcut("Enter").matches(kp)
        _ => false
      }
    },
    fn(_) raise @moonui.UiError { self.add_task() },
  )
  // 分组列表：键 = (分组名, 版本号)，勾一条只重建它那一组
  let list = @moonui.Widget::for_list(
    b,
    self.sections_sig,
    fn(s) { (s.title, s.rev) },
    fn(s) raise @moonui.UiError {
      section_view(
        b,
        p,
        s,
        655.0,
        fn(id) { self.task_of(id) },
        fn(id) raise @moonui.UiError { self.toggle(id) },
        fn(id) raise @moonui.UiError { self.cycle_prio(id) },
        fn(id) raise @moonui.UiError { self.delete(id) },
      )
    },
    2.0,
  )
  let list_pad = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::{ top: 12.0, end: 0.0, bottom: 0.0, start: 0.0, },
    list,
  )
  let scroll = @moonui.Widget::scroll(b, @moonui.Axis::Vertical, list_pad)
  scroll.set_hover_style(None)
  // 弹性撑满剩余卡高：`sized(702, None)` 只钉宽，`set_expand(true)`（sized 是
  // layout-only，会被包成 `LayoutSpec::Expand`）让它吃 Column 的 剩余主轴。
  // 702 不是笔误：参考视口 x578..1981 = 702 CSS，卡 736 CSS = 左 32 + 702 + 右 2。
  // 右边距只有 2、不是 32——中间那 32 CSS 空隙是**视口内的留白**（内容 655 CSS
  // 右缘 1888、滚动条轨道 1954..1981，都落在视口里），不是卡的右边距。见 T413。
  let scoll = @moonui.Widget::sized(b, Some(702.0), None, scroll)
  scoll.set_expand(true)
  let col = @moonui.Widget::column(b, 10.0, [head, qa, scoll])
  let pad = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::{ top: 30.0, end: 2.0, bottom: 32.0, start: 32.0, },
    col,
  )
  let core = @moonui.Widget::panel(b, pad)
  core.set_style(
    Some(@moonui.style(background=Some(rgb(p.surface)), radius=Some(9.0))),
  )
  let m = core.margin(@moonui.EdgeInsets::{
    top: 0.0,
    end: 8.0,
    bottom: 8.0,
    start: 0.0,
  })
  boxrow(b, w, 654.0, p.surface, 10.0, p.border, m)
}

///|
/// 事实源 → 分组派生。版本号 `rev` 只在增删时 +1；勾选只让所在那组的 `rev` +1。
fn[B] TodoApp::refresh(self : TodoApp[B]) -> Unit raise @moonui.UiError {
  let secs = sections_for(self.dest, self.tasks, self.rev)
  let out : Array[Section] = []
  for s in secs {
    // 空组不画（网页也是这样：收件箱清空后整组消失）
    if s.tasks.length() > 0 {
      out.push(s)
    }
  }
  self.sections_sig.set(out)
}

///|
fn[B] TodoApp::task_of(self : TodoApp[B], id : Int32) -> Task {
  for t in self.tasks {
    if t.id == id {
      return t
    }
  }
  Task::{
    id,
    title: "",
    project: None,
    labels: [],
    priority: 0,
    due: None,
    at: None,
    estimate: 0,
    repeat: None,
    sub_done: 0,
    sub_total: 0,
    has_notes: false,
    via_api: false,
    assignee: None,
    section: None,
    comments: 0,
    done: false,
  }
}

///|
/// 勾选切换：就地改事实源，所在组的 `rev` +1（键变 → 那一组 diff 重建）。
fn[B] TodoApp::toggle(
  self : TodoApp[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  let mut found = false
  for i in 0..<self.tasks.length() {
    if self.tasks[i].id == id {
      self.tasks[i] = Task::{
        id,
        title: self.tasks[i].title,
        project: self.tasks[i].project,
        labels: self.tasks[i].labels,
        priority: self.tasks[i].priority,
        due: self.tasks[i].due,
        at: self.tasks[i].at,
        estimate: self.tasks[i].estimate,
        repeat: self.tasks[i].repeat,
        sub_done: self.tasks[i].sub_done,
        sub_total: self.tasks[i].sub_total,
        has_notes: self.tasks[i].has_notes,
        via_api: self.tasks[i].via_api,
        assignee: self.tasks[i].assignee,
        section: self.tasks[i].section,
        comments: self.tasks[i].comments,
        done: !self.tasks[i].done,
      }
      found = true
      break
    }
  }
  if found {
    self.rev = self.rev + 1
    self.refresh()
  }
}

///|
/// 循环优先级：0 → 1 → 2 → 3 → 4 → 0（网页上点旗标是这一档）。
fn[B] TodoApp::cycle_prio(
  self : TodoApp[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  for i in 0..<self.tasks.length() {
    if self.tasks[i].id == id {
      let n = self.tasks[i].priority
      self.tasks[i] = {
        ..self.tasks[i],
        priority: if n >= 4 {
          0
        } else {
          n + 1
        },
      }
      break
    }
  }
  self.rev = self.rev + 1
  self.refresh()
}

///|
/// 删除一条（操作簇的"更多"里走）。
fn[B] TodoApp::delete(
  self : TodoApp[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  let keep : Array[Task] = []
  for t in self.tasks {
    if t.id != id {
      keep.push(t)
    }
  }
  self.tasks = keep
  self.rev = self.rev + 1
  self.refresh()
}

///|
/// 回车录入：文本进当前视图的"未分组"位置，日期按今天算。
fn[B] TodoApp::add_task(self : TodoApp[B]) -> Unit raise @moonui.UiError {
  let txt = self.input_sig.peek()
  if txt.length() == 0 {
    return
  }
  let id = self.next_id
  self.next_id = id + 1
  let t = Task::{
    id,
    title: txt,
    project: None,
    labels: [],
    priority: 0,
    due: Some(DEMO_TODAY),
    at: None,
    estimate: 0,
    repeat: None,
    sub_done: 0,
    sub_total: 0,
    has_notes: false,
    via_api: false,
    assignee: None,
    section: None,
    comments: 0,
    done: false,
  }
  self.tasks.push(t)
  self.input_sig.set("")
  self.rev = self.rev + 1
  self.refresh()
}

///|
/// 切视图：改 `dest`（侧栏与卡片头部的 `reactive` 各自重建）+ 占位文案 + 分组。
fn[B] TodoApp::set_dest(
  self : TodoApp[B],
  key : String,
) -> Unit raise @moonui.UiError {
  if key == self.dest {
    return
  }
  self.dest = key
  self.ph = match key {
    "today" => "添加今天的任务…"
    "inbox" => "向收件箱添加任务…"
    _ => "添加任务…"
  }
  self.refresh()
}

///|
/// 供白盒测试读的状态切片（不碰原生层，mock 后端上也能跑）。
pub fn[B] TodoApp::sections(self : TodoApp[B]) -> Array[Section] {
  self.sections_sig.peek()
}

///|
pub fn[B] TodoApp::current(self : TodoApp[B]) -> String {
  self.dest
}
