///|
/// `TreeView`——可折叠的树（`T102` 的第二刀）。
///
/// 与 `DataGrid` 同一条路子：不包 `NSOutlineView` / Win32 `TreeView`，而是把
/// "缩进 + 箭头 + 一行字"自己画在 `T101` 的自绘面上。理由是同一件事——两边的
/// 原生树视图都要数据源 / delegate / 回收 那一整套，而一棵**已经扁平化**的树
/// 在屏幕上就是"每行前面缩进多少、有没有箭头、写什么字"，三样都是纯算术。
///
/// **这一刀的核心是"扁平化"**：树是嵌套的，绘制与命中都只认一维的行号，所以
/// 内部维护一份"当前可见行"的缓存（`state.rows`），只在换数据 / 展开 / 收起时
/// 重算一次。绘制只走窗口内那几行，于是"一万个节点的树滚到底"与"二十个节点"
/// 发出的命令数一样多——与 `DataGrid` 的虚拟化是同一条算术（`floor(偏移 / 行高)`
/// 定窗口起点），只是这里多记了一列 `depth` 与两个布尔。
///
/// 坐标一律控件局部逻辑像素（`T101` 的契约），逻辑→物理换算归后端。
///
/// 还没有的东西（不假装有）：拖放、多选、行内改名、横向滚动、按需懒加载子节点
/// （`children` 是一次性给全的）；展开状态按 `id` 记，所以 `id` 必须唯一。

///|
/// 一个树节点：`id`（唯一，展开状态按它记）、`label`（行文案）、`detail`
/// （右侧副文案，可空）、`children`（子节点）。
///
/// 值语义的不可变结构：要改树就整棵换（`set_root`）。这与 `DataGrid::set_rows`
/// 同一条姿势——控件不替调用方维护增量 diff，也就不会出现"我改了一半，控件记的
/// 是另一半"。
pub struct TreeNode {
  id : Int32
  label : String
  detail : String
  children : Array[TreeNode]
}

///|
/// 造一个节点。`children` 直接收下（数组是引用语义，调用方之后别再动它）。
pub fn TreeNode::new(
  id : Int32,
  label : String,
  children~ : Array[TreeNode] = [],
  detail~ : String = "",
) -> TreeNode {
  { id, label, detail, children, }
}

///|
/// 节点 id。
pub fn TreeNode::id(self : TreeNode) -> Int32 {
  self.id
}

///|
/// 行文案。
pub fn TreeNode::label(self : TreeNode) -> String {
  self.label
}

///|
/// 右侧副文案（空串 = 没有）。
pub fn TreeNode::detail(self : TreeNode) -> String {
  self.detail
}

///|
/// 子节点数。
pub fn TreeNode::child_count(self : TreeNode) -> Int32 {
  self.children.length()
}

///|
/// 是不是叶子（没有子节点）。叶子不画箭头，也不响应"点箭头"。
pub fn TreeNode::is_leaf(self : TreeNode) -> Bool {
  self.children.length() == 0
}

///|
/// 扁平化之后的一行。`depth` 只用于缩进与参考线；`leaf` / `expanded` 只用于
/// 画箭头——三者都是扁平化那一刻算好的，绘制时不再回树里找。
priv struct TreeRow {
  id : Int32
  label : String
  detail : String
  depth : Int32
  expanded : Bool
  leaf : Bool
}

///|
/// 树的可变账（与 `GridState` / `RingState` 同一条：绘制回调捕获状态，控件只是
/// 宿主与重画入口）。
struct TreeState {
  mut root : TreeNode
  show_root : Bool
  mut expanded : Array[Int32]
  /// 当前可见行的扁平缓存——换数据 / 展开 / 收起时重算（`tree_rebuild`）
  mut rows : Array[TreeRow]
  mut offset : Double
  /// 选中节点的 id，`-1` = 没有选中
  mut selected : Int32
  row_height : Double
  font_size : Double
  indent : Double
  pad : Double
  guides : Bool
  bg : Int32
  selected_bg : Int32
  text_color : Int32
  detail_color : Int32
  glyph_color : Int32
  guide_color : Int32
  empty_text : String
}

