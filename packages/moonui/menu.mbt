///|
/// 菜单模型（设计文档 §25）。
///
/// 文档的形状是 `Menu::new([MenuItem::new("New"), Separator, Submenu::new(...)])`：
/// 一个下拉里混合普通项、分隔线和子菜单。MoonBit 这个版本没有 `dyn`，数组元素
/// 必须同类型，所以混合列表落成了 `MenuNode` 枚举——语义完全保留，写起来是：
///
/// ```MoonBit
/// let new_item = MenuItem::new("New")
/// let sidebar = MenuItem::checkbox("Sidebar")
/// let file = Menu::new("File", [
///   Item(new_item),
///   Separator,
///   Submenu("View", [ Item(sidebar) ]),
/// ])
/// ```
///
/// `MenuItem` 是引用语义：先拿住对象，`Menu::new` / `MenuBar::new` 给它编号，
/// 之后 `app.activate_menu_item(new_item.id)` 读到的就是同一个 item，
/// 回调里改的勾选状态也立刻可见。
///
/// Checkbox/Radio 的选中状态只存在 Core：libui-ng 的菜单项没有可靠的读回接口，
/// 而"同组互斥"这条规则本身就是 MoonUI 的语义，不缓存反而无法实现。

///|
pub(all) enum MenuRole {
  Normal
  Check
  Radio
} derive(Debug, Eq)

///|
/// 菜单项。`id` 和 `radio_group` 在装进 `Menu`/`MenuBar` 时才赋值，
/// 之前是 `-1`——这样游离的 item 不会被误当成可点击的目标。
pub(all) struct MenuItem {
  mut id : Int
  label : String
  role : MenuRole
  mut checked : Bool
  mut enabled : Bool
  mut shortcut : Shortcut?
  mut radio_group : Int
  mut handlers : Array[MenuHandler]
  mut next_handler_id : Int
}

///|
pub(all) struct MenuHandler {
  id : Int
  call : (MenuItem) -> Unit raise UiError
}

///|
fn make_item(label : String, role : MenuRole) -> MenuItem {
  MenuItem::{
    id: -1,
    label,
    role,
    checked: false,
    enabled: true,
    shortcut: None,
    radio_group: -1,
    handlers: [],
    next_handler_id: 0,
  }
}

///|
/// 文档 §25 的 `MenuItem::new("New")`。
pub fn MenuItem::new(label : String) -> MenuItem {
  make_item(label, Normal)
}

///|
/// `MenuItem::checkbox("Sidebar")`。
pub fn MenuItem::checkbox(label : String) -> MenuItem {
  make_item(label, Check)
}

///|
/// `MenuItem::radio(...)`。同一子菜单里的 radio 项自动互斥，
/// 组号由 `Menu::new` 分配，调用方不需要再起名字。
pub fn MenuItem::radio(label : String) -> MenuItem {
  make_item(label, Radio)
}

///|
/// 文档 §25 最后一行：菜单项携带 Shortcut。这里只是把组合记在项上，
/// 真正生效要靠 `App::set_menubar`——它会把每个启用项的组合注册成快捷键。
pub fn MenuItem::set_shortcut(self : MenuItem, sc : Shortcut) -> Unit {
  self.shortcut = Some(sc)
}

///|
pub fn MenuItem::shortcut_of(self : MenuItem) -> Shortcut? {
  self.shortcut
}

///|
pub fn MenuItem::set_enabled(self : MenuItem, v : Bool) -> Unit {
  self.enabled = v
}

///|
pub fn MenuItem::is_enabled(self : MenuItem) -> Bool {
  self.enabled
}

///|
pub fn MenuItem::is_checked(self : MenuItem) -> Bool {
  self.checked
}

///|
/// 点击回调，返回订阅 id 便于 `off`。可以有多个，按注册顺序触发。
pub fn MenuItem::on(
  self : MenuItem,
  handler : (MenuItem) -> Unit raise UiError,
) -> Int {
  let id = self.next_handler_id
  self.next_handler_id = id + 1
  self.handlers.push(MenuHandler::{ id, call: handler, })
  id
}

///|
pub fn MenuItem::off(self : MenuItem, id : Int) -> Bool {
  let kept : Array[MenuHandler] = []
  for h in self.handlers {
    if h.id != id {
      kept.push(h)
    }
  }
  let removed = kept.length() != self.handlers.length()
  self.handlers = kept
  removed
}

