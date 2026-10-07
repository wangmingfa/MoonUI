///|
/// 布局引擎（设计文档 §14）。
///
/// 第一阶段不照搬 libui-ng 的 Box/Grid API，而是自己定义"测量 + 摆放"两步：
/// `measure` 在给定约束下求固有尺寸，`layout` 把叶子矩写出来。两步分离，
/// 才可能在 §17 让 CustomWidget 复用同一套布局语义（自绘时只需读矩形）。

///|
/// 主轴方向。横向即 Row，纵向即 Column。
pub(all) enum Axis {
  Horizontal
  Vertical
} derive(Debug, Eq)

///|
pub(all) struct BoxConstraints {
  min : LogicalSize
  max : LogicalSize
} derive(Debug, Eq)

///|
pub fn BoxConstraints::loose(width : Double, height : Double) -> BoxConstraints {
  BoxConstraints::{
    min: LogicalSize::zero(),
    max: LogicalSize::{ width, height, },
  }
}

///|
pub fn BoxConstraints::tight(width : Double, height : Double) -> BoxConstraints {
  BoxConstraints::{
    min: LogicalSize::{ width, height, },
    max: LogicalSize::{ width, height, },
  }
}

///|
/// 布局树里用的"无限"上限。用有限大数而不是 Double.infinity，是为了让
/// Backend 拿到的约束在任何平台都是可比较、可序列化的普通浮点。
const Infinity : Double = 1000000000000000000.0

///|
fn inf_size() -> LogicalSize {
  LogicalSize::{ width: Infinity, height: Infinity, }
}

///|
pub fn BoxConstraints::unbounded() -> BoxConstraints {
  BoxConstraints::{ min: LogicalSize::zero(), max: inf_size(), }
}

///|
pub fn BoxConstraints::constrain(
  self : BoxConstraints,
  size : LogicalSize,
) -> LogicalSize {
  size.clamp(self.min, self.max)
}

///|
/// 叶子控件：固有尺寸 + 是否可沿主轴伸展（`expand`）。
pub(all) struct LeafSpec {
  id : Int
  intrinsic : LogicalSize
  expand : Bool
} derive(Debug, Eq)

///|
/// 线性容器。`spacing` 只加在相邻子项之间，`children` 为空时不产生间距。
pub(all) struct LineSpec {
  axis : Axis
  spacing : Double
  children : Array[LayoutSpec]
} derive(Debug, Eq)

///|
pub(all) struct PaddingSpec {
  insets : EdgeInsets
  child : LayoutSpec
} derive(Debug, Eq)

///|
pub(all) struct CenterSpec {
  child : LayoutSpec
} derive(Debug, Eq)

///|
/// 叠放容器（§14 的 Stack）：子项共用同一个原点，数组靠后的画在上层。
pub(all) struct StackSpec {
  children : Array[LayoutSpec]
} derive(Debug, Eq)

///|
/// 均匀网格（§14 的 Grid）：行优先流动，`columns` 至少 1（更小按 1 处理）。
pub(all) struct GridSpec {
  columns : Int
  spacing : Double
  children : Array[LayoutSpec]
} derive(Debug, Eq)

///|
/// 滚动视口（§14 的 Scroll）。`axis` 是滚动方向，也就是"允许溢出"的那根轴。
pub(all) struct ScrollSpec {
  axis : Axis
  child : LayoutSpec
} derive(Debug, Eq)

///|
/// 布局树。`Spacer` 在弹性分配里表示"吃掉剩余空间"，
/// `Unbounded` 用于滚动容器给子项无限主轴约束。
pub(all) enum LayoutSpec {
  Leaf(LeafSpec)
  Row(LineSpec)
  Column(LineSpec)
  Padding(PaddingSpec)
  Spacer
  Center(CenterSpec)
  Stack(StackSpec)
  Grid(GridSpec)
  Scroll(ScrollSpec)
  Unbounded(LayoutSpec)
} derive(Debug, Eq)

///|
/// 摆放结果：叶子 id 与其逻辑矩形。Backend/自绘只需消费这张表。
pub(all) struct Placed {
  id : Int
  frame : LogicalRect
} derive(Debug, Eq)