///|
/// 可折叠的树。`new` 之后用 `widget()` 进布局，`set_root` 换树、`expand` /
/// `collapse` / `toggle` 推展开状态、`set_offset` / `scroll_to_row` 推滚动、
/// `select_id` 推选中（都自动重画）。
pub struct TreeView[B] {
  widget : @moonui.Widget[B]
  state : TreeState
  size : @moonui.LogicalSize
}

///|
/// 造一棵树。
///
/// 参数口径：
/// - `show_root=false`（默认）时根只是"容器"，它的子节点从 `depth = 0` 开始排
///   ——多数场景的根是虚构的，占一行反而多余；要显示就传 `true`；
/// - `expanded` 是**初始**展开的 id 列表，之后由 `expand` / `collapse` 改；
/// - `indent` 是每层缩进，也是箭头的命中盒宽度（点箭头那一格才折叠，点整行是
///   选中——两件事分开，省得"想选却折了"）；
/// - `detail` 右对齐、最多占标签区 45% 宽（超了就省略），标签按剩下的宽度裁；
/// - `guides` 管缩进参考线：按**窗口内**最大深度铺几条竖线，不做逐行 "├─" 的
///   那套（那要每行记住"祖先还有没有兄弟"，收益只是几个像素的美观）；
/// - `empty_text` 只在可见行为零时出现在正中（整棵树都没展开时也算空）。
///
/// 颜色是 0xRRGGBB，**没有从 `Theme` 取色**：与 `ProgressRing` / `DataGrid` 同
/// 一条理由——`Theme` 挂在 `App` 上，控件拿不到。
pub fn[B : @moonui.Backend] TreeView::new(
  backend : B,
  root : TreeNode,
  width~ : Double = 240.0,
  height~ : Double = 300.0,
  row_height~ : Double = 22.0,
  font_size~ : Double = 12.0,
  indent~ : Double = 14.0,
  pad~ : Double = 8.0,
  show_root~ : Bool = false,
  expanded~ : Array[Int32] = [],
  guides~ : Bool = true,
  bg~ : Int32 = 0xFFFFFF,
  selected_bg~ : Int32 = 0xEBF4FF,
  text_color~ : Int32 = 0x1A202C,
  detail_color~ : Int32 = 0x718096,
  glyph_color~ : Int32 = 0x718096,
  guide_color~ : Int32 = 0xE2E8F0,
  empty_text~ : String = "",
) -> TreeView[B] raise @moonui.UiError {
  if row_height <= 0.0 {
    raise @moonui.OperationFailed("树的行高必须为正")
  }
  if font_size <= 0.0 {
    raise @moonui.OperationFailed("树的字号必须为正")
  }
  if indent <= 0.0 {
    raise @moonui.OperationFailed("树的缩进必须为正")
  }
  let w = if width > 0.0 { width } else { 0.0 }
  let h = if height > 0.0 { height } else { 0.0 }
  let state = TreeState::{
    root,
    show_root,
    expanded,
    rows: [],
    offset: 0.0,
    selected: -1,
    row_height,
    font_size,
    indent,
    pad: if pad > 0.0 {
      pad
    } else {
      0.0
    },
    guides,
    bg,
    selected_bg,
    text_color,
    detail_color,
    glyph_color,
    guide_color,
    empty_text,
  }
  tree_rebuild(state)
  let widget = @moonui.Widget::custom(backend, @moonui.LogicalSize(w, h), fn(
    dl,
    env,
  ) {
    paint_tree(state, dl, env)
  })
  { widget, state, size: @moonui.LogicalSize(w, h), }
}

///|
/// 展开集里有没有这个 id。
fn tree_has(ids : Array[Int32], id : Int32) -> Bool {
  for v in ids {
    if v == id {
      return true
    }
  }
  false
}