///|
fn MenuItem::has_handler(self : MenuItem, id : Int) -> Bool {
  let mut found = false
  for h in self.handlers {
    if h.id == id {
      found = true
    }
  }
  found
}

///|
pub fn MenuItem::handler_count(self : MenuItem) -> Int {
  self.handlers.length()
}

///|
/// 只跑回调，不改勾选状态。禁用项什么都不做，返回触发个数。
/// 按索引 + 预先取长度：回调里新增的 handler 本轮不触发，被 `off` 掉的不再调用。
pub fn MenuItem::fire(self : MenuItem) -> Int raise UiError {
  if !self.enabled {
    0
  } else {
    let n = self.handlers.length()
    let mut hits = 0
    for i = 0; i < n; i = i + 1 {
      let h = self.handlers[i]
      if self.has_handler(h.id) {
        (h.call)(self)
        hits = hits + 1
      }
    }
    hits
  }
}

///|
/// 事件订阅用的目标。菜单项 id 与窗口/控件句柄 id 是两个独立编号空间，
/// 靠 `Event::MenuSelect` 这个变体区分，不会互相冒充（见 `App::dispatch`）。
pub fn MenuItem::target(self : MenuItem) -> EventTarget {
  EventTarget::{ id: self.id, }
}

///|
/// 下拉列表里的一个位置：普通项、分隔线、或子菜单（§25 的四种构件里
/// Menu 本身是容器，见下面的 `Menu`/`MenuBar`）。
pub(all) enum MenuNode {
  Item(MenuItem)
  Separator
  Submenu(String, Array[MenuNode])
}

///|
/// 编号游标。`next_group` 每遇到一层列表就 +1，所以同一层的 radio 项天然同组。
priv struct MenuStamp {
  mut next_id : Int
  mut next_group : Int
}

///|
fn stamp_nodes(nodes : Array[MenuNode], st : MenuStamp) -> Unit {
  let group = st.next_group
  st.next_group = st.next_group + 1
  for n in nodes {
    match n {
      Item(item) => {
        item.id = st.next_id
        item.radio_group = group
        st.next_id = st.next_id + 1
      }
      Separator => ()
      Submenu(_, items) => stamp_nodes(items, st)
    }
  }
}

///|
fn collect_nodes(nodes : Array[MenuNode], out : Array[MenuItem]) -> Unit {
  for n in nodes {
    match n {
      Item(item) => out.push(item)
      Separator => ()
      Submenu(_, items) => collect_nodes(items, out)
    }
  }
}

///|
fn find_in(nodes : Array[MenuNode], id : Int) -> MenuItem? {
  let items : Array[MenuItem] = []
  collect_nodes(nodes, items)
  let mut found : MenuItem? = None
  for item in items {
    if found is None && item.id == id {
      found = Some(item)
    }
  }
  found
}

///|
/// 一个顶层下拉：标题 + 条目列表（§25 的 `Menu::new([...])`）。
pub struct Menu {
  label : String
  nodes : Array[MenuNode]
}

///|
pub fn Menu::new(label : String, nodes : Array[MenuNode]) -> Menu {
  stamp_nodes(nodes, MenuStamp::{ next_id: 0, next_group: 0, })
  Menu::{ label, nodes, }
}

///|
pub fn Menu::title(self : Menu) -> String {
  self.label
}

///|
pub fn Menu::nodes(self : Menu) -> Array[MenuNode] {
  self.nodes
}

///|
/// 深度优先展开，分隔线不出现。
pub fn Menu::flatten(self : Menu) -> Array[MenuItem] {
  let out : Array[MenuItem] = []
  collect_nodes(self.nodes, out)
  out
}

///|
pub fn Menu::item_count(self : Menu) -> Int {
  self.flatten().length()
}

///|
pub fn Menu::find(self : Menu, id : Int) -> MenuItem? {
  find_in(self.nodes, id)
}

///|
/// 菜单栏：顶层菜单的有序列表。装进来时会把整棵树的 id 重新统一编号，
/// 因为每个 `Menu::new` 都从 0 开始，多个菜单直接并存必然撞号。
pub struct MenuBar {
  menus : Array[Menu]
}