///|
/// 测量固有尺寸。约束决定"最多能给多少"，`min` 决定"至少要多大"。
pub fn measure(spec : LayoutSpec, c : BoxConstraints) -> LogicalSize {
  match spec {
    Leaf(leaf) =>
      if leaf.expand {
        c.max
      } else {
        c.constrain(leaf.intrinsic.non_negative())
      }
    Row(line) | Column(line) => measure_line(line, c)
    Padding(pad) => {
      let inner = measure(pad.child, shrink(c, pad.insets))
      c.constrain(LogicalSize::{
        width: inner.width + pad.insets.horizontal(),
        height: inner.height + pad.insets.vertical(),
      })
    }
    Spacer => c.constrain(LogicalSize::zero())
    Center(inner) => measure(inner.child, BoxConstraints::unbounded())
    Stack(stack) => measure_stack(stack, c)
    Grid(grid) => measure_grid(grid, c)
    // 视口不需要为内容让出主轴：内容沿滚动轴可以无限长，交叉轴才受约束
    Scroll(scroll) => measure_scroll(scroll, c)
    Unbounded(child) => measure(child, BoxConstraints::unbounded())
  }
}

///|
/// 摆放：把整棵树的叶子矩形写入 `out`，顺序为先序（与绘制顺序一致）。
pub fn layout(
  spec : LayoutSpec,
  frame : LogicalRect,
  out : Array[Placed],
) -> Unit {
  let f = normalized_frame(frame)
  match spec {
    Leaf(leaf) => out.push(Placed::{ id: leaf.id, frame: f, })
    Row(line) | Column(line) => layout_line(line, f, out)
    Padding(pad) =>
      layout(
        pad.child,
        f.inset(
          pad.insets.top,
          pad.insets.end,
          pad.insets.bottom,
          pad.insets.start,
        ),
        out,
      )
    Spacer => ()
    Center(inner) => {
      let size = measure(inner.child, BoxConstraints::unbounded())
      layout(inner.child, f.center(size), out)
    }
    Stack(stack) => layout_stack(stack, f, out)
    Grid(grid) => layout_grid(grid, f, out)
    Scroll(scroll) => layout_scroll(scroll, f, out)
    Unbounded(child) => layout(child, f, out)
  }
}

///|
/// `shrink` 只收紧上限：内缩后的空间仍允许子项变小，否则 Padding 会把
/// 子项强行撑成容器尺寸。
fn shrink(c : BoxConstraints, insets : EdgeInsets) -> BoxConstraints {
  let w = c.max.width - insets.horizontal()
  let h = c.max.height - insets.vertical()
  BoxConstraints::{
    min: LogicalSize::zero(),
    max: LogicalSize::{
      width: if w < 0.0 {
        0.0
      } else {
        w
      },
      height: if h < 0.0 {
        0.0
      } else {
        h
      },
    },
  }
}

///|
fn main_of(axis : Axis, size : LogicalSize) -> Double {
  match axis {
    Horizontal => size.width
    Vertical => size.height
  }
}

///|
fn cross_of(axis : Axis, size : LogicalSize) -> Double {
  match axis {
    Horizontal => size.height
    Vertical => size.width
  }
}

///|
fn main_max(axis : Axis, c : BoxConstraints) -> Double {
  main_of(axis, c.max)
}

///|
fn measure_line(line : LineSpec, c : BoxConstraints) -> LogicalSize {
  let axis = line.axis
  let children = line.children
  let n = children.length()
  if n == 0 {
    return c.constrain(LogicalSize::zero())
  }
  let gap = if line.spacing < 0.0 { 0.0 } else { line.spacing }
  // 子项在主轴上不受限（由容器负责分配），交叉轴受容器上限约束
  let child_c = BoxConstraints::unbounded()
  let mut main_total = 0.0
  let mut cross_max = 0.0
  for child in children {
    let s = measure(child, child_c)
    main_total = main_total + main_of(axis, s)
    let cr = cross_of(axis, s)
    if cr > cross_max {
      cross_max = cr
    }
  }
  main_total = main_total + gap * (n - 1).to_double()
  let limit = main_max(axis, c)
  // expand 的叶子或 Spacer 会把主轴撑到容器上限
  if count_expand(children) > 0 {
    main_total = limit
  }
  let main = if main_total > limit { limit } else { main_total }
  c.constrain(make_size(axis, main, cross_max))
}