///|
/// 把一棵子树压成行（递归）：先压自己，展开了才往下走。
///
/// 递归深度 = 树深，与行数无关——拷贝一份树的形状不会在这里发生。
fn tree_flatten_row(
  state : TreeState,
  node : TreeNode,
  depth : Int32,
  out : Array[TreeRow],
) -> Unit {
  let leaf = node.children.length() == 0
  let open = if leaf { false } else { tree_has(state.expanded, node.id) }
  out.push(TreeRow::{
    id: node.id,
    label: node.label,
    detail: node.detail,
    depth,
    expanded: open,
    leaf,
  })
  if open {
    for child in node.children {
      tree_flatten_row(state, child, depth + 1, out)
    }
  }
}

///|
/// 重算可见行。换数据、展开、收起之后必须调——绘制与命中都只读这份缓存。
fn tree_rebuild(state : TreeState) -> Unit {
  let out : Array[TreeRow] = []
  if state.show_root {
    tree_flatten_row(state, state.root, 0, out)
  } else {
    // 根只是容器：它的展开状态不参与判断，子节点一律从 depth 0 开始
    for child in state.root.children {
      tree_flatten_row(state, child, 0, out)
    }
  }
  state.rows = out
}

///|
/// 偏移上限：最后一行贴住底边就到头，再滚就是空屏。
fn tree_max_offset(rows : Int32, row_height : Double, body : Double) -> Double {
  let max = rows.to_double() * row_height - body
  if max > 0.0 {
    max
  } else {
    0.0
  }
}

///|
/// 把偏移夹到 `[0, 上限]`。读的地方也夹一次——`.height()` 覆盖过实际高度之后，
/// 用声明高度算出来的上限就不准了（同 `DataGrid`）。
fn tree_clamp_offset(
  state : TreeState,
  body : Double,
  offset : Double,
) -> Double {
  let max = tree_max_offset(state.rows.length(), state.row_height, body)
  let off = if offset > max { max } else { offset }
  if off < 0.0 {
    0.0
  } else {
    off
  }
}

///|
/// 当前偏移夹过之后的值。
fn tree_effective_offset(state : TreeState, body : Double) -> Double {
  tree_clamp_offset(state, body, state.offset)
}

///|
/// 窗口第一行：`floor(偏移 / 行高)`。
fn tree_first_row(state : TreeState, body : Double) -> Int32 {
  let n = state.rows.length()
  if n == 0 {
    return 0
  }
  let eff = tree_effective_offset(state, body)
  let first = (eff / state.row_height).floor().to_int()
  if first < 0 {
    0
  } else if first > n - 1 {
    n - 1
  } else {
    first
  }
}

///|
/// 画一行：箭头（只有非叶子有）+ 标签 + 右对齐的副文案。
///
/// 标签与副文案都走 `draw_fitted_text`：放得下直接画，放不下才省略并夹住。副
/// 文案先量一次是为了给标签让宽度——不量的话"标签省略了但副文案压上来"会重叠。
fn paint_tree_row(
  state : TreeState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  row : TreeRow,
  y : Double,
) -> Unit {
  let w = env.width()
  let slot = state.pad + row.depth.to_double() * state.indent
  if !row.leaf {
    let glyph = if row.expanded { "▾" } else { "▸" }
    let (gw, gh) = env.measure_text(glyph, state.font_size, false)
    dl.text(
      glyph,
      slot + (state.indent - gw) / 2.0,
      y + (state.row_height - gh) / 2.0,
      size=state.font_size,
      rgb=state.glyph_color,
    )
  }
  let label_x = slot + state.indent
  let mut detail_w = 0.0
  if row.detail != "" {
    let (dw, _) = env.measure_text(row.detail, state.font_size, false)
    // 副文案最多占标签区的 45%：它只是个附注，不能把主语挤没了
    let cap = (w - label_x - state.pad) * 0.45
    detail_w = if dw < cap { dw } else if cap > 0.0 { cap } else { 0.0 }
  }
  let gap = if detail_w > 0.0 { state.pad } else { 0.0 }
  let avail = w - state.pad - detail_w - gap - label_x
  draw_fitted_text(
    dl,
    env,
    row.label,
    label_x,
    avail,
    y,
    state.row_height,
    state.font_size,
    false,
    state.text_color,
    false,
  )
  if detail_w > 0.0 {
    draw_fitted_text(
      dl,
      env,
      row.detail,
      w - state.pad - detail_w,
      detail_w,
      y,
      state.row_height,
      state.font_size,
      false,
      state.detail_color,
      true,
    )
  }
}