///|
pub fn MenuBar::new(menus : Array[Menu]) -> MenuBar {
  let st = MenuStamp::{ next_id: 0, next_group: 0, }
  for m in menus {
    stamp_nodes(m.nodes, st)
  }
  MenuBar::{ menus, }
}

///|
pub fn MenuBar::top_labels(self : MenuBar) -> Array[String] {
  let out : Array[String] = []
  for m in self.menus {
    out.push(m.label)
  }
  out
}

///|
pub fn MenuBar::menu_count(self : MenuBar) -> Int {
  self.menus.length()
}

///|
pub fn MenuBar::all_items(self : MenuBar) -> Array[MenuItem] {
  let out : Array[MenuItem] = []
  for m in self.menus {
    for item in m.flatten() {
      out.push(item)
    }
  }
  out
}

///|
pub fn MenuBar::find(self : MenuBar, id : Int) -> MenuItem? {
  let mut found : MenuItem? = None
  for m in self.menus {
    match found {
      Some(_) => ()
      None => found = m.find(id)
    }
  }
  found
}

///|
/// 带快捷键的启用项，供 `App::set_menubar` 自动注册（§25 的 Shortcut + §26）。
/// 禁用项的组合不登记：菜单置灰时快捷键必须一起失效，否则快捷键成了隐藏入口。
pub fn MenuBar::shortcut_items(self : MenuBar) -> Array[MenuItem] {
  let out : Array[MenuItem] = []
  for item in self.all_items() {
    let scripted = match item.shortcut {
      Some(_) => true
      None => false
    }
    if scripted && item.enabled {
      out.push(item)
    }
  }
  out
}

///|
fn is_sibling_radio(other : MenuItem, item : MenuItem) -> Bool {
  other.id != item.id &&
  other.radio_group == item.radio_group &&
  other.role == Radio
}

///|
fn set_item_checked(bar : MenuBar, item : MenuItem, v : Bool) -> Bool {
  match item.role {
    Normal => false
    Check => {
      item.checked = v
      true
    }
    Radio => {
      item.checked = v
      if v {
        for other in bar.all_items() {
          if is_sibling_radio(other, item) {
            other.checked = false
          }
        }
      }
      true
    }
  }
}

///|
/// 设置勾选。Radio 项勾选时，同一子菜单里的其他 Radio 自动取消；
/// Normal 项没有勾选语义，返回 `false` 表示状态未采纳。
pub fn MenuBar::set_checked(self : MenuBar, id : Int, v : Bool) -> Bool {
  match self.find(id) {
    None => false
    Some(item) => set_item_checked(self, item, v)
  }
}

///|
fn toggle_item(bar : MenuBar, id : Int, item : MenuItem) -> Bool {
  match item.role {
    Check => {
      item.checked = !item.checked
      true
    }
    // Radio 只能被选中，取消要由同组的新选择完成
    Radio => bar.set_checked(id, true)
    Normal => false
  }
}

///|
/// Checkbox 项翻转；Radio 只能被选中，取消要由同组的新选择完成。
pub fn MenuBar::toggle(self : MenuBar, id : Int) -> Bool {
  match self.find(id) {
    None => false
    Some(item) => toggle_item(self, id, item)
  }
}

///|
/// 用户点了某一项：先按种类更新勾选状态，再跑回调。
/// 返回被激活的项，找不到（或菜单栏还没装）就是 `None`。
/// 禁用项保留状态不变也不触发回调。
pub fn MenuBar::click(self : MenuBar, id : Int) -> MenuItem? raise UiError {
  match self.find(id) {
    None => None
    Some(item) =>
      if !item.enabled {
        None
      } else {
        match item.role {
          Normal => ()
          Check => item.checked = !item.checked
          Radio => {
            let _ = self.set_checked(id, true)
          }
        }
        let _ = item.fire()
        Some(item)
      }
  }
}

///|
/// 一次点击的完整记录，测试用它断言菜单结构而不必依赖对象身份。
pub fn MenuItem::describe(self : MenuItem) -> String {
  let role = match self.role {
    Normal => ""
    Check => if self.checked { " [x]" } else { " [ ]" }
    Radio => if self.checked { " (*)" } else { " ( )" }
  }
  let accel = match self.shortcut {
    Some(sc) => "\t" + sc.label()
    None => ""
  }
  let disabled = if self.enabled { "" } else { " (禁用)" }
  self.label + role + accel + disabled
}