///|
fn count_expand(children : Array[LayoutSpec]) -> Int {
  let mut n = 0
  for child in children {
    match child {
      Leaf(leaf) => if leaf.expand { n = n + 1 }
      Spacer => n = n + 1
      _ => ()
    }
  }
  n
}

///|
fn make_size(axis : Axis, main : Double, cross : Double) -> LogicalSize {
  match axis {
    Horizontal => LogicalSize::{ width: main, height: cross, }
    Vertical => LogicalSize::{ width: cross, height: main, }
  }
}

///|
fn normalized_frame(frame : LogicalRect) -> LogicalRect {
  frame.normalized()
}

///|
/// 线性分配：固定项按固有尺寸，`Spacer`/`expand` 项均分剩余主轴空间。
/// 空间不足时弹性项得 0，固定项保持固有尺寸（宁可溢出也不压缩固定内容）。
fn layout_line(
  line : LineSpec,
  frame : LogicalRect,
  out : Array[Placed],
) -> Unit {
  let axis = line.axis
  let children = line.children
  let n = children.length()
  if n == 0 {
    return
  }
  let gap = if line.spacing < 0.0 { 0.0 } else { line.spacing }
  let cross_avail = cross_of(axis, frame.size)
  let child_c = BoxConstraints::unbounded()
  let sizes = children.map(child => measure(child, child_c))
  let mut fixed_total = 0.0
  let mut flex_count = 0
  for i = 0; i < n; i = i + 1 {
    match children[i] {
      Spacer => flex_count = flex_count + 1
      Leaf(leaf) =>
        if leaf.expand {
          flex_count = flex_count + 1
        } else {
          fixed_total = fixed_total + main_of(axis, sizes[i])
        }
      _ => fixed_total = fixed_total + main_of(axis, sizes[i])
    }
  }
  let gap_total = if n > 1 { gap * (n - 1).to_double() } else { 0.0 }
  let spare = main_of(axis, frame.size) - gap_total - fixed_total
  let remaining = if spare > 0.0 { spare } else { 0.0 }
  let flex_each = if flex_count > 0 {
    remaining / flex_count.to_double()
  } else {
    0.0
  }

  let mut cursor = match axis {
    // 主轴起点：Row 看 x，Column 看 y。写死成 x 会让 Column 在
    // 非零原点的框架里整体横移，而纵向完全不推进。
    Horizontal => frame.origin.x
    Vertical => frame.origin.y
  }
  for i = 0; i < n; i = i + 1 {
    let child = children[i]
    let flex = match child {
      Spacer => true
      Leaf(leaf) => leaf.expand
      _ => false
    }
    let main = if flex { flex_each } else { main_of(axis, sizes[i]) }
    // 弹性项铺满交叉轴（Row 里的 Spacer 要有高度可占），固定项保持固有尺寸
    let cross = if flex { cross_avail } else { cross_of(axis, sizes[i]) }
    let origin = match axis {
      Horizontal => LogicalPoint::{ x: cursor, y: frame.origin.y, }
      Vertical => LogicalPoint::{ x: frame.origin.x, y: cursor, }
    }
    match child {
      Spacer => ()
      _ =>
        layout(
          child,
          LogicalRect::{ origin, size: make_size(axis, main, cross), },
          out,
        )
    }
    cursor = cursor + main + (if i < n - 1 { gap } else { 0.0 })
  }
}

///|
/// Stack：子项共用同一个原点，数组靠后的画在上层（后画覆盖先画）。
/// 每个子项按传入约束测量，因此 `expand` 子项会撑到上限——这正是叠放里
/// "铺满一层"的写法。Core 没有 z-order 参数，顺序就是数组顺序。
fn measure_stack(stack : StackSpec, c : BoxConstraints) -> LogicalSize {
  let mut w = 0.0
  let mut h = 0.0
  for child in stack.children {
    let s = measure(child, c)
    if s.width > w {
      w = s.width
    }
    if s.height > h {
      h = s.height
    }
  }
  c.constrain(LogicalSize::{ width: w, height: h, })
}

///|
fn layout_stack(
  stack : StackSpec,
  frame : LogicalRect,
  out : Array[Placed],
) -> Unit {
  let c = BoxConstraints::loose(frame.size.width, frame.size.height)
  for child in stack.children {
    let s = measure(child, c)
    layout(child, LogicalRect::{ origin: frame.origin, size: s, }, out)
  }
}

