///|
/// 验证性示例三份的 Demo 本体（`T88④`）：设置中心、Markdown 编辑器、数据后台。
///
/// 写在库里而不只写在 examples 的壳里，沿 demo.mbt 那句老账：Demo 要有可回归
/// 的载体——`moon test` 每次把三份示例从头跑一遍（mock 后端无头），同一份代码
/// 换个后端就是真窗口（真窗演示留给 owner 手动跑，判据全在无头壳上闭环）。
/// 每份至少一条判据测试断言它验证的那块地基（黑盒判据在 dx_demo_test.mbt，
/// 落盘读档的文件半判据在 demo_dx_file_native.mbt——native 门控沿
/// window_state_file_native.mbt 的先例，wasm 没有文件系统）：
/// - 设置中心验 `T86⑦` 持久化闭环（浅深主题 + 尺寸位置 + 偏好存档恢复往返）；
/// - Markdown 编辑器验落盘读档（文件半沿 `T86⑦` 的 extern 先例同款）与
///   分栏 + 最小编排（注记：不是完整 Markdown——标题/列表/粗体/正文四类行）；
/// - 数据后台验 `T86④` 虚拟化账（视口外零句柄在 1000 行合成数据上复验）与
///   过滤切换账。
///
/// 文案硬编码中文不动（文档不是文案层；`T88②` 的 L10n 是另一条独立地基）。

///|
/// 数据后台的行账（`T88④`）：id + 姓名 + 部门。合成数据确定性生成——判据
/// 断言的是账本身（过滤前后行数、虚拟窗口的首行号），不是随机内容的巧合。
pub(all) struct AdminRow {
  id : Int32
  name : String
  dept : String
} derive(Debug, Eq)

///|
/// 数据后台的固定参数（记案）：行高与页大小都是框架默认值，判据钉的就是
/// 这对默认下的行为——1000 行 ÷ 每页 20 = 50 页，过滤单部门 250 行 = 13 页。
pub const DATA_ADMIN_ROW_HEIGHT : Double = 32.0

///|
pub const DATA_ADMIN_PAGE_SIZE : Int32 = 20

///|
/// 数据后台的部门清单（合成数据按 4 部门轮转：250 行/部门）。
fn admin_depts() -> Array[String] {
  ["研发", "产品", "运营", "市场"]
}

///|
/// 1000 行合成数据（`T88④`）：id 0..999，姓名 "员工 \{id}"，部门按清单轮转——
/// 确定性账，判据可逐行断言。
pub fn DataAdminDemo::synthetic() -> Array[AdminRow] {
  let depts = admin_depts()
  let rows : Array[AdminRow] = []
  for i = 0; i < 1000; i = i + 1 {
    rows.push(AdminRow::{
      id: i,
      name: "员工 \{i}",
      dept: depts[i % depts.length()],
    })
  }
  rows
}

///|
pub struct DataAdminDemo[B] {
  backend : B
  app : App[B]
  window : Window[B]
  /// 过滤器（ComboBox：全部 + 各部门），过滤切换账的载体
  filter : Widget[B]
  /// 分页条——total 与 filtered 行数绑死，过滤切换时整只重建（total 建时定死，
  /// components.mbt 的既定口径）
  mut pager : Pagination[B]
  /// 表格页的挂点：VirtualList 的 view 整只换树重建的位置
  pane : Widget[B]
  /// 当下的虚拟列表（count 与过滤后行数绑死，过滤切换时整只重建——
  /// VirtualList 是静态 count 档，行账随旧树关闭）
  mut list : VirtualList[B]
  /// 当下过滤后的行账（判据读数口 rows 的来源）
  mut dataset : Array[AdminRow]
  /// 分页偏移推进过的视口高（判据显式推进；过滤/换页的重推进沿它）
  mut viewport : Double
}

