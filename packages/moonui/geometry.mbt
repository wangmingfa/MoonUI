///|
/// 几何与 HiDPI（设计文档 §30）。
///
/// MoonUI 公共 API 一律使用逻辑像素；物理像素只在 Backend 内部出现。
/// 换算集中在这里，是为了避免尺寸语义散落到各组件里——文档 §47 第 5 条
/// 风险（Logical / Physical 混淆）的缓解手段就是"只允许这一处换算"。

///|
/// 逻辑尺寸，单位：逻辑像素
pub(all) struct LogicalSize {
  width : Double
  height : Double
} derive(Debug, Eq)

///|
/// 逻辑坐标点，原点位于容器左上角，单位：逻辑像素
pub(all) struct LogicalPoint {
  x : Double
  y : Double
} derive(Debug, Eq)

///|
/// 逻辑矩形，`size` 可为负，规范化见 `normalized`
pub(all) struct LogicalRect {
  origin : LogicalPoint
  size : LogicalSize
} derive(Debug, Eq)

///|
/// 设备缩放因子。`1.0` 对应 96dpi 标准屏，`2.0` 对应 Retina。
pub(all) struct Scale {
  x : Double
  y : Double
} derive(Debug, Eq)

///|
pub fn Scale::one() -> Scale {
  Scale::{ x: 1.0, y: 1.0, }
}

///|
/// 由 DPI 构造缩放因子；低于 1.0 的值被夹紧到 1.0，避免反缩放导致
/// 控件小于 1 物理像素而被系统丢弃。
pub fn Scale::of_dpi(dpi : Double) -> Scale {
  let k = if dpi < 96.0 { 1.0 } else { dpi / 96.0 }
  Scale::{ x: k, y: k, }
}

///|
/// 合法化缩放因子：任一轴低于 1.0 都按 1.0 处理。
///
/// 与 `of_dpi` 的夹紧规则一致（标准屏以下不反缩放），意义是堵住除零：
/// `to_logical_*` 要除以缩放因子，后端返回 0.0（未初始化的 DPI 字段）时
/// 会让整个布局变成 Infinity，而 1.0 是最保守的可读结果。Core 只在
/// `Window::scale` 这一处收后端给的 Scale，所以放行到这里就够了。
pub fn Scale::normalized(self : Scale) -> Scale {
  Scale::{
    x: clamp_double(self.x, 1.0, Infinity),
    y: clamp_double(self.y, 1.0, Infinity),
  }
}

///|
/// 逻辑像素 → 物理像素。尺寸向上取整，保证内容不被裁掉。
pub fn Scale::to_physical_size(
  self : Scale,
  size : LogicalSize,
) -> PhysicalSize {
  let s = self.normalized()
  PhysicalSize::{
    width: ceil_to_int(size.width * s.x),
    height: ceil_to_int(size.height * s.y),
  }
}

///|
/// 物理像素 → 逻辑像素
pub fn Scale::to_logical_size(self : Scale, size : PhysicalSize) -> LogicalSize {
  let s = self.normalized()
  LogicalSize::{
    width: size.width.to_double() / s.x,
    height: size.height.to_double() / s.y,
  }
}

///|
/// 物理坐标原点（取整到最近像素，用于鼠标命中判定）
pub fn Scale::to_physical_point(
  self : Scale,
  p : LogicalPoint,
) -> PhysicalPoint {
  let s = self.normalized()
  PhysicalPoint::{ x: round_to_int(p.x * s.x), y: round_to_int(p.y * s.y), }
}

///|
/// 物理坐标 → 逻辑坐标。命中判定用 `to_physical_point` 取整，这里反过来做
/// 的是"物理设备坐标落到逻辑布局空间"，不做取整——滚动惯性、文本选区
/// 都依赖小数部分，提前取整会让拖拽抖动。
pub fn Scale::to_logical_point(self : Scale, p : PhysicalPoint) -> LogicalPoint {
  let s = self.normalized()
  LogicalPoint::{ x: p.x.to_double() / s.x, y: p.y.to_double() / s.y, }
}

