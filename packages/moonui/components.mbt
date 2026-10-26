///|
/// 组合组件（§13 的 0.2 批下半）：RadioGroup / Tabs / Steps / Alert / Card /
/// Breadcrumb / Pagination / Rate——形状参考 Element UI 的同名组件，实现全是
/// 纯 MoonBit 拼装，不碰两份 C adapter。
///
/// 两条公约，都来自 0.1 已经定下的事实而不是偏好：
/// - **结构建时定死、交互态原地变。** Core 还没有"从父级摘下单个控件"的
///   API（§8 的所有权注记），所以每个组件的骨架（选项数、卡片层数、星级数）
///   在构造时一次拼好；能原地变的只有文案、选中下标、数值这些"属性级"状态，
///   走 `set_text` / `set_selected` / `set_enabled`——它们原生层就有对应物。
///   真后端不接收样式（§32 保原生外观），选中态一律用文案或使能态表达。
/// - **换内容的组件（Tabs）每次 `view()` 重建整棵树。** 这是画册（§49）用熟的
///   路子：`Window::set_content` 关旧树、挂新树，句柄一个不漏地回收由它保证。
///   调用方在 `on_change` 里再 `set_content(tabs.view())` 一次即可换页。
///
/// 事件约定与叶子控件一致（§10 / §48-16）：用户操作触发订阅回调并携带变化后
/// 的值；程序赋值（`set_selected` / `set_value` / `set_page` / `set_current`）
/// 更新状态但**不**触发回调——和 libui 那份（`T82` 删）的 setter 不回声是同一条规矩。

///|
/// RadioGroup：原生 RadioButtons 加一条"当前选中"的说明文案。
/// 选项在构造时定死；换选产生回调携带新下标。
pub struct RadioGroup[B] {
  backend : B
  options : Array[String]
  /// 当前选中的下标；`-1` = 没选中（沿 libui 的哨兵）。
  mut selected : Int32
  mut handler : ((Int32) -> Unit raise UiError)?
  radio : Widget[B]
  caption : Widget[B]
  root : Widget[B]
}

///|
fn RadioGroup::caption_text(
  options : Array[String],
  selected : Int32,
) -> String {
  if selected >= 0 && selected < options.length() {
    "当前：" + options[selected]
  } else {
    "当前：（未选择）"
  }
}

///|
pub fn[B : Backend] RadioGroup::new(
  backend : B,
  options : Array[String],
  selected : Int32,
) -> RadioGroup[B] raise UiError {
  let radio = Widget::radio_buttons(backend, options)
  let init = if selected >= 0 && selected < options.length() {
    selected
  } else {
    -1
  }
  if init >= 0 {
    radio.set_selected(init)
  }
  let caption = Widget::label(backend, RadioGroup::caption_text(options, init))
  let root = Widget::column(backend, 8.0, [radio, caption])
  let group : RadioGroup[B] = {
    backend,
    options,
    selected: init,
    handler: None,
    radio,
    caption,
    root,
  }
  let _ = radio.on_change(fn() raise UiError {
    // 通知不带内容（§48-16），下标回读原生控件
    let i = group.radio.selected()
    group.selected = i
    group.caption.set_text(RadioGroup::caption_text(group.options, i))
    match group.handler {
      Some(f) => f(i)
      None => ()
    }
  })
  group
}

///|
/// 组件的根；挂进容器或 `Window::set_content` 都用它。
pub fn[B] RadioGroup::view(self : RadioGroup[B]) -> Widget[B] {
  self.root
}

///|
pub fn[B] RadioGroup::selected(self : RadioGroup[B]) -> Int32 {
  self.selected
}

///|
pub fn[B] RadioGroup::selected_text(self : RadioGroup[B]) -> String {
  if self.selected >= 0 && self.selected < self.options.length() {
    self.options[self.selected]
  } else {
    ""
  }
}

///|
pub fn[B] RadioGroup::on_change(
  self : RadioGroup[B],
  f : (Int32) -> Unit raise UiError,
) -> Unit {
  self.handler = Some(f)
}

///|
/// 程序设值：更新原生选中与文案，不触发 `on_change`。越界下标原样不动。
pub fn[B : Backend] RadioGroup::set_selected(
  self : RadioGroup[B],
  index : Int32,
) -> Unit raise UiError {
  if index >= 0 && index < self.options.length() {
    self.selected = index
    self.radio.set_selected(index)
    self.caption.set_text(RadioGroup::caption_text(self.options, index))
  }
}