///|
/// 数据后台（`T88④`）：过滤器 + 分页条 + 表格页（VirtualList）三段一窗。
/// 表格页的虚拟列表 count 与**过滤后**行数绑死——换页不重建（分页是滚动偏移
/// 的跳账，VirtualList 的窗口跟着 offset 走），过滤才重建（count 变了，行账
/// 随旧树关闭——静态 count 档的既定语义）。
pub fn[B : Backend] DataAdminDemo::demo(
  app : App[B],
) -> DataAdminDemo[B] raise UiError {
  let b = app.backend()
  let dataset = DataAdminDemo::synthetic()
  let filter = Widget::combobox(b, ["全部"])
  for d in admin_depts() {
    filter.append_option(d)
  }
  let pager = Pagination::new(b, dataset.length(), DATA_ADMIN_PAGE_SIZE)
  let pane = Widget::column(b, 0.0, [])
  let root = Widget::column(b, 8.0, [filter, pager.view(), pane])
  let win = app.create_window("数据后台", LogicalSize(800.0, 600.0))
  win.set_content(root)
  win.show()
  // 表格页：行账绝对映射（行号 i = dataset[i]），建行闭包按重建时刻的行账钉住
  let build = fn(i : Int32) raise UiError {
    let row = dataset[i]
    Widget::label(b, "\{row.id}  \{row.name}  \{row.dept}")
  }
  let list = VirtualList::new(b, dataset.length(), DATA_ADMIN_ROW_HEIGHT, build)
  pane.children = [list.view()]
  let demo : DataAdminDemo[B] = {
    backend: b,
    app,
    window: win,
    filter,
    pager,
    pane,
    list,
    dataset,
    viewport: 0.0,
  }
  demo
}

///|
/// 挂点换树：旧树整棵回收（句柄归表，`T49` 族机制）、新 view 挂进 pane。
/// 挂接账沿 VirtualList 的补挂先例——窗口已在（构造完成后的重建）时，新 view
/// 的叶子补挂进后端的父子表（容器链是 pane 的父级窗口——pane 是纯布局节点）。
fn[B : Backend] DataAdminDemo::replace_pane(
  self : DataAdminDemo[B],
  view : Widget[B],
) -> Unit raise UiError {
  for c in self.pane.children {
    c.close_tree()
  }
  self.pane.children = [view]
  if self.window.content() is Some(_) {
    let wh = self.window.handle()
    let pairs : Array[(NativeHandle?, NativeHandle)] = []
    view.collect_attach(None, pairs)
    for p in pairs {
      match p.0 {
        Some(c) => Backend::attach_widget_to(self.backend, c, p.1)
        None => Backend::attach_widget(self.backend, wh, p.1)
      }
    }
  }
}

///|
/// 过滤器与分页条的用户姿势读口（判据按用户姿势复验：组件不公开内部句柄，
/// 测试沿 components_test 同一句注——读口给的是公开控件，不是字段）。
pub fn[B] DataAdminDemo::filter_view(self : DataAdminDemo[B]) -> Widget[B] {
  self.filter
}

///|
pub fn[B] DataAdminDemo::pager_view(self : DataAdminDemo[B]) -> Widget[B] {
  self.pager.view()
}

///|
/// 过滤后的行账（`T88④` 判据读数口）：全部 = 合成数据的整份；部门 = 该部门
/// 的行。index 0 是 "全部"，1..4 对应部门清单。
pub fn[B] DataAdminDemo::rows(self : DataAdminDemo[B]) -> Int32 {
  self.dataset.length()
}

///|
/// 过滤后的行账本体（判据逐行断言用）。
pub fn[B] DataAdminDemo::row(self : DataAdminDemo[B], i : Int32) -> AdminRow {
  self.dataset[i]
}

///|
pub fn[B] DataAdminDemo::page(self : DataAdminDemo[B]) -> Int32 {
  self.pager.page()
}

///|
pub fn[B] DataAdminDemo::pages(self : DataAdminDemo[B]) -> Int32 {
  self.pager.pages()
}

///|
/// 表格页当下 materialized 的行数与首行号（`T86④` 判据的两只读数口透传——
/// "视口外零句柄在 1000 行合成数据上复验"就断这两只 + 句柄总量恒定）。
pub fn[B] DataAdminDemo::materialized(self : DataAdminDemo[B]) -> Int32 {
  self.list.materialized_count()
}

///|
pub fn[B] DataAdminDemo::materialized_first(self : DataAdminDemo[B]) -> Int32 {
  self.list.materialized_first()
}

///|
/// 页码 → 滚动偏移：第 p 页的文档偏移 = (p-1) × 每页行数 × 行高（逻辑像素，
/// `T86④` 的窗口推进语义——分页是偏移的跳账，表格页跟着 offset 走）。
fn admin_page_offset(page : Int32) -> Double {
  ((page - 1) * DATA_ADMIN_PAGE_SIZE).to_double() * DATA_ADMIN_ROW_HEIGHT
}