///|
fn bare_menu() -> (MenuItem, MenuItem, MenuItem, MenuItem, Menu) {
  let new_item = MenuItem::new("New")
  let open_item = MenuItem::new("Open")
  let sidebar = MenuItem::checkbox("Sidebar")
  let toolbar = MenuItem::checkbox("Toolbar")
  let menu = Menu::new("View", [
    Item(new_item),
    Item(open_item),
    Separator,
    Submenu("Show", [Item(sidebar), Item(toolbar)]),
  ])
  (new_item, open_item, sidebar, toolbar, menu)
}

///|
test "菜单结构照 §25 的示例建出来，id 按深度优先分配" {
  let (new_item, open_item, sidebar, toolbar, menu) = bare_menu()
  assert_eq(menu.title(), "View")
  assert_eq(menu.item_count(), 4)
  // 分隔线不占 id，子菜单里的项接在顶层项之后
  assert_eq([new_item.id, open_item.id, sidebar.id, toolbar.id], [0, 1, 2, 3])
  let flat = menu.flatten()
  assert_eq([flat[0].label, flat[1].label, flat[2].label, flat[3].label], [
    "New", "Open", "Sidebar", "Toolbar",
  ])
  assert_true(menu.find(2) is Some(_))
  assert_true(menu.find(99) is None)
}

///|
test "MenuBar 统一重编号，多个顶层菜单不会撞号" {
  let a = MenuItem::new("New")
  let b = MenuItem::new("Quit")
  let bar = MenuBar::new([
    Menu::new("File", [Item(a), Separator]),
    Menu::new("App", [Item(b)]),
  ])
  assert_eq(bar.menu_count(), 2)
  assert_eq(bar.top_labels(), ["File", "App"])
  assert_eq([a.id, b.id], [0, 1])
  assert_eq(bar.all_items().length(), 2)
}

///|
test "Checkbox 可翻转，Radio 在同组内互斥" {
  let sidebar = MenuItem::checkbox("Sidebar")
  let small = MenuItem::radio("Small")
  let large = MenuItem::radio("Large")
  let other = MenuItem::radio("Other")
  let bar = MenuBar::new([
    Menu::new("View", [
      Item(sidebar),
      Submenu("Size", [Item(small), Item(large)]),
      Submenu("Kind", [Item(other)]),
    ]),
  ])
  assert_true(bar.set_checked(sidebar.id, true))
  assert_true(sidebar.is_checked())
  assert_true(bar.toggle(sidebar.id))
  assert_false(sidebar.is_checked())

  assert_true(bar.set_checked(small.id, true))
  assert_true(bar.set_checked(large.id, true))
  assert_false(small.is_checked())
  assert_true(large.is_checked())
  // 不同子菜单是不同组，不会被牵连
  assert_true(bar.set_checked(other.id, true))
  assert_true(large.is_checked())

  // Normal 项没有勾选语义，未知 id 也一样不采纳
  let plain = MenuItem::new("Plain")
  let bar2 = MenuBar::new([Menu::new("Edit", [Item(plain)])])
  assert_false(bar2.set_checked(plain.id, true))
  assert_false(bar2.toggle(plain.id))
  assert_false(bar2.set_checked(7, true))
}

///|
test "click 按种类更新状态再触发回调，禁用项不响应" {
  let check_item = MenuItem::checkbox("Sidebar")
  let radio_a = MenuItem::radio("A")
  let radio_b = MenuItem::radio("B")
  let quit = MenuItem::new("Quit")
  let mut seen = 0
  let mut seen_label = ""
  let _ = quit.on(it => {
    seen = seen + 1
    seen_label = it.label
  })
  let bar = MenuBar::new([
    Menu::new("File", [
      Item(check_item),
      Submenu("R", [Item(radio_a), Item(radio_b)]),
      Item(quit),
    ]),
  ])
  let clicked = bar.click(check_item.id)
  assert_true(clicked is Some(_))
  assert_true(check_item.is_checked())
  let _ = bar.click(radio_a.id)
  let _ = bar.click(radio_b.id)
  assert_true(radio_b.is_checked())
  assert_false(radio_a.is_checked())
  let _ = bar.click(quit.id)
  assert_eq(seen, 1)
  assert_eq(seen_label, "Quit")

  // 禁用：状态和回调都不动
  quit.set_enabled(false)
  assert_true(bar.click(quit.id) is None)
  assert_eq(seen, 1)
  assert_true(bar.click(12345) is None)
}