///|
/// Alert：一条醒目的提示，四种情绪（Element UI 的 Alert）。标题带情绪图标，
/// 说明另起一行。图标与标题拼在同一只 Label 上，改哪个都原地重拼。
/// `pub(all)`：包外要能构造这四个值（`pub enum` 对包外只读，`AccessRole`
/// 同一条规则）。
pub(all) enum AlertType {
  AlertInfo
  AlertSuccess
  AlertWarning
  AlertError
}

///|
fn AlertType::glyph(self : AlertType) -> String {
  match self {
    AlertInfo => "ℹ"
    AlertSuccess => "✔"
    AlertWarning => "⚠"
    AlertError => "✖"
  }
}

///|
pub struct Alert[B] {
  mut alert_type : AlertType
  mut title : String
  title_label : Widget[B]
  desc_label : Widget[B]
  root : Widget[B]
}

///|
pub fn[B : Backend] Alert::new(
  backend : B,
  alert_type : AlertType,
  title : String,
  description : String,
) -> Alert[B] raise UiError {
  let title_label = Widget::label(backend, alert_type.glyph() + " " + title)
  let desc_label = Widget::label(backend, description)
  let root = Widget::column(backend, 4.0, [title_label, desc_label])
  { alert_type, title, title_label, desc_label, root, }
}

///|
pub fn[B] Alert::view(self : Alert[B]) -> Widget[B] {
  self.root
}

///|
/// title 字段不是能省的缓存：`set_type` 重拼标题时要用"当下这份"，
/// 不存它，两次 set 之间的改写就丢了。
pub fn[B : Backend] Alert::set_title(
  self : Alert[B],
  title : String,
) -> Unit raise UiError {
  self.title = title
  self.title_label.set_text(self.alert_type.glyph() + " " + title)
}

///|
pub fn[B : Backend] Alert::set_description(
  self : Alert[B],
  text : String,
) -> Unit raise UiError {
  self.desc_label.set_text(text)
}

///|
/// 换情绪：标题行重拼成新图标 + 当下这份标题。
pub fn[B : Backend] Alert::set_type(
  self : Alert[B],
  alert_type : AlertType,
) -> Unit raise UiError {
  self.alert_type = alert_type
  self.title_label.set_text(alert_type.glyph() + " " + self.title)
}

///|
/// Card：标题 + 分隔线 + 内容（Element UI 的 Card）。内容树的形状建时定死，
/// 标题可以原地改。
pub struct Card[B] {
  header : Widget[B]
  root : Widget[B]
}

///|
pub fn[B : Backend] Card::new(
  backend : B,
  title : String,
  children : Array[Widget[B]],
) -> Card[B] raise UiError {
  let header = Widget::label(backend, title)
  let all : Array[Widget[B]] = [header, Widget::separator(backend)]
  for c in children {
    all.push(c)
  }
  let root = Widget::column(backend, 8.0, all)
  { header, root, }
}

///|
pub fn[B] Card::view(self : Card[B]) -> Widget[B] {
  self.root
}

///|
pub fn[B : Backend] Card::set_title(
  self : Card[B],
  title : String,
) -> Unit raise UiError {
  self.header.set_text(title)
}

///|
/// Steps：步骤条（Element UI 的 Steps）。每步一颗圆点（● 当步 / ○ 其余）加
/// 步骤名。只做展示与 `set_current`，完成 / 失败语义留给 0.3。
pub struct Steps[B] {
  steps : Array[String]
  mut current : Int32
  marks : Array[Widget[B]]
  root : Widget[B]
}

///|
fn Steps::mark_text(index : Int32, current : Int32) -> String {
  if index == current {
    "●"
  } else {
    "○"
  }
}

///|
/// 把 current 的圆点画到各行 Label 上。current 改变时逐只重拼，不重建树
/// ——Steps 的骨架（步数）建时定死，圆点是它唯一要动的文案。
fn[B : Backend] Steps::paint(self : Steps[B]) -> Unit raise UiError {
  for i, mark in self.marks {
    mark.set_text(Steps::mark_text(i, self.current) + " " + self.steps[i])
  }
}