///|
/// 显式推进虚拟窗口（`T86④`：滚动偏移是后端的事实、Core 不存——判据作为
/// 调用方显式给偏移；过滤/换页的重推进沿最近一次视口高）。
pub fn[B : Backend] DataAdminDemo::sync_rows(
  self : DataAdminDemo[B],
  offset : Double,
  viewport : Double,
) -> Unit raise UiError {
  self.viewport = viewport
  self.list.sync(offset, viewport)
}

///|
/// 过滤切换（`T88④` 判据·过滤切换账）：行账按部门切片、页码归 1、表格页与
/// 分页条整只重建——count/total 都与行数绑死，重建是既定语义不是绕行。
pub fn[B : Backend] DataAdminDemo::apply_filter(
  self : DataAdminDemo[B],
  index : Int32,
) -> Unit raise UiError {
  let depts = admin_depts()
  let next : Array[AdminRow] = []
  for row in DataAdminDemo::synthetic() {
    if index == 0 || row.dept == depts[index - 1] {
      next.push(row)
    }
  }
  self.dataset = next
  let build = fn(i : Int32) raise UiError {
    let row = next[i]
    Widget::label(self.backend, "\{row.id}  \{row.name}  \{row.dept}")
  }
  let list = VirtualList::new(
    self.backend,
    next.length(),
    DATA_ADMIN_ROW_HEIGHT,
    build,
  )
  self.list = list
  self.replace_pane(list.view())
  // 分页条整只重建：total 与新行数绑死（Pagination 的 total 建时定死）。
  // 旧分页条整棵回收（旧 view 就是根列的第 1 格——只回收一次，双重 close_tree
  // 会打到已销毁的控件上）
  let old_pager = self.pager
  self.pager = Pagination::new(
    self.backend,
    next.length(),
    DATA_ADMIN_PAGE_SIZE,
  )
  old_pager.view().close_tree()
  let root = self.window.content()
  match root {
    Some(r) =>
      // 根列的 [filter, pager, pane] 三格原地换 pager 那格（文案账不重建）
      r.children[1] = self.pager.view()
    None => ()
  }
  self.pager.set_page(1)
  self.sync_rows(0.0, self.viewport)
}

///|
/// 过滤切换的用户路径：ComboBox 派 Change → 同一条过滤账（程序路径与用户路径
/// 共账，判据按用户姿势复验）。
pub fn[B : Backend] DataAdminDemo::wire_filter(
  self : DataAdminDemo[B],
) -> Unit raise UiError {
  let _ = self.filter.on_change(fn() raise UiError {
    self.apply_filter(self.filter.selected())
  })
}

///|
/// 换页（`T88④` 判据·分页账）：页码落上分页条、表格页跟着偏移跳账——
/// VirtualList 不重建（静态 count 档，窗口推进零回收错账）。
pub fn[B : Backend] DataAdminDemo::show_page(
  self : DataAdminDemo[B],
  page : Int32,
) -> Unit raise UiError {
  self.pager.set_page(page)
  self.sync_rows(admin_page_offset(page), self.viewport)
}

///|
/// 分页条的用户路径：页码按钮的回调接到同一条跳账上（程序路径与用户路径共账）。
pub fn[B : Backend] DataAdminDemo::wire_pager(self : DataAdminDemo[B]) -> Unit {
  self.pager.on_change(fn(page) raise UiError {
    self.sync_rows(admin_page_offset(page), self.viewport)
  })
}

///|
/// Markdown 的行类（`T88④` 注记：最小子集——标题 / 列表 / 粗体 / 正文四类行，
/// 不是完整 Markdown。行级判定：`# ` 起头是标题、`- ` 起头是列表、整行裹在
/// `**…**` 里是粗体、其余是正文；空行不进账）。行内标记（一段正文里的粗体）
/// 与嵌套结构（有序列表 / 引用 / 代码块）都不在这版子集里——预览侧是"现有
/// 组件拼的最小编排"，欠账按分期记。
pub(all) enum MarkdownKind {
  Heading
  Bullet
  Bold
  Plain
} derive(Debug, Eq)

///|
pub(all) struct MarkdownLine {
  kind : MarkdownKind
  text : String
} derive(Debug, Eq)