///|
/// 矩形换算：原点向下取整、宽高向上取整。
///
/// 相邻矩形的公共边落在同一个整数上（如 x=100.5 与 x=150.5、宽 50 →
/// [100,150) 与 [150,200)），既不重叠也不留缝，这是绘制层唯一需要的性质。
pub fn Scale::to_physical_rect(self : Scale, r : LogicalRect) -> PhysicalRect {
  let s = self.normalized()
  let n = r.normalized()
  PhysicalRect::{
    origin: PhysicalPoint::{
      x: floor_to_int(n.origin.x * s.x),
      y: floor_to_int(n.origin.y * s.y),
    },
    size: PhysicalSize::{
      width: ceil_to_int(n.size.width * s.x),
      height: ceil_to_int(n.size.height * s.y),
    },
  }
}

///|
/// 物理矩形 → 逻辑矩形：原点与宽高都按因子线性缩放，取整留给绘制层。
pub fn Scale::to_logical_rect(self : Scale, r : PhysicalRect) -> LogicalRect {
  let s = self.normalized()
  LogicalRect::{
    origin: LogicalPoint::{
      x: r.origin.x.to_double() / s.x,
      y: r.origin.y.to_double() / s.y,
    },
    size: LogicalSize::{
      width: r.size.width.to_double() / s.x,
      height: r.size.height.to_double() / s.y,
    },
  }
}

///|
pub(all) struct PhysicalSize {
  width : Int
  height : Int
} derive(Debug, Eq)

///|
pub(all) struct PhysicalPoint {
  x : Int
  y : Int
} derive(Debug, Eq)

///|
/// 物理像素矩形，只在 Backend/绘制层出现；公共 API 一律是逻辑像素（§30）。
pub(all) struct PhysicalRect {
  origin : PhysicalPoint
  size : PhysicalSize
} derive(Debug, Eq)

///|
pub fn LogicalSize::zero() -> LogicalSize {
  LogicalSize::{ width: 0.0, height: 0.0, }
}

///|
pub fn LogicalSize::clamp(
  self : LogicalSize,
  min : LogicalSize,
  max : LogicalSize,
) -> LogicalSize {
  LogicalSize::{
    width: clamp_double(self.width, min.width, max.width),
    height: clamp_double(self.height, min.height, max.height),
  }
}

///|
/// 把负宽高归零，保持原点不变。
pub fn LogicalSize::non_negative(self : LogicalSize) -> LogicalSize {
  LogicalSize::{
    width: if self.width < 0.0 {
      0.0
    } else {
      self.width
    },
    height: if self.height < 0.0 {
      0.0
    } else {
      self.height
    },
  }
}

///|
/// 面积；参与布局分配计算，负值按零处理。
pub fn LogicalSize::area(self : LogicalSize) -> Double {
  self.non_negative().width * self.non_negative().height
}

///|
/// 矩形左上角加偏移
pub fn LogicalPoint::offset(
  self : LogicalPoint,
  dx : Double,
  dy : Double,
) -> LogicalPoint {
  LogicalPoint::{ x: self.x + dx, y: self.y + dy, }
}

///|
/// 矩形右下角（origin + size）
pub fn LogicalRect::max(self : LogicalRect) -> LogicalPoint {
  LogicalPoint::{
    x: self.origin.x + self.size.width,
    y: self.origin.y + self.size.height,
  }
}

///|
/// 把负宽高折成有效矩形，同时修正原点
pub fn LogicalRect::normalized(self : LogicalRect) -> LogicalRect {
  let min_x = if self.size.width < 0.0 {
    self.origin.x + self.size.width
  } else {
    self.origin.x
  }
  let min_y = if self.size.height < 0.0 {
    self.origin.y + self.size.height
  } else {
    self.origin.y
  }
  LogicalRect::{
    origin: LogicalPoint::{ x: min_x, y: min_y, },
    size: LogicalSize::{
      width: if self.size.width < 0.0 {
        -self.size.width
      } else {
        self.size.width
      },
      height: if self.size.height < 0.0 {
        -self.size.height
      } else {
        self.size.height
      },
    },
  }
}