///|
pub fn[B : Backend] Steps::new(
  backend : B,
  steps : Array[String],
  current : Int32,
) -> Steps[B] raise UiError {
  let marks : Array[Widget[B]] = []
  let cells : Array[Widget[B]] = []
  for i, name in steps {
    let mark = Widget::label(backend, Steps::mark_text(i, current) + " " + name)
    marks.push(mark)
    cells.push(mark)
    // 最后一步后面不加箭头
    if i < steps.length() - 1 {
      cells.push(Widget::label(backend, "→"))
    }
  }
  let root = Widget::row(backend, 12.0, cells)
  let s : Steps[B] = {
    steps,
    current: if current >= 0 && current < steps.length() {
      current
    } else {
      0
    },
    marks,
    root,
  }
  s.paint()
  s
}

///|
pub fn[B] Steps::view(self : Steps[B]) -> Widget[B] {
  self.root
}

///|
pub fn[B] Steps::current(self : Steps[B]) -> Int32 {
  self.current
}

///|
/// 程序设值：越界夹到 0 / 末步，原地重画圆点，不产生事件。
pub fn[B : Backend] Steps::set_current(
  self : Steps[B],
  index : Int32,
) -> Unit raise UiError {
  let n = self.steps.length()
  self.current = if index < 0 { 0 } else if index >= n { n - 1 } else { index }
  self.paint()
}

///|
/// Breadcrumb：面包屑（Element UI 的 Breadcrumb）。除最后一段（当前页，
/// 纯文本）外每段是可点的按钮，点哪段就把下标回调给谁。
pub struct Breadcrumb[B] {
  mut handler : ((Int32) -> Unit raise UiError)?
  root : Widget[B]
}

///|
pub fn[B : Backend] Breadcrumb::new(
  backend : B,
  items : Array[String],
) -> Breadcrumb[B] raise UiError {
  let cells : Array[Widget[B]] = []
  let links : Array[Widget[B]] = []
  let n = items.length()
  for i, name in items {
    if i > 0 {
      cells.push(Widget::label(backend, "/"))
    }
    if i == n - 1 {
      // 当前页不可点：就是它自己
      cells.push(Widget::label(backend, name))
    } else {
      let btn = Widget::button(backend, name)
      cells.push(btn)
      links.push(btn)
    }
  }
  let root = Widget::row(backend, 8.0, cells)
  let bc : Breadcrumb[B] = { handler: None, root, }
  // 回调挂在结构体建好之后：闭包按引用捕获 bc，这里赋的 handler 才是
  // 之后 on_navigate 换上的那份。
  for i, btn in links {
    let _ = btn.on_click(fn() raise UiError {
      match bc.handler {
        Some(f) => f(i)
        None => ()
      }
    })
  }
  bc
}

///|
pub fn[B] Breadcrumb::view(self : Breadcrumb[B]) -> Widget[B] {
  self.root
}

///|
pub fn[B] Breadcrumb::on_navigate(
  self : Breadcrumb[B],
  f : (Int32) -> Unit raise UiError,
) -> Unit {
  self.handler = Some(f)
}

///|
/// Pagination：分页条（Element UI 的 Pagination）。总数与页大小建时定死，
/// 页码按钮全部平铺（0.1 不做省略号折叠）；当前页用「」标出并禁用，
/// 上一页 / 下一页在边界处禁用——使能态是原生层真生效的属性（§13）。
pub struct Pagination[B] {
  total : Int32
  page_size : Int32
  mut page : Int32
  prev : Widget[B]
  next : Widget[B]
  page_btns : Array[Widget[B]]
  info : Widget[B]
  root : Widget[B]
  mut handler : ((Int32) -> Unit raise UiError)?
}

///|
fn Pagination::pages_of(total : Int32, page_size : Int32) -> Int32 {
  if total <= 0 || page_size <= 0 {
    return 0
  }
  let q = total / page_size
  if total % page_size == 0 {
    q
  } else {
    q + 1
  }
}