///|
/// 行解析（`T88④`）：左栏文本 → 行账。判据断言账本身；预览侧按账拼标签。
pub fn MarkdownLine::parse(text : String) -> Array[MarkdownLine] {
  let out : Array[MarkdownLine] = []
  for line in text.split("\n") {
    let s = line.to_owned()
    if s != "" {
      let head = s[0:2].to_owned()
      if head == "# " {
        out.push(MarkdownLine::{ kind: Heading, text: s[2:].to_owned(), })
      } else if head == "- " {
        out.push(MarkdownLine::{ kind: Bullet, text: s[2:].to_owned(), })
      } else if head == "**" &&
        s.length() >= 4 &&
        s[s.length() - 2:].to_owned() == "**" {
        out.push(MarkdownLine::{
          kind: Bold,
          text: s[2:s.length() - 2].to_owned(),
        })
      } else {
        out.push(MarkdownLine::{ kind: Plain, text: s, })
      }
    }
  }
  out
}

///|
pub struct MarkdownDemo[B] {
  window : Window[B]
  /// 左栏编辑器（MultilineEntry）
  editor : Widget[B]
  /// 右栏预览（Column，按行账拼标签——原地重拼，旧标签整棵回收）
  preview : Widget[B]
}

///|
/// Markdown 编辑器（`T88④`）：左编辑右预览的分栏。预览侧按行账用现有组件拼
/// （标题加粗、列表垫 "• "、粗体加粗、正文原样）——现有组件的最小编排，
/// 不是渲染器。文件读写半沿 `T86⑦` 的落盘先例同款（同包的 archive 半，
/// native 是 extern 直指 stdio 的 MoonBit 声明、wasm 显式缺席——零新 extern）。
pub fn[B : Backend] MarkdownDemo::demo(
  app : App[B],
  text : String,
) -> MarkdownDemo[B] raise UiError {
  let b = app.backend()
  let editor = Widget::multiline(b, text)
  let preview = Widget::column(b, 4.0, [])
  let root = Widget::row(b, 8.0, [editor, preview])
  let win = app.create_window("Markdown 编辑器", LogicalSize(800.0, 600.0))
  win.set_content(root)
  win.show()
  let demo : MarkdownDemo[B] = { window: win, editor, preview, }
  demo.compose_preview(MarkdownLine::parse(text))
  demo
}

///|
/// 预览重拼（`T88④`）：按行账整列原地换——旧标签整棵回收（句柄归表），
/// 新标签按行类拼：标题加粗、列表垫 "• "、粗体加粗、正文原样。窗口已在时
/// 新标签补挂后端父子表（挂接账沿 VirtualList 的先例）。
fn[B : Backend] MarkdownDemo::compose_preview(
  self : MarkdownDemo[B],
  lines : Array[MarkdownLine],
) -> Unit raise UiError {
  for c in self.preview.children {
    c.close_tree()
  }
  let fresh : Array[Widget[B]] = []
  for line in lines {
    let label = Widget::label(self.window.backend, line.text)
    match line.kind {
      Heading | Bold => label.set_style(Some(style(font_weight=Some(Bold))))
      Bullet => label.set_text("• " + line.text)
      Plain => ()
    }
    fresh.push(label)
  }
  self.preview.children = fresh
  if self.window.content() is Some(_) {
    let wh = self.window.handle()
    for label in fresh {
      let pairs : Array[(NativeHandle?, NativeHandle)] = []
      label.collect_attach(None, pairs)
      for p in pairs {
        match p.0 {
          Some(c) => Backend::attach_widget_to(self.window.backend, c, p.1)
          None => Backend::attach_widget(self.window.backend, wh, p.1)
        }
      }
    }
  }
}

///|
pub fn[B] MarkdownDemo::window(self : MarkdownDemo[B]) -> Window[B] {
  self.window
}

///|
/// 左栏文本（判据读数口）。
pub fn[B : Backend] MarkdownDemo::editor_text(
  self : MarkdownDemo[B],
) -> String raise UiError {
  self.editor.text()
}

///|
/// 预览标签的文案账（判据读数口：拼出来的顺序即行账的顺序）。
pub fn[B : Backend] MarkdownDemo::preview_texts(
  self : MarkdownDemo[B],
) -> Array[String] raise UiError {
  let out : Array[String] = []
  for c in self.preview.children {
    out.push(c.text())
  }
  out
}

///|
/// 行账读数口（判据断言解析账本身）。
pub fn[B : Backend] MarkdownDemo::parsed(
  self : MarkdownDemo[B],
) -> Array[MarkdownLine] raise UiError {
  MarkdownLine::parse(self.editor.text())
}