///|
fn grid_columns(columns : Int) -> Int {
  if columns < 1 {
    1
  } else {
    columns
  }
}

///|
/// 行优先流动：最后一行不满也算一行。
fn grid_rows(count : Int, columns : Int) -> Int {
  if count == 0 {
    0
  } else {
    (count + columns - 1) / columns
  }
}

///|
fn grid_gap(spacing : Double) -> Double {
  if spacing < 0.0 {
    0.0
  } else {
    spacing
  }
}

///|
/// 单元格尺寸取所有子项固有尺寸的最大值——均匀网格是 Grid 的全部语义，
/// 第二阶段的跨轴拉伸（§14）不在这里预留。
fn grid_cell(grid : GridSpec, c : BoxConstraints) -> LogicalSize {
  let mut w = 0.0
  let mut h = 0.0
  for child in grid.children {
    let s = measure(child, c)
    if s.width > w {
      w = s.width
    }
    if s.height > h {
      h = s.height
    }
  }
  LogicalSize::{ width: w, height: h, }
}

///|
fn measure_grid(grid : GridSpec, c : BoxConstraints) -> LogicalSize {
  let cols = grid_columns(grid.columns)
  let rows = grid_rows(grid.children.length(), cols)
  if rows == 0 {
    return c.constrain(LogicalSize::zero())
  }
  let gap = grid_gap(grid.spacing)
  let cell = grid_cell(grid, c)
  let w = cell.width * cols.to_double() + gap * (cols - 1).to_double()
  let h = cell.height * rows.to_double() + gap * (rows - 1).to_double()
  c.constrain(LogicalSize::{ width: w, height: h, })
}

///|
fn layout_grid(
  grid : GridSpec,
  frame : LogicalRect,
  out : Array[Placed],
) -> Unit {
  let n = grid.children.length()
  if n == 0 {
    return
  }
  let cols = grid_columns(grid.columns)
  let gap = grid_gap(grid.spacing)
  let cell_c = BoxConstraints::loose(frame.size.width, frame.size.height)
  let cell = grid_cell(grid, cell_c)
  for i = 0; i < n; i = i + 1 {
    let col = i % cols
    let row = i / cols
    // 子项在自己的单元格里取固有尺寸、左上对齐，和 Row/Column 的交叉轴语义一致
    let size = measure(grid.children[i], cell_c)
    let origin = LogicalPoint::{
      x: frame.origin.x + col.to_double() * (cell.width + gap),
      y: frame.origin.y + row.to_double() * (cell.height + gap),
    }
    layout(grid.children[i], LogicalRect::{ origin, size, }, out)
  }
}

///|
/// 只放开主轴为无限：滚动容器的内容在滚动方向上不受视口限制，
/// 交叉方向仍然必须适配视口宽度/高度。
fn unbounded_main(axis : Axis, c : BoxConstraints) -> BoxConstraints {
  let inf = LogicalSize::{ width: Infinity, height: Infinity, }
  match axis {
    Horizontal =>
      BoxConstraints::{
        min: LogicalSize::zero(),
        max: LogicalSize::{ width: inf.width, height: c.max.height, },
      }
    Vertical =>
      BoxConstraints::{
        min: LogicalSize::zero(),
        max: LogicalSize::{ width: c.max.width, height: inf.height, },
      }
  }
}

///|
/// 视口自身是"弹性"的：主轴铺满可用空间，交叉轴取内容尺寸与上限的较小者。
/// 因此 Scroll 必须在一个**有界**约束下测量（窗口内容区总是有界），
/// 无限约束下的视口尺寸没有意义。
fn measure_scroll(scroll : ScrollSpec, c : BoxConstraints) -> LogicalSize {
  let content = measure(scroll.child, unbounded_main(scroll.axis, c))
  let limit = cross_of(scroll.axis, c.max)
  let cross = cross_of(scroll.axis, content)
  let each = if cross > limit { limit } else { cross }
  make_size(scroll.axis, main_of(scroll.axis, c.max), each)
}