///|
test "describe 把 §25 的构件渲染成一行的可读文本" {
  let sidebar = MenuItem::checkbox("Sidebar")
  sidebar.set_shortcut(Shortcut::ctrl("b"))
  let zoom = MenuItem::radio("Zoom")
  zoom.set_enabled(false)
  let bar = MenuBar::new([
    Menu::new("View", [Item(sidebar), Separator, Item(zoom)]),
  ])
  sidebar.checked = true
  let items = bar.all_items()
  assert_eq([items[0].describe(), items[1].describe()], [
    "Sidebar [x]\tCtrl+b", "Zoom ( ) (禁用)",
  ])
}

///|
/// 菜单项自带快捷键的镜像表条目（§25 的 Shortcut + §26）。
pub(all) struct MenuAccel {
  shortcut : Shortcut
  item : MenuItem
}

///|
/// 一条 `register_shortcut` 注册。
pub(all) struct ShortcutBinding {
  id : Int
  shortcut : Shortcut
  call : (Shortcut) -> Unit raise UiError
}

///|
/// 安装菜单栏（§25）。整棵替换：真实后端只能在安装时重建原生菜单，
/// 没有可靠的"就地插一项"API，所以 Core 也不提供增量修改。
/// 安装时顺带把启用项自带的组合登记成快捷键，等价于 §26 的自动注册。
pub fn[B : Backend] App::set_menubar(
  self : App[B],
  bar : MenuBar,
) -> Unit raise UiError {
  self.menubar = Some(bar)
  self.menu_accel = []
  for item in bar.shortcut_items() {
    match item.shortcut {
      Some(sc) => self.menu_accel.push(MenuAccel::{ shortcut: sc, item, })
      None => ()
    }
  }
  Backend::set_menu_bar(self.backend, bar)
}

///|
pub fn[B] App::menubar(self : App[B]) -> MenuBar? {
  self.menubar
}

///|
/// 已登记的菜单项组合数（不含 `register_shortcut` 的独立注册）。
pub fn[B] App::menu_accel_count(self : App[B]) -> Int {
  self.menu_accel.length()
}

///|
/// 点击某个菜单项，等价于原生层报来一次 MenuSelect。
/// 没装菜单栏或 id 不存在都返回 `None`——菜单是可选构件。
pub fn[B] App::click_menu_item(
  self : App[B],
  id : Int,
) -> MenuItem? raise UiError {
  match self.menubar {
    Some(bar) => bar.click(id)
    None => None
  }
}

///|
/// §26 的 `app.register_shortcut(...)`，返回 id 用于注销。
/// 允许与菜单项自带组合重复：两条都会跑，框架不做"后注册覆盖前注册"的隐式语义，
/// 那会让注册顺序决定行为，比显式冲突更难查。
pub fn[B] App::register_shortcut(
  self : App[B],
  sc : Shortcut,
  handler : (Shortcut) -> Unit raise UiError,
) -> Int {
  let id = self.next_shortcut_id
  self.next_shortcut_id = id + 1
  self.shortcuts.push(ShortcutBinding::{ id, shortcut: sc, call: handler, })
  id
}

///|
pub fn[B] App::unregister_shortcut(self : App[B], id : Int) -> Bool {
  let kept : Array[ShortcutBinding] = []
  for b in self.shortcuts {
    if b.id != id {
      kept.push(b)
    }
  }
  let removed = kept.length() != self.shortcuts.length()
  self.shortcuts = kept
  removed
}

///|
fn[B] App::has_shortcut(self : App[B], id : Int) -> Bool {
  let mut found = false
  for b in self.shortcuts {
    if b.id == id {
      found = true
    }
  }
  found
}

///|
pub fn[B] App::shortcut_count(self : App[B]) -> Int {
  self.shortcuts.length()
}