///|
/// 读档（`T88④` 文件半沿 `T86⑦` 先例同款）：path 的文本读进左栏并重拼预览。
/// 没有档是常态（第一次打开，§33 的 Option 缺席读法）——左栏清空、预览清账；
/// 档在就读全量（编辑器档撑不过几 KB，一次读尽不循环）。
pub fn[B : Backend] MarkdownDemo::load_from(
  self : MarkdownDemo[B],
  path : String,
) -> Unit raise UiError {
  match archive_read(path) {
    None => {
      self.editor.set_text("")
      self.compose_preview([])
    }
    Some(content) => {
      self.editor.set_text(content)
      self.compose_preview(MarkdownLine::parse(content))
    }
  }
}

///|
/// 落盘（`T88④` 文件半沿 `T86⑦` 先例同款）：左栏全文写进 path。半份档不许
/// 存（`archive_write` 的失败形态照抄——打不开/没写完都显式报错）。
pub fn[B : Backend] MarkdownDemo::save_to(
  self : MarkdownDemo[B],
  path : String,
) -> Unit raise UiError {
  archive_write(path, self.editor.text())
}

///|
/// 设置中心的表单档控件名（记案）：用户名文本框 / 通知复选框 / 引擎下拉 /
/// 渠道单选——`T88④` 条目原文的四种表单控件各一只，判据断言值往返。
fn settings_title() -> String {
  "设置中心"
}

///|
test "设置档格式逐字段往返（T88④·格式半）" {
  let f = WindowFrame::{
    width: 800.0,
    height: 600.0,
    x: 30.0,
    y: 40.0,
    maximized: false,
  }
  let text = settings_to_json(Dark, true, f).stringify()
  // 格式钉死：单层对象、字段名固定——几何四字段与 `T86⑦` 同名同格式
  assert_eq(
    text, "{\"theme\":\"Dark\",\"reduced_motion\":true,\"width\":800,\"height\":600,\"x\":30,\"y\":40,\"maximized\":false}",
  )
  assert_eq(settings_from_json(parse_archive(text)), (Dark, true, f))
  // 损坏档显式报错（§33）：不是对象、缺字段带名字、浅深档不认第三种值
  let msgs : Array[String] = []
  msgs.push(
    dx_error(fn() raise UiError {
      let _ = settings_from_json(parse_archive("[]"))
    }),
  )
  msgs.push(
    dx_error(fn() raise UiError {
      let _ = settings_from_json(
        parse_archive("{\"theme\":\"Dark\",\"reduced_motion\":true}"),
      )
    }),
  )
  msgs.push(
    dx_error(fn() raise UiError {
      let _ = settings_from_json(
        parse_archive(
          "{\"theme\":\"Fr\",\"reduced_motion\":true,\"width\":1,\"height\":1,\"x\":0,\"y\":0,\"maximized\":false}",
        ),
      )
    }),
  )
  msgs.push(
    dx_error(fn() raise UiError {
      let _ = settings_from_json(
        parse_archive(
          "{\"theme\":\"Dark\",\"reduced_motion\":1,\"width\":1,\"height\":1,\"x\":0,\"y\":0,\"maximized\":false}",
        ),
      )
    }),
  )
  assert_eq(msgs, [
    "操作失败：设置档不是 JSON 对象", "操作失败：窗口存档缺少字段 width",
    "操作失败：设置档的 theme 不是浅深档（Fr）", "操作失败：设置档的 reduced_motion 不是布尔",
  ])
}

///|
/// 设置档判据的测试惯例（§33）：把 handler 的失败收成语明。
fn dx_error(body : () -> Unit raise UiError) -> String {
  try {
    body()
    "no error"
  } catch {
    e => e.message()
  }
}

///|
pub struct SettingsDemo[B] {
  app : App[B]
  window : Window[B]
  /// 表单档：文本框（用户名）
  username : Widget[B]
  /// 表单档：复选框（通知）
  notify : Widget[B]
  /// 表单档：下拉（引擎）
  engine : Widget[B]
  /// 表单档：单选（渠道）
  channel : Widget[B]
  /// 状态行（异步档的落点）
  status : Widget[B]
  /// 浅深主题档（档只存解析过的浅深——System 不进档，"跟随系统"不是偏好）
  mut theme : Theme
  /// 偏好开关档（`T87③`）：应用到后端读数由注入底座自理（Mock 是
  /// `set_prefers_reduced_motion`，原生半是系统偏好本身），档只存应用的选择
  mut reduced_motion : Bool
}