///|
/// 内容按自身完整尺寸摆放（可以超出视口——这就是可滚动的范围），
/// 交叉轴铺满视口。Core 不做偏移：滚动位置属于后端（§20 的 uiScrollContainer、
/// §21 的 SDL3 Scroll），后端只需沿主轴平移内容矩形。
fn layout_scroll(
  scroll : ScrollSpec,
  frame : LogicalRect,
  out : Array[Placed],
) -> Unit {
  let c = BoxConstraints::loose(frame.size.width, frame.size.height)
  let content = measure(scroll.child, unbounded_main(scroll.axis, c))
  let size = make_size(
    scroll.axis,
    main_of(scroll.axis, content),
    cross_of(scroll.axis, frame.size),
  )
  layout(scroll.child, LogicalRect::{ origin: frame.origin, size, }, out)
}

///|
/// 新容器测试用的简短构造：固有尺寸叶子与矩形字面量。
fn leaf(id : Int, width : Double, height : Double) -> LayoutSpec {
  LayoutSpec::Leaf(LeafSpec::{
    id,
    intrinsic: LogicalSize::{ width, height, },
    expand: false,
  })
}

///|
fn box_at(x : Double, y : Double, w : Double, h : Double) -> LogicalRect {
  LogicalRect::{
    origin: LogicalPoint::{ x, y, },
    size: LogicalSize::{ width: w, height: h, },
  }
}

///|
test "Stack 子项同原点叠放，尺寸取两轴最大值" {
  let spec = LayoutSpec::Stack(StackSpec::{
    children: [leaf(1, 100.0, 40.0), leaf(2, 30.0, 80.0)],
  })
  assert_eq(measure(spec, BoxConstraints::loose(200.0, 200.0)), LogicalSize::{
    width: 100.0,
    height: 80.0,
  })
  let placed = []
  layout(spec, box_at(0.0, 0.0, 200.0, 200.0), placed)
  assert_eq(placed.map(p => p.id), [1, 2])
  // 叠放：原点相同，尺寸各按固有值（不拉伸）
  assert_eq(placed[0].frame.origin, LogicalPoint::{ x: 0.0, y: 0.0, })
  assert_eq(placed[1].frame.origin, LogicalPoint::{ x: 0.0, y: 0.0, })
  assert_eq(placed[1].frame.size, LogicalSize::{ width: 30.0, height: 80.0, })
}

///|
test "Grid 均匀单元格、行优先流动" {
  let cells = [leaf(1, 60.0, 20.0), leaf(2, 40.0, 30.0), leaf(3, 20.0, 10.0)]
  let spec = LayoutSpec::Grid(GridSpec::{
    columns: 2,
    spacing: 8.0,
    children: cells,
  })
  // 单元格取最大固有尺寸 60x30；2 列 2 行 => 60*2+8 = 128，30*2+8 = 68
  assert_eq(measure(spec, BoxConstraints::unbounded()), LogicalSize::{
    width: 128.0,
    height: 68.0,
  })
  let placed = []
  layout(spec, box_at(10.0, 10.0, 300.0, 200.0), placed)
  assert_eq(placed.map(p => p.id), [1, 2, 3])
  assert_eq(placed[1].frame.origin, LogicalPoint::{ x: 78.0, y: 10.0, })
  assert_eq(placed[2].frame.origin, LogicalPoint::{ x: 10.0, y: 48.0, })
  assert_eq(placed[1].frame.size, LogicalSize::{ width: 40.0, height: 30.0, })
}

///|
test "Grid 的列数与间距都夹紧到可用范围" {
  let cells = [leaf(1, 20.0, 30.0), leaf(2, 20.0, 30.0), leaf(3, 20.0, 30.0)]
  // columns<1 按 1 处理，负间距按 0 处理
  let spec = LayoutSpec::Grid(GridSpec::{
    columns: 0,
    spacing: -8.0,
    children: cells,
  })
  assert_eq(measure(spec, BoxConstraints::unbounded()), LogicalSize::{
    width: 20.0,
    height: 90.0,
  })
  let placed = []
  layout(spec, box_at(0.0, 0.0, 100.0, 300.0), placed)
  assert_eq(placed[1].frame.origin.y, 30.0)
  assert_eq(placed[2].frame.origin.y, 60.0)
  let empty = LayoutSpec::Grid(GridSpec::{
    columns: 3,
    spacing: 4.0,
    children: [],
  })
  assert_eq(measure(empty, BoxConstraints::loose(50.0, 50.0)), LogicalSize::{
    width: 0.0,
    height: 0.0,
  })
}

