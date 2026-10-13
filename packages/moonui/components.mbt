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
/// 更新状态但**不**触发回调——和 libui 的 setter 不回声是同一条规矩。

///|
/// RadioGroup：原生 RadioButtons 加一条"当前选中"的说明文案。
/// 选项在构造时定死；换选产生回调携带新下标。
pub struct RadioGroup[B] {
  backend : B
  options : Array[String]
  /// 当前选中的下标；`-1` = 没选中（libui 的哨兵）。
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