///|
/// 设置中心（`T88④`）：表单档四控件 + 浅深主题切换 + 偏好开关 + 状态行。
/// 持久化闭环见 `save_settings` / `restored`（文件半沿 `T86⑦` 先例同款）。
pub fn[B : Backend] SettingsDemo::demo(
  app : App[B],
  default_size : LogicalSize,
) -> SettingsDemo[B] raise UiError {
  let b = app.backend()
  let username = Widget::text_input(b, "用户名")
  let notify = Widget::checkbox(b, "启用通知", false)
  let engine = Widget::combobox(b, ["标准"])
  engine.append_option("兼容")
  engine.set_selected(0)
  let channel = Widget::radio_buttons(b, ["渠道一", "渠道二"])
  channel.set_selected(0)
  let status = Widget::label(b, "设置中心就绪")
  let root = Widget::column(b, 16.0, [username, notify, engine, channel, status])
  let win = app.create_window(settings_title(), default_size)
  win.set_content(root)
  win.show()
  SettingsDemo::{
    app,
    window: win,
    username,
    notify,
    engine,
    channel,
    status,
    theme: Light,
    reduced_motion: false,
  }
}

///|
pub fn[B] SettingsDemo::window(self : SettingsDemo[B]) -> Window[B] {
  self.window
}

///|
/// 表单档读数口（判据断言值往返）。
pub fn[B : Backend] SettingsDemo::username_text(
  self : SettingsDemo[B],
) -> String raise UiError {
  self.username.text()
}

///|
pub fn[B : Backend] SettingsDemo::set_username(
  self : SettingsDemo[B],
  text : String,
) -> Unit raise UiError {
  self.username.set_text(text)
}

///|
pub fn[B : Backend] SettingsDemo::notify_checked(
  self : SettingsDemo[B],
) -> Bool raise UiError {
  self.notify.checked()
}

///|
pub fn[B : Backend] SettingsDemo::set_notify(
  self : SettingsDemo[B],
  v : Bool,
) -> Unit raise UiError {
  self.notify.set_checked(v)
}

///|
pub fn[B : Backend] SettingsDemo::engine_selected(
  self : SettingsDemo[B],
) -> Int32 raise UiError {
  self.engine.selected()
}

///|
pub fn[B : Backend] SettingsDemo::set_engine(
  self : SettingsDemo[B],
  index : Int32,
) -> Unit raise UiError {
  self.engine.set_selected(index)
}

///|
pub fn[B : Backend] SettingsDemo::channel_selected(
  self : SettingsDemo[B],
) -> Int32 raise UiError {
  self.channel.selected()
}

///|
pub fn[B : Backend] SettingsDemo::set_channel(
  self : SettingsDemo[B],
  index : Int32,
) -> Unit raise UiError {
  self.channel.set_selected(index)
}

///|
pub fn[B : Backend] SettingsDemo::status_text(
  self : SettingsDemo[B],
) -> String raise UiError {
  self.status.text()
}

///|
/// 浅深主题切换（`T88④`）：真语义——`App::set_theme` 换底样式 + 重排一起做
/// （既有账），demo 档跟着应用的选择走。
pub fn[B : Backend] SettingsDemo::set_theme_choice(
  self : SettingsDemo[B],
  t : Theme,
) -> Unit raise UiError {
  self.theme = t
  self.app.set_theme(t)
}

///|
pub fn[B] SettingsDemo::theme(self : SettingsDemo[B]) -> Theme {
  self.theme
}

///|
/// 偏好开关（`T87③`）：demo 档记应用的选择；应用到后端读数由注入底座自理
/// （Mock 判据注入 `set_prefers_reduced_motion` 复验泵闸门，既有判据在案）。
pub fn[B] SettingsDemo::set_reduced_motion(
  self : SettingsDemo[B],
  v : Bool,
) -> Unit {
  self.reduced_motion = v
}

///|
pub fn[B] SettingsDemo::reduced_motion(self : SettingsDemo[B]) -> Bool {
  self.reduced_motion
}

///|
/// 异步档（`T85①` 可用性）：偏好同步走 `post_task`——任务在下一轮循环执行
/// （判据 `step` 一圈后断状态行）。返回取消句柄沿既有账。
pub fn[B : Backend] SettingsDemo::refresh_async(
  self : SettingsDemo[B],
) -> TaskId {
  let status = self.status
  self.app.post_task(fn() raise UiError {
    status.set_text("偏好已同步（异步档）")
  })
}