///|
test "Scroll 视口铺满可用空间，内容沿滚动轴溢出即可滚动范围（§14/§21）" {
  let content = LayoutSpec::Column(LineSpec::{
    axis: Vertical,
    spacing: 0.0,
    children: [leaf(1, 100.0, 40.0), leaf(2, 100.0, 40.0), leaf(3, 100.0, 40.0)],
  })
  let spec = LayoutSpec::Scroll(ScrollSpec::{ axis: Vertical, child: content, })
  // 主轴（高）铺满视口的 100，交叉轴（宽）随内容收缩
  assert_eq(measure(spec, BoxConstraints::loose(200.0, 100.0)), LogicalSize::{
    width: 100.0,
    height: 100.0,
  })
  let placed = []
  layout(spec, box_at(0.0, 0.0, 200.0, 100.0), placed)
  assert_eq(placed.length(), 3)
  assert_eq(placed[0].frame.origin.y, 0.0)
  assert_eq(placed[2].frame.origin.y, 80.0)
  // 内容完整高度 120 超出视口 100，差值就是后端滚动条的行程
  assert_eq(placed[2].frame.origin.y + placed[2].frame.size.height, 120.0)
  // 交叉轴与 Row/Column 一致：固定叶子保持固有宽度，不被拉伸
  assert_eq(placed[0].frame.size.width, 100.0)
}

///|
test "横向 Scroll 的内容宽度可以溢出视口" {
  let spec = LayoutSpec::Scroll(ScrollSpec::{
    axis: Horizontal,
    child: LayoutSpec::Row(LineSpec::{
      axis: Horizontal,
      spacing: 0.0,
      children: [leaf(4, 80.0, 20.0), leaf(5, 80.0, 20.0)],
    }),
  })
  assert_eq(measure(spec, BoxConstraints::loose(100.0, 50.0)), LogicalSize::{
    width: 100.0,
    height: 20.0,
  })
  let placed = []
  layout(spec, box_at(0.0, 0.0, 100.0, 50.0), placed)
  assert_eq(placed[1].frame.origin.x, 80.0)
  assert_eq(placed[1].frame.size.height, 20.0)
}

///|
test "空 Stack 不占空间" {
  let spec = LayoutSpec::Stack(StackSpec::{ children: [], })
  assert_eq(measure(spec, BoxConstraints::loose(64.0, 64.0)), LogicalSize::{
    width: 0.0,
    height: 0.0,
  })
  let placed = []
  layout(spec, box_at(0.0, 0.0, 64.0, 64.0), placed)
  assert_eq(placed.length(), 0)
}

///|
test "约束类型给出正确的夹紧语义" {
  let loose = BoxConstraints::loose(100.0, 50.0)
  assert_eq(loose.constrain(LogicalSize::{ width: 300.0, height: 20.0, }), LogicalSize::{
    width: 100.0,
    height: 20.0,
  })
  let tight = BoxConstraints::tight(64.0, 32.0)
  assert_eq(tight.constrain(LogicalSize::{ width: 1.0, height: 999.0, }), LogicalSize::{
    width: 64.0,
    height: 32.0,
  })
}

///|
test "Column 纵向累加高度并取交叉轴最大宽度" {
  let spec = LayoutSpec::Column(LineSpec::{
    axis: Vertical,
    spacing: 8.0,
    children: [
      LayoutSpec::Leaf(LeafSpec::{
        id: 1,
        intrinsic: LogicalSize::{ width: 120.0, height: 24.0, },
        expand: false,
      }),
      LayoutSpec::Leaf(LeafSpec::{
        id: 2,
        intrinsic: LogicalSize::{ width: 80.0, height: 32.0, },
        expand: false,
      }),
    ],
  })
  assert_eq(measure(spec, BoxConstraints::loose(400.0, 600.0)), LogicalSize::{
    width: 120.0,
    height: 64.0,
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 400.0, height: 600.0, },
    },
    placed,
  )
  assert_eq(placed.length(), 2)
  assert_eq(placed[0].frame.origin.y, 0.0)
  assert_eq(placed[1].frame.origin.y, 32.0)
  // 交叉轴不拉伸，保持各自固有宽度
  assert_eq(placed[0].frame.size.width, 120.0)
  assert_eq(placed[1].frame.size.width, 80.0)
}