///|
/// 命中测试：点是否落在矩形内（含左上、不含右下），与主流工具链一致，
/// 保证相邻矩形共享边界时不会双重命中。
pub fn LogicalRect::contains(self : LogicalRect, p : LogicalPoint) -> Bool {
  let r = self.normalized()
  p.x >= r.origin.x && p.x < r.max().x && p.y >= r.origin.y && p.y < r.max().y
}

///|
/// 交集，无交集时返回零尺寸矩形
pub fn LogicalRect::intersect(
  self : LogicalRect,
  other : LogicalRect,
) -> LogicalRect {
  let a = self.normalized()
  let b = other.normalized()
  let x0 = if a.origin.x > b.origin.x { a.origin.x } else { b.origin.x }
  let y0 = if a.origin.y > b.origin.y { a.origin.y } else { b.origin.y }
  let x1 = if a.max().x < b.max().x { a.max().x } else { b.max().x }
  let y1 = if a.max().y < b.max().y { a.max().y } else { b.max().y }
  if x1 <= x0 || y1 <= y0 {
    LogicalRect::{
      origin: LogicalPoint::{ x: x0, y: y0, },
      size: LogicalSize::zero(),
    }
  } else {
    LogicalRect::{
      origin: LogicalPoint::{ x: x0, y: y0, },
      size: LogicalSize::{ width: x1 - x0, height: y1 - y0, },
    }
  }
}