///|
/// 页码 / 使能态 / 说明文案的重画。page 变化就调，不重建树。
fn[B : Backend] Pagination::paint(self : Pagination[B]) -> Unit raise UiError {
  let pages = Pagination::pages_of(self.total, self.page_size)
  for p, btn in self.page_btns {
    let is_current = p + 1 == self.page
    btn.set_text(
      if is_current {
        "「" + (p + 1).to_string() + "」"
      } else {
        (p + 1).to_string()
      },
    )
    btn.set_enabled(!is_current)
  }
  self.prev.set_enabled(self.page > 1)
  self.next.set_enabled(self.page < pages)
  self.info.set_text("共 \{self.total} 条 / \{pages} 页")
}

///|
/// 用户路径：夹紧后更新 UI 并回调；被夹成原地不动的点击不回调。
fn[B : Backend] Pagination::user_set(
  self : Pagination[B],
  page : Int32,
) -> Unit raise UiError {
  let pages = Pagination::pages_of(self.total, self.page_size)
  let clamped = if page < 1 { 1 } else if page > pages { pages } else { page }
  if clamped != self.page {
    self.page = clamped
    self.paint()
  }
  if clamped == page {
    match self.handler {
      Some(f) => f(clamped)
      None => ()
    }
  }
}

///|
pub fn[B : Backend] Pagination::new(
  backend : B,
  total : Int32,
  page_size : Int32,
) -> Pagination[B] raise UiError {
  let prev = Widget::button(backend, "上一页")
  let next = Widget::button(backend, "下一页")
  let page_btns : Array[Widget[B]] = []
  let cells : Array[Widget[B]] = [prev]
  for p = 1; p <= Pagination::pages_of(total, page_size); p = p + 1 {
    let btn = Widget::button(backend, p.to_string())
    page_btns.push(btn)
    cells.push(btn)
  }
  let info = Widget::label(backend, "")
  cells.push(next)
  cells.push(info)
  let root = Widget::row(backend, 8.0, cells)
  let pg : Pagination[B] = {
    total,
    page_size,
    page: 1,
    prev,
    next,
    page_btns,
    info,
    root,
    handler: None,
  }
  pg.paint()
  let _ = prev.on_click(fn() raise UiError { pg.user_set(pg.page - 1) })
  let _ = next.on_click(fn() raise UiError { pg.user_set(pg.page + 1) })
  for p, btn in page_btns {
    let _ = btn.on_click(fn() raise UiError { pg.user_set(p + 1) })
  }
  pg
}

///|
pub fn[B] Pagination::view(self : Pagination[B]) -> Widget[B] {
  self.root
}

///|
pub fn[B] Pagination::page(self : Pagination[B]) -> Int32 {
  self.page
}

///|
pub fn[B] Pagination::pages(self : Pagination[B]) -> Int32 {
  Pagination::pages_of(self.total, self.page_size)
}

///|
/// 程序设值：夹紧、重画，不触发 `on_change`。
pub fn[B : Backend] Pagination::set_page(
  self : Pagination[B],
  page : Int32,
) -> Unit raise UiError {
  let pages = Pagination::pages_of(self.total, self.page_size)
  self.page = if page < 1 { 1 } else if page > pages { pages } else { page }
  self.paint()
}

///|
pub fn[B] Pagination::on_change(
  self : Pagination[B],
  f : (Int32) -> Unit raise UiError,
) -> Unit {
  self.handler = Some(f)
}

///|
/// Rate：评分（Element UI 的 Rate）。max 颗星建时定死，点亮 = ★、熄灭 = ☆，
/// 点第几颗就打几分；0 分只能程序设（Element 的 clearable 语义留给 0.3）。
pub struct Rate[B] {
  max : Int32
  mut value : Int32
  stars : Array[Widget[B]]
  root : Widget[B]
  mut handler : ((Int32) -> Unit raise UiError)?
}

///|
fn[B : Backend] Rate::paint(self : Rate[B]) -> Unit raise UiError {
  for i, star in self.stars {
    star.set_text(if i < self.value { "★" } else { "☆" })
  }
}

///|
/// 用户路径：点同一颗不重复回调，其余同 Pagination 的规矩。
fn[B : Backend] Rate::user_set(
  self : Rate[B],
  value : Int32,
) -> Unit raise UiError {
  if value != self.value {
    self.value = value
    self.paint()
  }
  match self.handler {
    Some(f) => f(value)
    None => ()
  }
}