///|
/// 一次按键命中的所有组合，返回触发的回调个数。
/// 顺序固定：先菜单项（走 `MenuBar::click`，因此勾选状态和点菜单一致），
/// 后独立注册的组合。回调里再改注册表不影响本轮——先取快照再遍历。
pub fn[B] App::fire_shortcut(self : App[B], kp : KeyPress) -> Int raise UiError {
  let accel = self.menu_accel
  let bindings = self.shortcuts
  let mut hits = 0
  for a in accel {
    if a.shortcut.matches(kp) {
      match self.click_menu_item(a.item.id) {
        Some(_) => hits = hits + 1
        None => ()
      }
    }
  }
  for b in bindings {
    if b.shortcut.matches(kp) && self.has_shortcut(b.id) {
      (b.call)(b.shortcut)
      hits = hits + 1
    }
  }
  hits
}

///|
test "菜单栏装到后端，MenuSelect 经事件循环驱动菜单项（§25）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let sidebar = MenuItem::checkbox("Sidebar")
  let quit = MenuItem::new("Quit")
  quit.set_shortcut(Shortcut::ctrl("q"))
  let mut quits = 0
  let _ = quit.on(_ => {
    quits = quits + 1
    app.quit()
  })
  let bar = MenuBar::new([
    Menu::new("View", [Item(sidebar), Separator, Item(quit)]),
  ])
  app.set_menubar(bar)
  assert_eq(b.menu_install_count(), 1)
  match b.installed_menu_bar() {
    Some(installed) => {
      assert_eq(installed.top_labels(), ["View"])
      assert_eq(installed.all_items().length(), 2)
    }
    None => assert_false(true)
  }
  // 只有带组合的启用项进入快捷键表
  assert_eq(app.menu_accel_count(), 1)

  b.push_menu_select(sidebar.id)
  b.push_menu_select(quit.id)
  b.push_menu_select(999)
  app.run()
  assert_true(app.is_finished())
  assert_true(sidebar.is_checked())
  assert_eq(quits, 1)
}

///|
test "未安装菜单栏时 MenuSelect 无副作用" {
  let app = App::new(MockBackend::new())
  assert_eq(app.dispatch(MenuSelect(EventTarget::{ id: 0, })), 0)
  assert_true(app.click_menu_item(0) is None)
  assert_true(app.menubar() is None)
}

///|
test "§26：快捷键命中菜单项与独立注册，注销后不再响应" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let save = MenuItem::new("Save")
  save.set_shortcut(Shortcut::ctrl("s"))
  let mut saves = 0
  let _ = save.on(_ => saves = saves + 1)
  app.set_menubar(MenuBar::new([Menu::new("File", [Item(save)])]))
  let mut palettes = 0
  let sub_id = app.register_shortcut(Shortcut::ctrl("p"), _ => {
    palettes = palettes + 1
  })
  assert_eq(app.shortcut_count(), 1)

  // 快捷键按组合匹配，与事件 target 无关
  let nowhere = EventTarget::{ id: 42, }
  assert_eq(app.dispatch(KeyDown(nowhere, Shortcut::ctrl("s").key_press())), 1)
  assert_eq(saves, 1)
  // 少一个 Ctrl 就是另一个组合
  let _ = app.dispatch(
    KeyDown(nowhere, KeyPress::{
      key: "s",
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    }),
  )
  assert_eq(saves, 1)

  assert_eq(app.dispatch(KeyDown(nowhere, Shortcut::ctrl("p").key_press())), 1)
  assert_eq(palettes, 1)
  assert_true(app.unregister_shortcut(sub_id))
  assert_false(app.unregister_shortcut(sub_id))
  assert_eq(app.dispatch(KeyDown(nowhere, Shortcut::ctrl("p").key_press())), 0)
  assert_eq(palettes, 1)
}

///|
test "快捷键走的是和点菜单一样的语义：Radio 组合也会互斥" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let small = MenuItem::radio("Small")
  small.set_shortcut(Shortcut::ctrl("1"))
  let large = MenuItem::radio("Large")
  large.set_shortcut(Shortcut::ctrl("2"))
  app.set_menubar(MenuBar::new([Menu::new("View", [Item(small), Item(large)])]))
  let target = EventTarget::{ id: 0, }
  let _ = app.dispatch(KeyDown(target, Shortcut::ctrl("1").key_press()))
  assert_true(small.is_checked())
  assert_false(large.is_checked())
  let _ = app.dispatch(KeyDown(target, Shortcut::ctrl("2").key_press()))
  assert_false(small.is_checked())
  assert_true(large.is_checked())
}