///|
/// 把整棵树画进这份清单。纯函数：不读后端、不 raise，度量全走 `PaintEnv`。
///
/// 命令顺序：底 → 选中行底色 → 缩进参考线 → 行内容。参考线必须夹在"底色之后、
/// 文字之前"——画在底色之前会被选中的那一行整条盖掉（`DataGrid` 的竖分列线趟过
/// 同一个坑，那边是靠"最后画"解决的，这里不能照抄：线压在文字上会割穿字）。
fn paint_tree(
  state : TreeState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  dl.fill_rect(0.0, 0.0, w, h, rgb=state.bg)
  let n = state.rows.length()
  if n == 0 {
    if state.empty_text != "" {
      let (tw, th) = env.measure_text(state.empty_text, state.font_size, false)
      dl.text(
        state.empty_text,
        (w - tw) / 2.0,
        (h - th) / 2.0,
        size=state.font_size,
        rgb=state.text_color,
      )
    }
    return
  }
  let eff = tree_effective_offset(state, h)
  let first = tree_first_row(state, h)
  // 窗口末行：顶边还没落到底边以下的都算（半行要画——它的上半截是可见的）
  let mut last = first
  while last < n && last.to_double() * state.row_height - eff < h {
    last = last + 1
  }
  let mut i = first
  while i < last {
    let row = state.rows[i]
    if row.id == state.selected {
      dl.fill_rect(
        0.0,
        i.to_double() * state.row_height - eff,
        w,
        state.row_height,
        rgb=state.selected_bg,
      )
    }
    i = i + 1
  }
  if state.guides {
    // 参考线按窗口内的最大深度铺：只按全表最大深度铺的话，滚到只有浅层节点的
    // 那一段会看到几条空荡荡的竖线穿到底
    let mut maxd = 0
    let mut k = first
    while k < last {
      if state.rows[k].depth > maxd {
        maxd = state.rows[k].depth
      }
      k = k + 1
    }
    let mut lvl = 0
    while lvl < maxd {
      let x = state.pad + lvl.to_double() * state.indent + state.indent / 2.0
      dl.line(x, 0.0, x, h, width=1.0, rgb=state.guide_color)
      lvl = lvl + 1
    }
  }
  let mut i = first
  while i < last {
    paint_tree_row(
      state,
      dl,
      env,
      state.rows[i],
      i.to_double() * state.row_height - eff,
    )
    i = i + 1
  }
}

///|
/// 拿控件进布局。
pub fn[B] TreeView::widget(self : TreeView[B]) -> @moonui.Widget[B] {
  self.widget
}

///|
/// 声明尺寸。
pub fn[B] TreeView::size(self : TreeView[B]) -> @moonui.LogicalSize {
  self.size
}

///|
/// 当前可见行数（= 展开之后看得见的节点数）。
pub fn[B] TreeView::visible_count(self : TreeView[B]) -> Int32 {
  self.state.rows.length()
}

///|
/// 第 `row` 个可见行的节点 id；越界给 `None`。
pub fn[B] TreeView::visible_id(self : TreeView[B], row : Int32) -> Int32? {
  if row < 0 || row >= self.state.rows.length() {
    return None
  }
  Some(self.state.rows[row].id)
}

///|
/// 第 `row` 个可见行的缩进层级；越界给 `None`。
pub fn[B] TreeView::visible_depth(self : TreeView[B], row : Int32) -> Int32? {
  if row < 0 || row >= self.state.rows.length() {
    return None
  }
  Some(self.state.rows[row].depth)
}