///|
/// 原点非零的框架：窗口内容区一般不是 (0,0)，Column 必须从 `origin.y` 起算。
test "Column 在非零原点的框架里只纵向推进" {
  let spec = LayoutSpec::Column(LineSpec::{
    axis: Vertical,
    spacing: 8.0,
    children: [
      LayoutSpec::Leaf(LeafSpec::{
        id: 1,
        intrinsic: LogicalSize::{ width: 60.0, height: 20.0, },
        expand: false,
      }),
      LayoutSpec::Leaf(LeafSpec::{
        id: 2,
        intrinsic: LogicalSize::{ width: 40.0, height: 24.0, },
        expand: false,
      }),
    ],
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 100.0, y: 50.0, },
      size: LogicalSize::{ width: 300.0, height: 200.0, },
    },
    placed,
  )
  assert_eq(placed[0].frame.origin, LogicalPoint::{ x: 100.0, y: 50.0, })
  assert_eq(placed[1].frame.origin, LogicalPoint::{ x: 100.0, y: 78.0, })
}

///|
test "Row 横向累加宽度，间距只加在相邻项之间" {
  let spec = LayoutSpec::Row(LineSpec::{
    axis: Horizontal,
    spacing: 8.0,
    children: [
      LayoutSpec::Leaf(LeafSpec::{
        id: 1,
        intrinsic: LogicalSize::{ width: 60.0, height: 24.0, },
        expand: false,
      }),
      LayoutSpec::Leaf(LeafSpec::{
        id: 2,
        intrinsic: LogicalSize::{ width: 60.0, height: 24.0, },
        expand: false,
      }),
      LayoutSpec::Leaf(LeafSpec::{
        id: 3,
        intrinsic: LogicalSize::{ width: 60.0, height: 24.0, },
        expand: false,
      }),
    ],
  })
  // 3 项 + 2 段间距
  assert_eq(measure(spec, BoxConstraints::loose(400.0, 100.0)), LogicalSize::{
    width: 196.0,
    height: 24.0,
  })
}

///|
test "Spacer 均分剩余空间" {
  let spec = LayoutSpec::Row(LineSpec::{
    axis: Horizontal,
    spacing: 0.0,
    children: [
      LayoutSpec::Leaf(LeafSpec::{
        id: 1,
        intrinsic: LogicalSize::{ width: 40.0, height: 20.0, },
        expand: false,
      }),
      LayoutSpec::Spacer,
      LayoutSpec::Leaf(LeafSpec::{
        id: 2,
        intrinsic: LogicalSize::{ width: 40.0, height: 20.0, },
        expand: false,
      }),
    ],
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 200.0, height: 20.0, },
    },
    placed,
  )
  assert_eq(placed.length(), 2)
  assert_eq(placed[0].frame.origin.x, 0.0)
  // 剩余 120 由单个 Spacer 吃掉
  assert_eq(placed[1].frame.origin.x, 160.0)
}

///|
test "多个 Spacer 均分同一份剩余空间" {
  let spec = LayoutSpec::Row(LineSpec::{
    axis: Horizontal,
    spacing: 0.0,
    children: [
      LayoutSpec::Spacer,
      LayoutSpec::Leaf(LeafSpec::{
        id: 7,
        intrinsic: LogicalSize::{ width: 20.0, height: 10.0, },
        expand: false,
      }),
      LayoutSpec::Spacer,
    ],
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 100.0, height: 10.0, },
    },
    placed,
  )
  assert_eq(placed[0].frame.origin.x, 40.0)
}

///|
test "expand 叶子与 Spacer 共同参与弹性分配" {
  let spec = LayoutSpec::Row(LineSpec::{
    axis: Horizontal,
    spacing: 10.0,
    children: [
      LayoutSpec::Leaf(LeafSpec::{
        id: 1,
        intrinsic: LogicalSize::{ width: 50.0, height: 20.0, },
        expand: true,
      }),
      LayoutSpec::Leaf(LeafSpec::{
        id: 2,
        intrinsic: LogicalSize::{ width: 30.0, height: 20.0, },
        expand: false,
      }),
    ],
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 200.0, height: 20.0, },
    },
    placed,
  )
  // 固定 30 + 间距 10 => 弹性项得 160
  assert_eq(placed[0].frame.size.width, 160.0)
  assert_eq(placed[1].frame.origin.x, 170.0)
}