///|
pub fn[B : Backend] Rate::new(
  backend : B,
  max : Int32,
  value : Int32,
) -> Rate[B] raise UiError {
  let stars : Array[Widget[B]] = []
  for i = 0; i < max; i = i + 1 {
    stars.push(Widget::button(backend, "☆"))
  }
  let root = Widget::row(backend, 4.0, stars)
  let rate : Rate[B] = {
    max,
    value: if value < 0 {
      0
    } else if value > max {
      max
    } else {
      value
    },
    stars,
    root,
    handler: None,
  }
  rate.paint()
  for i, star in stars {
    let _ = star.on_click(fn() raise UiError { rate.user_set(i + 1) })
  }
  rate
}

///|
pub fn[B] Rate::view(self : Rate[B]) -> Widget[B] {
  self.root
}

///|
pub fn[B] Rate::value(self : Rate[B]) -> Int32 {
  self.value
}

///|
/// 程序设值：夹到 0..max、重画，不触发 `on_change`。
pub fn[B : Backend] Rate::set_value(
  self : Rate[B],
  value : Int32,
) -> Unit raise UiError {
  self.value = if value < 0 {
    0
  } else if value > self.max {
    self.max
  } else {
    value
  }
  self.paint()
}

///|
pub fn[B] Rate::on_change(
  self : Rate[B],
  f : (Int32) -> Unit raise UiError,
) -> Unit {
  self.handler = Some(f)
}

///|
/// Tabs：页签（Element UI 的 Tabs）。每个页签的内容是一个构建器，切页时由
/// `view()` 整树重建（Core 还没有摘除单个子控件的 API，§8），调用方在
/// `on_change` 里 `window.set_content(tabs.view())` 一次即可换页——树是
/// 耗材，状态不是（画册 §49 的同一条路子）。
pub struct Tabs[B] {
  backend : B
  titles : Array[String]
  bodies : Array[() -> Widget[B] raise UiError]
  mut current : Int32
  mut handler : ((Int32) -> Unit raise UiError)?
}

///|
pub fn[B] Tabs::new(
  backend : B,
  titles : Array[String],
  bodies : Array[() -> Widget[B] raise UiError],
) -> Tabs[B] raise UiError {
  if titles.length() != bodies.length() {
    raise OperationFailed("页签标题与内容的数量必须一致")
  }
  { backend, titles, bodies, current: 0, handler: None, }
}

///|
pub fn[B] Tabs::current(self : Tabs[B]) -> Int32 {
  self.current
}

///|
/// 程序设值：只改状态不建树（树由下一次 `view()` 重建）；不触发 `on_change`。
pub fn[B] Tabs::select(self : Tabs[B], index : Int32) -> Unit {
  let n = self.titles.length()
  self.current = if index < 0 { 0 } else if index >= n { n - 1 } else { index }
}

///|
pub fn[B] Tabs::on_change(
  self : Tabs[B],
  f : (Int32) -> Unit raise UiError,
) -> Unit {
  self.handler = Some(f)
}

///|
/// 重建整棵内容树：页签头（当前页 ●、其余 ○）加分隔线加当前页内容。
/// 每次调用都是一棵新树，旧树由 `Window::set_content` 负责关闭回收；
/// 点页签头只改状态并回调，树换不换由调用方决定。
pub fn[B : Backend] Tabs::view(self : Tabs[B]) -> Widget[B] raise UiError {
  let cells : Array[Widget[B]] = []
  for i, title in self.titles {
    let mark = if i == self.current { "● " } else { "○ " }
    let btn = Widget::button(self.backend, mark + title)
    let _ = btn.on_click(fn() raise UiError {
      if i != self.current {
        self.select(i)
        match self.handler {
          Some(f) => f(i)
          None => ()
        }
      }
    })
    cells.push(btn)
  }
  let head = Widget::row(self.backend, 8.0, cells)
  let body = self.bodies[self.current]()
  Widget::column(self.backend, 8.0, [
    head,
    Widget::separator(self.backend),
    body,
  ])
}