///|
/// 某个 id 当前在第几行；被折叠在看不见的地方（或不存在）给 `None`。
pub fn[B] TreeView::row_of(self : TreeView[B], id : Int32) -> Int32? {
  let mut i = 0
  while i < self.state.rows.length() {
    if self.state.rows[i].id == id {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// 当前滚动偏移（逻辑像素）。
pub fn[B] TreeView::offset(self : TreeView[B]) -> Double {
  self.state.offset
}

///|
/// 当前行高（逻辑像素）。
pub fn[B] TreeView::row_height(self : TreeView[B]) -> Double {
  self.state.row_height
}

///|
/// 选中节点的 id，`-1` = 没有选中。
pub fn[B] TreeView::selected_id(self : TreeView[B]) -> Int32 {
  self.state.selected
}

///|
/// 这个 id 是不是展开的（叶子恒为 `false`）。
pub fn[B] TreeView::is_expanded(self : TreeView[B], id : Int32) -> Bool {
  tree_has(self.state.expanded, id)
}

///|
/// 当前展开集的**拷贝**。不把内部数组递出去：数组是引用语义，递出去等于把
/// "改完要 repaint"的账交给调用方去猜（与 `Sparkline::series` 同一条）。
pub fn[B] TreeView::expanded_ids(self : TreeView[B]) -> Array[Int32] {
  let out : Array[Int32] = []
  for v in self.state.expanded {
    out.push(v)
  }
  out
}

///|
/// 把控件局部坐标里的 y 换算成可见行号；空白处、越界给 `None`。
///
/// 与 `DataGrid::row_at` 同一条理由：事件坐标是窗口/父局部的（`T108` 的滚轮还
/// 恒报窗口自己），"第几行"只有控件自己知道（行高 + 当前偏移）。调用方把
/// `y - frame.origin.y` 递进来即可；`height` 传了就用它，不传按声明高度算。
pub fn[B] TreeView::row_at(
  self : TreeView[B],
  y : Double,
  height~ : Double = -1.0,
) -> Int32? {
  let surface = if height > 0.0 { height } else { self.size.height }
  if surface <= 0.0 {
    return None
  }
  let eff = tree_effective_offset(self.state, surface)
  let rel = y + eff
  if rel < 0.0 {
    return None
  }
  let row = (rel / self.state.row_height).floor().to_int()
  if row < 0 || row >= self.state.rows.length() {
    None
  } else {
    Some(row)
  }
}

///|
/// 点一下 `(x, y)`：只有落在**箭头那一格**（第 `depth` 层的缩进槽）里才折叠/
/// 展开，返回被动过的节点 id；点在别处、点在叶子上、点在空白上都给 `None`。
///
/// 为什么命中盒只有箭头槽：整行可折叠的话，"想选中却折了"会成为最常见的手误；
/// 选中交给 `row_at` + `select_id`，各管各的。
pub fn[B : @moonui.Backend] TreeView::toggle_at(
  self : TreeView[B],
  x : Double,
  y : Double,
  height~ : Double = -1.0,
) -> Int32? raise @moonui.UiError {
  let row = match self.row_at(y, height~) {
    Some(r) => r
    None => return None
  }
  let r = self.state.rows[row]
  if r.leaf {
    return None
  }
  let slot = self.state.pad + r.depth.to_double() * self.state.indent
  if x < slot || x > slot + self.state.indent {
    return None
  }
  TreeView::toggle(self, r.id)
  Some(r.id)
}

///|
/// 整棵换树并重画。
///
/// 展开集**不清空**：同一个 id 在新树里往往还是同一个目录（刷新一行数据的场景
/// 最常见），清掉的话每次刷新整棵树都缩回去。id 不存在了也无害——`tree_has` 只
/// 在扁平化走到有子节点的节点时才问。
pub fn[B : @moonui.Backend] TreeView::set_root(
  self : TreeView[B],
  root : TreeNode,
) -> Unit raise @moonui.UiError {
  self.state.root = root
  tree_rebuild(self.state)
  let body = self.size.height
  self.state.offset = tree_effective_offset(self.state, body)
  self.widget.repaint()
}

///|
/// 展开一个节点并重画（已经是展开的就只重画，不重复记 id）。
pub fn[B : @moonui.Backend] TreeView::expand(
  self : TreeView[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  if !tree_has(self.state.expanded, id) {
    self.state.expanded.push(id)
    tree_rebuild(self.state)
    self.widget.repaint()
  }
}

///|
/// 收起一个节点并重画（本来就收着的什么都不做，连重画都省掉）。
pub fn[B : @moonui.Backend] TreeView::collapse(
  self : TreeView[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  if tree_has(self.state.expanded, id) {
    let kept : Array[Int32] = []
    for v in self.state.expanded {
      if v != id {
        kept.push(v)
      }
    }
    self.state.expanded = kept
    tree_rebuild(self.state)
    self.widget.repaint()
  }
}

///|
/// 展开/收起一个节点并重画。
pub fn[B : @moonui.Backend] TreeView::toggle(
  self : TreeView[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  if tree_has(self.state.expanded, id) {
    TreeView::collapse(self, id)
  } else {
    TreeView::expand(self, id)
  }
}

///|
/// 收集"有子节点"的 id（`expand_all` 用）。
fn tree_collect_ids(node : TreeNode, out : Array[Int32]) -> Unit {
  if node.children.length() > 0 {
    out.push(node.id)
    for child in node.children {
      tree_collect_ids(child, out)
    }
  }
}

///|
/// 全部展开并重画。
///
/// 警告：行数是"整棵树的节点数"，一万个节点就是一万行缓存——真要这样用，说明
/// 该上按需加载（本控件还没有）。
pub fn[B : @moonui.Backend] TreeView::expand_all(
  self : TreeView[B],
) -> Unit raise @moonui.UiError {
  let ids : Array[Int32] = []
  tree_collect_ids(self.state.root, ids)
  self.state.expanded = ids
  tree_rebuild(self.state)
  self.widget.repaint()
}

///|
/// 全部收起并重画（只剩 `show_root` 决定的根那一层）。
pub fn[B : @moonui.Backend] TreeView::collapse_all(
  self : TreeView[B],
) -> Unit raise @moonui.UiError {
  self.state.expanded = []
  tree_rebuild(self.state)
  self.widget.repaint()
}

///|
/// 整份替换展开集并重画（`expanded_ids()` 的逆操作，用于"记住上次展开状态"）。
pub fn[B : @moonui.Backend] TreeView::set_expanded(
  self : TreeView[B],
  ids : Array[Int32],
) -> Unit raise @moonui.UiError {
  self.state.expanded = ids
  tree_rebuild(self.state)
  self.widget.repaint()
}

///|
/// 选中一个节点并重画；`-1` 或任何看不见的 id 表示**清掉选中**。
///
/// 与 `DataGrid::select_row` 的差别：这里收的是 id 而不是行号——行号会随着
/// 展开/收起变，按 id 记才不会被"折了一下父节点"搞成高亮错行。
pub fn[B : @moonui.Backend] TreeView::select_id(
  self : TreeView[B],
  id : Int32,
) -> Unit raise @moonui.UiError {
  self.state.selected = id
  self.widget.repaint()
}

///|
/// 推一个滚动偏移并重画（负值归零、越过尾部夹到最后一行贴底）。
pub fn[B : @moonui.Backend] TreeView::set_offset(
  self : TreeView[B],
  offset : Double,
) -> Unit raise @moonui.UiError {
  let body = self.size.height
  self.state.offset = tree_clamp_offset(self.state, body, offset)
  self.widget.repaint()
}

///|
/// 滚到第 `row` 行（对齐顶边）并重画。越界按 `set_offset` 的规则夹住。
pub fn[B : @moonui.Backend] TreeView::scroll_to_row(
  self : TreeView[B],
  row : Int32,
) -> Unit raise @moonui.UiError {
  let r = if row < 0 { 0 } else { row }
  TreeView::set_offset(self, r.to_double() * self.state.row_height)
}