///|
test "Padding 同时影响测量与摆放" {
  let spec = LayoutSpec::Padding(PaddingSpec::{
    insets: EdgeInsets::all(10.0),
    child: LayoutSpec::Leaf(LeafSpec::{
      id: 1,
      intrinsic: LogicalSize::{ width: 50.0, height: 20.0, },
      expand: false,
    }),
  })
  assert_eq(measure(spec, BoxConstraints::loose(400.0, 400.0)), LogicalSize::{
    width: 70.0,
    height: 40.0,
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 100.0, y: 50.0, },
      size: LogicalSize::{ width: 70.0, height: 40.0, },
    },
    placed,
  )
  assert_eq(placed[0].frame.origin, LogicalPoint::{ x: 110.0, y: 60.0, })
  assert_eq(placed[0].frame.size, LogicalSize::{ width: 50.0, height: 20.0, })
}

///|
test "Center 把子项居中且不改变其尺寸" {
  let spec = LayoutSpec::Center(CenterSpec::{
    child: LayoutSpec::Leaf(LeafSpec::{
      id: 1,
      intrinsic: LogicalSize::{ width: 40.0, height: 20.0, },
      expand: false,
    }),
  })
  assert_eq(measure(spec, BoxConstraints::loose(200.0, 200.0)), LogicalSize::{
    width: 40.0,
    height: 20.0,
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 200.0, height: 100.0, },
    },
    placed,
  )
  assert_eq(placed[0].frame.origin, LogicalPoint::{ x: 80.0, y: 40.0, })
}

///|
test "空容器不产生间距" {
  let spec = LayoutSpec::Row(LineSpec::{
    axis: Horizontal,
    spacing: 16.0,
    children: [],
  })
  assert_eq(measure(spec, BoxConstraints::loose(100.0, 100.0)), LogicalSize::{
    width: 0.0,
    height: 0.0,
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 100.0, height: 100.0, },
    },
    placed,
  )
  assert_eq(placed.length(), 0)
}

///|
test "主轴空间不足时弹性项得零、固定项不被压缩" {
  let spec = LayoutSpec::Row(LineSpec::{
    axis: Horizontal,
    spacing: 0.0,
    children: [
      LayoutSpec::Leaf(LeafSpec::{
        id: 1,
        intrinsic: LogicalSize::{ width: 30.0, height: 10.0, },
        expand: false,
      }),
      LayoutSpec::Spacer,
    ],
  })
  assert_eq(measure(spec, BoxConstraints::loose(20.0, 100.0)), LogicalSize::{
    width: 20.0,
    height: 10.0,
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 10.0, height: 10.0, },
    },
    placed,
  )
  // 固定项保持 30（宁可溢出），Spacer 得 0
  assert_eq(placed[0].frame.size.width, 30.0)
}

///|
test "嵌套布局的叶子矩形按先序输出" {
  let spec = LayoutSpec::Column(LineSpec::{
    axis: Vertical,
    spacing: 4.0,
    children: [
      LayoutSpec::Padding(PaddingSpec::{
        insets: EdgeInsets::{ top: 2.0, end: 0.0, bottom: 0.0, start: 6.0, },
        child: LayoutSpec::Leaf(LeafSpec::{
          id: 11,
          intrinsic: LogicalSize::{ width: 10.0, height: 10.0, },
          expand: false,
        }),
      }),
      LayoutSpec::Row(LineSpec::{
        axis: Horizontal,
        spacing: 2.0,
        children: [
          LayoutSpec::Leaf(LeafSpec::{
            id: 12,
            intrinsic: LogicalSize::{ width: 8.0, height: 8.0, },
            expand: false,
          }),
          LayoutSpec::Leaf(LeafSpec::{
            id: 13,
            intrinsic: LogicalSize::{ width: 8.0, height: 8.0, },
            expand: false,
          }),
        ],
      }),
    ],
  })
  let placed = []
  layout(
    spec,
    LogicalRect::{
      origin: LogicalPoint::{ x: 0.0, y: 0.0, },
      size: LogicalSize::{ width: 100.0, height: 100.0, },
    },
    placed,
  )
  let ids = placed.map(p => p.id)
  assert_eq(ids, [11, 12, 13])
  assert_eq(placed[0].frame.origin, LogicalPoint::{ x: 6.0, y: 2.0, })
  assert_eq(placed[1].frame.origin.x, 0.0)
  assert_eq(placed[2].frame.origin.x, 10.0)
}