///|
/// 长列表虚拟化（`T86④`）：视口内按需建原生控件、遮掉的回收——与句柄表回收
/// `T49` 同族的机制，不绕（§8 的所有权账照走：行整棵 `close_tree`，叶子句柄
/// 经 `destroy_widget` 归还句柄表）。
///
/// 载体是 `T74` 的 Scroll 视口：文档区是一根零间距 Column，行与行之间垫两块
/// **纯布局**填充（Sized 包 Spacer，零句柄——§14）把窗口外的行程占出来，所以
/// 文档总长恒等于 count × item_height，滚动行程不受 materialized 与否影响。
/// 每行包一层 `Sized`（高 = item_height）锁等高档——均匀行是虚拟化的前提，
/// 非均匀行高的档分期再记。
///
/// 第一版形状偏差（记案）：滚动偏移是**后端的事实**、Core 不存（§14，T74 同
/// 账）——所以虚拟窗口由调用方显式推进（`sync(offset, viewport)`），偏移回流
/// （后端 → Core 的读回）是另一条 ABI 的账，不在这里夹带。等高档 + 纵向 +
/// 静态 count 也是第一版的前提；换内容树（`set_content` 换掉 `view()` 的根）
/// 之后组件作废——行账已随旧树关闭，与 Tabs 的重建语义同一条规矩。
pub struct VirtualList[B] {
  backend : B
  /// 视口根（`T74`：Scroll 占用一个原生对象，判据"视口外零句柄"里那只常驻的）
  scroll : Widget[B]
  /// 文档区（零间距 Column，唯一的 Scroll 子项）
  content : Widget[B]
  /// 窗口前/后的纯布局填充（Sized 包 Spacer，零句柄），占出行程
  top_filler : Widget[B]
  bottom_filler : Widget[B]
  /// 均匀行高（逻辑像素，必须为正——等高档的前提）
  item_height : Double
  /// 列表总行数（静态档；`set_count` 换数据源时改这一格）
  mut count : Int32
  /// 行工厂：按行号建一行的内容（叶子；组件包 Sized 锁等高）
  build : (Int32) -> Widget[B] raise UiError
  /// 当下 materialized 的行（行号 + 行根），按行序
  mut rows : Array[(Int32, Widget[B])]
  /// 当下窗口的第一行
  mut first : Int32
  /// 同步参数去重：同窗重复 sync 零 churn（不建不毁）
  mut last_offset : Double?
  mut last_viewport : Double?
}

///|
pub fn[B : Backend] VirtualList::new(
  backend : B,
  count : Int32,
  item_height : Double,
  build : (Int32) -> Widget[B] raise UiError,
) -> VirtualList[B] raise UiError {
  if count < 0 {
    raise OperationFailed("列表行数不能为负")
  }
  if item_height <= 0.0 {
    raise OperationFailed("虚拟列表的行高必须为正")
  }
  let content = Widget::column(backend, 0.0, [])
  let top = Widget::sized(backend, None, Some(0.0), Widget::spacer(backend))
  let bottom = Widget::sized(backend, None, Some(0.0), Widget::spacer(backend))
  for f in [top, bottom] {
    content.add_child(f)
  }
  let scroll = Widget::scroll(backend, Vertical, content)
  VirtualList::{
    backend,
    scroll,
    content,
    top_filler: top,
    bottom_filler: bottom,
    item_height,
    count,
    build,
    rows: [],
    first: 0,
    last_offset: None,
    last_viewport: None,
  }
}

///|
/// 视口根（`T74` 的 Scroll）：调用方把它交给 `Window::set_content`（挂进文档区）。
pub fn[B] VirtualList::view(self : VirtualList[B]) -> Widget[B] {
  self.scroll
}

///|
/// 当下 materialized 的行数——判据"视口外零句柄"的读数口之一。
pub fn[B] VirtualList::materialized_count(self : VirtualList[B]) -> Int32 {
  self.rows.length()
}

///|
/// 当下窗口的第一行号——判据"遮掉的回收"的读数口之二。
pub fn[B] VirtualList::materialized_first(self : VirtualList[B]) -> Int32 {
  self.first
}

///|
/// 换数据源（`T128`）：改总行数并按新数据重建当下的物化窗口。
///
/// 为什么整窗回收而不是"留着行号没变的行"：行是行工厂按**当时**的视图内容建
/// 的，视图换过之后同一个行号背后往往已经是另一首歌——留着的就是旧文案（切
/// 页签时那 11 行会原地显示上一个页签的歌）。所以这里把窗内行整棵 `close_tree`
/// 再清掉 `sync` 的去重缓存，下一次 `sync` 按新行数从头补建——行数相同的档也
/// 一样重建，不吃去重。
///
/// 行数没变时 `sync` 的既有幸存逻辑也会把这些行当"在窗"留着，这是本函数必须
/// 自己回收而不能只改 `count` 的原因。
pub fn[B : Backend] VirtualList::set_count(
  self : VirtualList[B],
  count : Int32,
) -> Unit raise UiError {
  if count < 0 {
    raise OperationFailed("列表行数不能为负")
  }
  for pair in self.rows {
    pair.1.close_tree()
  }
  self.rows.clear()
  self.first = 0
  self.count = count
  self.last_offset = None
  self.last_viewport = None
}