///|
/// 设置档 JSON：单层对象一条一份——主题串（"Light"/"Dark"，浅深是解析过的
/// 选择）、偏好布尔、窗口几何四字段加最大化位（`T86⑦` 同名字段同档格式，
/// `frame_from_json` 直接读得）。判据钉的就是这条格式。
fn settings_to_json(theme : Theme, reduced : Bool, f : WindowFrame) -> Json {
  Json::object(
    Map([
      (
        "theme",
        Json::string(
          match theme {
            Dark => "Dark"
            _ => "Light"
          },
        ),
      ),
      ("reduced_motion", Json::boolean(reduced)),
      ("width", Json::number(f.width)),
      ("height", Json::number(f.height)),
      ("x", Json::number(f.x)),
      ("y", Json::number(f.y)),
      ("maximized", Json::boolean(f.maximized)),
    ]),
  )
}

///|
/// 设置档解析（`T88④`）：缺字段/类型不对都是显式错误（§33——损坏的档不许
/// 静默解析成默认值），几何字段复用 `frame_from_json`（同名字段同账）。
fn settings_from_json(j : Json) -> (Theme, Bool, WindowFrame) raise UiError {
  match j {
    Object(m) => {
      let theme = match m.get("theme") {
        Some(String(s)) =>
          match s {
            "Light" => Light
            "Dark" => Dark
            _ =>
              raise OperationFailed(
                "设置档的 theme 不是浅深档（\{s}）",
              )
          }
        Some(_) => raise OperationFailed("设置档的 theme 不是字符串")
        None => raise OperationFailed("设置档缺少字段 theme")
      }
      let reduced = match m.get("reduced_motion") {
        Some(True) => true
        Some(False) => false
        Some(_) =>
          raise OperationFailed("设置档的 reduced_motion 不是布尔")
        None => raise OperationFailed("设置档缺少字段 reduced_motion")
      }
      (theme, reduced, frame_from_json(j))
    }
    _ => raise OperationFailed("设置档不是 JSON 对象")
  }
}

///|
/// 存档（`T88④` 持久化闭环）：浅深主题 + 偏好开关 + 当下第一只存活窗口的
/// 几何（`T86⑦` 的快照读数半）合成一条设置档落盘。没有存活窗口显式报错。
pub fn[B : Backend] SettingsDemo::save_settings(
  self : SettingsDemo[B],
  path : String,
) -> Unit raise UiError {
  match self.app.window_frame() {
    Some(f) =>
      archive_write(
        path,
        settings_to_json(self.theme, self.reduced_motion, f).stringify(),
      )
    None => raise OperationFailed("没有存活的窗口可存档")
  }
}

///|
/// 启动恢复（`T88④` 持久化闭环的另一半）：档在 → 按档建窗（`T86⑦` 的恢复
/// 点在建窗前）、主题与偏好应用回去；档不在（第一次启动）→ 默认尺寸默认偏好。
/// 损坏的档显式报错（§33），不静默变成"没有档"。
pub fn[B : Backend] SettingsDemo::restored(
  app : App[B],
  path : String,
  default_size : LogicalSize,
) -> SettingsDemo[B] raise UiError {
  match archive_read(path) {
    None => SettingsDemo::demo(app, default_size)
    Some(content) => {
      let (theme, reduced, frame) = settings_from_json(parse_archive(content))
      let win = app.create_window_restored(
        settings_title(),
        default_size,
        Some(frame),
      )
      app.set_theme(theme)
      // 表单档照常建（存档只存偏好与几何——表单值是会话态，不进第一版档）
      let b = app.backend()
      let username = Widget::text_input(b, "用户名")
      let notify = Widget::checkbox(b, "启用通知", false)
      let engine = Widget::combobox(b, ["标准"])
      engine.append_option("兼容")
      engine.set_selected(0)
      let channel = Widget::radio_buttons(b, ["渠道一", "渠道二"])
      channel.set_selected(0)
      let status = Widget::label(b, "设置中心就绪")
      win.set_content(
        Widget::column(b, 16.0, [username, notify, engine, channel, status]),
      )
      win.show()
      SettingsDemo::{
        app,
        window: win,
        username,
        notify,
        engine,
        channel,
        status,
        theme,
        reduced_motion: reduced,
      }
    }
  }
}