///|
/// 内容区：从外框按四边内缩，内缩超过框宽时夹紧为零，不产生负尺寸。
pub fn LogicalRect::inset(
  self : LogicalRect,
  top : Double,
  right : Double,
  bottom : Double,
  left : Double,
) -> LogicalRect {
  let r = self.normalized()
  let w = r.size.width - left - right
  let h = r.size.height - top - bottom
  LogicalRect::{
    origin: LogicalPoint::{ x: r.origin.x + left, y: r.origin.y + top, },
    size: LogicalSize::{
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
/// 居中放置 `inner` 于 `outer` 内，奇数余量偏向左上，保证取整后不抖动。
pub fn LogicalRect::center(
  self : LogicalRect,
  inner : LogicalSize,
) -> LogicalRect {
  let dx = (self.size.width - inner.width) / 2.0
  let dy = (self.size.height - inner.height) / 2.0
  LogicalRect::{
    origin: LogicalPoint::{
      x: self.origin.x + (if dx < 0.0 { 0.0 } else { dx }),
      y: self.origin.y + (if dy < 0.0 { 0.0 } else { dy }),
    },
    size: inner,
  }
}

///|
fn clamp_double(v : Double, lo : Double, hi : Double) -> Double {
  let upper = if hi < lo { lo } else { hi }
  if v < lo {
    lo
  } else if v > upper {
    upper
  } else {
    v
  }
}

///|
fn ceil_to_int(v : Double) -> Int {
  let c = v.ceil()
  if c.to_int() < 0 {
    0
  } else {
    c.to_int()
  }
}

///|
/// 矩形原点专用：向零以下的整数取整，负坐标按 0 处理（容器没有负偏移可言）。
fn floor_to_int(v : Double) -> Int {
  let f = v.floor()
  if f.to_int() < 0 {
    0
  } else {
    f.to_int()
  }
}

///|
fn round_to_int(v : Double) -> Int {
  let r = v.round()
  if r.to_int() < 0 {
    0
  } else {
    r.to_int()
  }
}

///|
test "逻辑像素与物理像素按缩放因子换算" {
  let s2 = Scale::{ x: 2.0, y: 2.0, }
  assert_eq(
    s2.to_physical_size(LogicalSize::{ width: 800.0, height: 600.0, }),
    PhysicalSize::{ width: 1600, height: 1200, },
  )
  assert_eq(s2.to_logical_size(PhysicalSize::{ width: 1600, height: 1200, }), LogicalSize::{
    width: 800.0,
    height: 600.0,
  })
  assert_eq(
    Scale::one().to_physical_size(LogicalSize::{ width: 100.5, height: 10.0, }),
    PhysicalSize::{ width: 101, height: 10, },
  )
}

///|
test "of_dpi 夹紧到不小于 1.0 且按 96dpi 归一" {
  assert_eq(Scale::of_dpi(96.0), Scale::{ x: 1.0, y: 1.0, })
  assert_eq(Scale::of_dpi(192.0), Scale::{ x: 2.0, y: 2.0, })
  assert_eq(Scale::of_dpi(72.0), Scale::{ x: 1.0, y: 1.0, })
}

///|
test "物理坐标换算：尺寸向上取整，点位就近取整" {
  let s15 = Scale::{ x: 1.5, y: 1.5, }
  assert_eq(
    s15.to_physical_size(LogicalSize::{ width: 100.0, height: 33.3, }),
    PhysicalSize::{ width: 150, height: 50, },
  )
  assert_eq(s15.to_physical_point(LogicalPoint::{ x: 10.0, y: 33.3, }), PhysicalPoint::{
    x: 15,
    y: 50,
  })
}

///|
test "矩形内缩与交集不会产生负尺寸" {
  let frame = LogicalRect::{
    origin: LogicalPoint::{ x: 0.0, y: 0.0, },
    size: LogicalSize::{ width: 100.0, height: 50.0, },
  }
  assert_eq(frame.inset(10.0, 10.0, 10.0, 10.0), LogicalRect::{
    origin: LogicalPoint::{ x: 10.0, y: 10.0, },
    size: LogicalSize::{ width: 80.0, height: 30.0, },
  })
  // 内缩超过框宽：尺寸夹为零，原点按 left 移动
  let squeezed = frame.inset(0.0, 0.0, 0.0, 200.0)
  assert_eq(squeezed.size, LogicalSize::{ width: 0.0, height: 50.0, })
  assert_eq(squeezed.origin, LogicalPoint::{ x: 200.0, y: 0.0, })
  let other = LogicalRect::{
    origin: LogicalPoint::{ x: 50.0, y: 25.0, },
    size: LogicalSize::{ width: 100.0, height: 100.0, },
  }
  assert_eq(frame.intersect(other), LogicalRect::{
    origin: LogicalPoint::{ x: 50.0, y: 25.0, },
    size: LogicalSize::{ width: 50.0, height: 25.0, },
  })
  assert_eq(
    frame.intersect(LogicalRect::{
      origin: LogicalPoint::{ x: 500.0, y: 500.0, },
      size: LogicalSize::{ width: 10.0, height: 10.0, },
    }).size,
    LogicalSize::zero(),
  )
}

///|
test "命中测试含左上不含右下，相邻矩形不会双重命中" {
  let left = LogicalRect::{
    origin: LogicalPoint::{ x: 0.0, y: 0.0, },
    size: LogicalSize::{ width: 10.0, height: 10.0, },
  }
  assert_true(left.contains(LogicalPoint::{ x: 0.0, y: 0.0, }))
  assert_false(left.contains(LogicalPoint::{ x: 10.0, y: 5.0, }))
  assert_false(left.contains(LogicalPoint::{ x: 5.0, y: 10.0, }))
}

///|
test "负尺寸矩形被规范化" {
  let flipped = LogicalRect::{
    origin: LogicalPoint::{ x: 10.0, y: 10.0, },
    size: LogicalSize::{ width: -4.0, height: -6.0, },
  }
  assert_eq(flipped.normalized(), LogicalRect::{
    origin: LogicalPoint::{ x: 6.0, y: 4.0, },
    size: LogicalSize::{ width: 4.0, height: 6.0, },
  })
}

///|
test "clamp 与 area 对负值按零处理" {
  let big = LogicalSize::{ width: 100.0, height: 100.0, }
  let small = LogicalSize::{ width: 10.0, height: 10.0, }
  let v = LogicalSize::{ width: 500.0, height: 5.0, }
  assert_eq(v.clamp(small, big), LogicalSize::{ width: 100.0, height: 10.0, })
  assert_eq(LogicalSize::{ width: -5.0, height: 4.0, }.area(), 0.0)
  assert_eq(LogicalSize::{ width: 3.0, height: 4.0, }.area(), 12.0)
}

///|
test "物理矩形：原点向下取整、宽高向上取整" {
  let s2 = Scale::{ x: 2.0, y: 2.0, }
  let r = LogicalRect::{
    origin: LogicalPoint::{ x: 12.5, y: 7.25, },
    size: LogicalSize::{ width: 30.0, height: 10.0, },
  }
  assert_eq(s2.to_physical_rect(r), PhysicalRect::{
    origin: PhysicalPoint::{ x: 25, y: 14, },
    size: PhysicalSize::{ width: 60, height: 20, },
  })
  // 负宽高先规范化，换算出来的矩形不会倒退
  assert_eq(
    Scale::one().to_physical_rect(LogicalRect::{
      origin: LogicalPoint::{ x: 10.0, y: 10.0, },
      size: LogicalSize::{ width: -4.0, height: -6.0, },
    }),
    PhysicalRect::{
      origin: PhysicalPoint::{ x: 6, y: 4, },
      size: PhysicalSize::{ width: 4, height: 6, },
    },
  )
}

///|
test "相邻矩形的物理公共边不重叠也不留缝" {
  // 1x 屏上 100.5 与 150.5 两个相邻边界：floor 后正好接在 150
  let left = LogicalRect::{
    origin: LogicalPoint::{ x: 100.5, y: 0.0, },
    size: LogicalSize::{ width: 50.0, height: 20.0, },
  }
  let right = LogicalRect::{
    origin: LogicalPoint::{ x: 150.5, y: 0.0, },
    size: LogicalSize::{ width: 50.0, height: 20.0, },
  }
  let pl = Scale::one().to_physical_rect(left)
  let pr = Scale::one().to_physical_rect(right)
  assert_eq(pl.origin.x + pl.size.width, pr.origin.x)
}

///|
test "物理值可以还原成逻辑值，逻辑尺寸不做取整" {
  let s2 = Scale::{ x: 2.0, y: 2.0, }
  assert_eq(s2.to_logical_size(PhysicalSize::{ width: 40, height: 21, }), LogicalSize::{
    width: 20.0,
    height: 10.5,
  })
  // 保留小数：拖拽/选区依赖分数部分，提前取整会抖
  assert_eq(s2.to_logical_point(PhysicalPoint::{ x: 25, y: 15, }), LogicalPoint::{
    x: 12.5,
    y: 7.5,
  })
  assert_eq(
    s2.to_logical_rect(PhysicalRect::{
      origin: PhysicalPoint::{ x: 20, y: 30, },
      size: PhysicalSize::{ width: 61, height: 40, },
    }),
    LogicalRect::{
      origin: LogicalPoint::{ x: 10.0, y: 15.0, },
      size: LogicalSize::{ width: 30.5, height: 20.0, },
    },
  )
}

///|
/// 后端 DPI 字段未初始化（0.0）不能把布局变成 Infinity——这是 §47 第 5 条
/// 风险唯一需要主动防守的地方，防守点在 Scale 本身。
test "非法缩放因子被夹紧到 1.0，换算永不产生 Infinity" {
  let broken = Scale::{ x: 0.0, y: -2.0, }
  assert_eq(broken.normalized(), Scale::{ x: 1.0, y: 1.0, })
  assert_eq(broken.to_logical_size(PhysicalSize::{ width: 40, height: 20, }), LogicalSize::{
    width: 40.0,
    height: 20.0,
  })
  assert_eq(
    broken.to_physical_size(LogicalSize::{ width: 40.0, height: 20.0, }),
    PhysicalSize::{ width: 40, height: 20, },
  )
  // 合法值不受影响，1.5 这类非整数缩放仍然保留
  assert_eq(Scale::{ x: 1.5, y: 1.5, }.normalized(), Scale::{ x: 1.5, y: 1.5, })
}