///|
/// 推进虚拟窗口：offset 是文档坐标下的滚动偏移、viewport 是视口高（均逻辑
/// 像素，负值按零处理）。窗口 = [floor(offset/item_height), …, +ceil(
/// viewport/item_height)+1 行)——上下各留一行半行的档；越界夹到列表两端。
/// 同参数重复调用是幂等空操作（零建零毁）；参数变了先整棵回收出窗的行、
/// 再按行序补齐缺的行——行的增删走 `close_tree`/`add_child`（§8），句柄
/// 归还句柄表（`T49` 族），不绕机制。
pub fn[B : Backend] VirtualList::sync(
  self : VirtualList[B],
  offset : Double,
  viewport : Double,
) -> Unit raise UiError {
  let off = if offset < 0.0 { 0.0 } else { offset }
  let vp = if viewport < 0.0 { 0.0 } else { viewport }
  if self.last_offset == Some(off) && self.last_viewport == Some(vp) {
    return
  }
  self.last_offset = Some(off)
  self.last_viewport = Some(vp)
  let n = self.count
  let mut first = (off / self.item_height).floor().to_int()
  if first < 0 {
    first = 0
  } else if first > n {
    first = n
  }
  let mut visible = (vp / self.item_height).ceil().to_int() + 1
  if visible < 1 {
    visible = 1
  }
  if n - first < visible {
    visible = n - first
  }
  // 出窗的行整棵回收（叶子句柄归表，`T49` 族机制）；在窗的留下
  let survivors : Array[(Int32, Widget[B])] = []
  for pair in self.rows {
    if pair.0 >= first && pair.0 < first + visible {
      survivors.push(pair)
    } else {
      pair.1.close_tree()
    }
  }
  // 按行序补齐：缺的行现场建（工厂给内容、组件包 Sized 锁等高），垫进
  // 文档区的孩子数组——[top_filler, *rows, bottom_filler]
  let children : Array[Widget[B]] = [self.top_filler]
  let new_rows : Array[(Int32, Widget[B])] = []
  for i = first; i < first + visible; i = i + 1 {
    let mut found : Widget[B]? = None
    for pair in survivors {
      if pair.0 == i {
        found = Some(pair.1)
      }
    }
    match found {
      Some(w) => {
        children.push(w)
        new_rows.push((i, w))
      }
      None => {
        let row = (self.build)(i)
        let wrapper = Widget::sized(
          self.backend,
          None,
          Some(self.item_height),
          row,
        )
        self.content.add_child(wrapper)
        // 行在窗口树下推进的档（`view()` 已挂进窗口）：新行的叶子要补挂进
        // Scroll 的文档区——`set_content` 的挂接遍历只覆盖推进前已在的行，
        // 缺这一步真后端上叶子没有父级。挂接动作仍走 `T74` 那套
        // `attach_widget_to`（容器 = Scroll 自己），不绕机制。
        if self.scroll.attached {
          match self.scroll.handle {
            Some(sc) => {
              let pairs : Array[(NativeHandle?, NativeHandle)] = []
              wrapper.collect_attach(Some(sc), pairs)
              for p in pairs {
                match p.0 {
                  Some(c) => Backend::attach_widget_to(self.backend, c, p.1)
                  None => ()
                }
              }
            }
            None => ()
          }
        }
        children.push(wrapper)
        new_rows.push((i, wrapper))
      }
    }
  }
  children.push(self.bottom_filler)
  self.content.children = children
  self.rows = new_rows
  self.first = first
  // 行程账：窗口外的行程由两块纯布局填充占位——文档总长恒等于 count × 行高
  self.top_filler.fixed_h = Some(first.to_double() * self.item_height)
  self.bottom_filler.fixed_h = Some(
    (n - first - visible).to_double() * self.item_height,
  )
}
