///|
/// 吸附联动（`T89`）：用户拖一只窗时，把"贴着它"的其它窗按同样的位移一起
/// 带走——一排拼在一起的窗看起来是一整套，拖动的时候也该是一整套。
///
/// 设计上的几个取舍：
///
/// - **不存持久分组**。每次移动都按当下几何现算一次连通块：用户把一只窗拖到
///   另一只旁边，下一步它就跟上了；想拆开，把它拖出容差之外就行。持久分组表
///   还得再配一套"什么时候解散"的规则，两头都容易写歪。
/// - **只认用户拖动**。Core 自己 `set_position` 与位移动画泵推的位置，原生层
///   把回调抑制掉了（与 `suppress_resize` 同一条约定），所以联动本身不会再
///   回声成 Moved——不会自己拖自己。
/// - **只带走看得见的窗**。收起的均衡器/迷你条不该在看不见的地方被拖着走。
/// - 位移量取自"这只窗上一次在哪"（`Window::last_origin`）：原生只报新位置，
///   没有上一次就没有 delta。
const DOCK_SNAP_GAP : Double = 12.0

///|
/// 吸附判定用的一只窗的矩形（逻辑像素，外层左上角原点）。
priv struct DockBox {
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
fn dock_box_of(origin : LogicalPoint, size : LogicalSize) -> DockBox {
  { x: origin.x, y: origin.y, w: size.width, h: size.height, }
}

///|
/// 两窗"贴在一起"没有：并排（纵向有重叠、水平缝 ≤ 容差）或上下叠（横向有
/// 重叠、垂直缝 ≤ 容差）。斜对角只碰到一个点的不算——那种情况两窗没有共同的
/// 边，拖动一只带动另一只反而突兀。
fn dock_touching(a : DockBox, b : DockBox) -> Bool {
  let ax1 = a.x + a.w
  let ay1 = a.y + a.h
  let bx1 = b.x + b.w
  let by1 = b.y + b.h
  let gap_x = if b.x > ax1 {
    b.x - ax1
  } else if a.x > bx1 {
    a.x - bx1
  } else {
    0.0
  }
  let gap_y = if b.y > ay1 {
    b.y - ay1
  } else if a.y > by1 {
    a.y - by1
  } else {
    0.0
  }
  let ov_x = (if ax1 < bx1 { ax1 } else { bx1 }) -
    (if a.x > b.x { a.x } else { b.x })
  let ov_y = (if ay1 < by1 { ay1 } else { by1 }) -
    (if a.y > b.y { a.y } else { b.y })
  (ov_y > 0.0 && gap_x <= DOCK_SNAP_GAP) ||
  (ov_x > 0.0 && gap_y <= DOCK_SNAP_GAP)
}

///|
fn dock_group_has(group : Array[Int32], i : Int32) -> Bool {
  let mut found = false
  for k in group {
    if k == i {
      found = true
    }
  }
  found
}

///|
/// 开/关吸附联动。默认开；关掉之后拖窗各走各的（排版类应用多半想要这个）。
pub fn[B] App::set_dock_enabled(self : App[B], on : Bool) -> Unit {
  self.dock = on
}

///|
/// 吸附联动的当前开关。
pub fn[B] App::dock_enabled(self : App[B]) -> Bool {
  self.dock
}

///|
/// 处理一条 `Moved`：记下这只窗的新原点，并把吸附在同一块里的其它窗按同样
/// 的位移搬走（`T89`）。返回是否找到了这只窗（派发路由用）。
///
/// 分组按**移动前**的几何算：邻居本来就是"贴着它"才该跟着走，而按移动后的
/// 位置去判，一次大步拖动会让缝一下子超出容差、邻居反而掉队（越拖越散）。
/// 移动前贴着 → 整体平移 → 移动后依然贴着，几何自洽。
pub fn[B : Backend] App::follow_move(
  self : App[B],
  target : EventTarget,
  p : LogicalPoint,
) -> Bool {
  let mut mover : Int32 = -1
  for i, win in self.windows {
    if !win.is_closed() && win.target() == target {
      mover = i
    }
  }
  if mover < 0 {
    return false
  }
  let m = self.windows[mover]
  let prev = m.last_origin
  let dx = p.x - prev.x
  let dy = p.y - prev.y
  // 被拖窗的新原点**先别记**——连通块要按移动前几何判（mover 的 last_origin
  // 此刻仍是 prev）。若在这里就写成 p，"拖离邻居"的方向（往左上拖，而邻居在
  // 右/下）会让 mover 的框一步跨出容差、与旧位置的邻居断开，邻居反而不跟。
  if !self.dock || (dx == 0.0 && dy == 0.0) {
    m.last_origin = p
    return true
  }
  // 连通扩散：从被拖的这只出发，凡是贴着组内某一只的都并进来（A 贴 B、
  // B 贴 C 时，拖 A 也要带走 C——它们是同一个"排"）。
  let group : Array[Int32] = [mover]
  let mut head = 0
  while head < group.length() {
    let a = self.windows[group[head]]
    head = head + 1
    let asz = a.size() catch { _ => LogicalSize(0.0, 0.0) }
    if asz.width <= 0.0 || asz.height <= 0.0 {
      continue
    }
    let abox = dock_box_of(a.last_origin, asz)
    for j, b in self.windows {
      if j == mover || dock_group_has(group, j) {
        continue
      }
      if b.is_closed() || !b.visible {
        continue
      }
      let bsz = b.size() catch { _ => LogicalSize(0.0, 0.0) }
      if bsz.width <= 0.0 || bsz.height <= 0.0 {
        continue
      }
      if dock_touching(abox, dock_box_of(b.last_origin, bsz)) {
        group.push(j)
      }
    }
  }
  for k = 1; k < group.length(); k = k + 1 {
    let b = self.windows[group[k]]
    let np = LogicalPoint(b.last_origin.x + dx, b.last_origin.y + dy)
    let _ = b.set_position(np) catch { _ => () }
  }
  // 邻居搬完，最后才记被拖窗的新原点（此刻 mover 的 last_origin 仍是 prev）。
  m.last_origin = p
  true
}

///|
/// 吸附：拖一只，贴着它的邻居按同样的位移一起走；隔着空位的那只不动。
test "吸附：拖动一只窗，贴着它的邻居一起走，离得远的不动" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let left = app.create_window("左", LogicalSize(300.0, 200.0))
  let right = app.create_window("右", LogicalSize(300.0, 200.0))
  let far = app.create_window("远", LogicalSize(300.0, 200.0))
  left.set_position(LogicalPoint(100.0, 100.0))
  // 右窗贴着左窗（缝 6，落在容差内）；远窗在下面隔着一大段空
  right.set_position(LogicalPoint(406.0, 100.0))
  far.set_position(LogicalPoint(100.0, 700.0))
  left.show()
  right.show()
  far.show()
  // 用户把左窗拖到 (+40, +25)：原生先落位置，再报一条 Moved
  MockBackend::push_window_moved(b, left.handle(), LogicalPoint(140.0, 125.0))
  let _ = app.step()
  assert_eq(left.position(), LogicalPoint(140.0, 125.0))
  assert_eq(right.position(), LogicalPoint(446.0, 125.0))
  assert_eq(far.position(), LogicalPoint(100.0, 700.0))
  Backend::terminate(b)
}

///|
/// 吸附是**连通**的：A 贴 B、B 贴 C，拖 A 时 C 也要跟（它们是一整排）。
test "吸附：一排三只——拖最左那只，中间和右边都跟" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let a = app.create_window("A", LogicalSize(200.0, 150.0))
  let c = app.create_window("B", LogicalSize(200.0, 150.0))
  let d = app.create_window("C", LogicalSize(200.0, 150.0))
  a.set_position(LogicalPoint(100.0, 100.0))
  c.set_position(LogicalPoint(306.0, 100.0))
  d.set_position(LogicalPoint(512.0, 100.0))
  for w in [a, c, d] {
    w.show()
  }
  MockBackend::push_window_moved(b, a.handle(), LogicalPoint(110.0, 100.0))
  let _ = app.step()
  assert_eq(c.position(), LogicalPoint(316.0, 100.0))
  assert_eq(d.position(), LogicalPoint(522.0, 100.0))
  Backend::terminate(b)
}

///|
/// 关掉吸附之后各走各的：同一个位置、同样的拖动，邻居一步不动。
test "吸附：关掉联动后邻居不动" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  app.set_dock_enabled(false)
  let left = app.create_window("左", LogicalSize(300.0, 200.0))
  let right = app.create_window("右", LogicalSize(300.0, 200.0))
  left.set_position(LogicalPoint(100.0, 100.0))
  right.set_position(LogicalPoint(406.0, 100.0))
  left.show()
  right.show()
  MockBackend::push_window_moved(b, left.handle(), LogicalPoint(140.0, 125.0))
  let _ = app.step()
  assert_eq(right.position(), LogicalPoint(406.0, 100.0))
  Backend::terminate(b)
}

///|
/// 收起的窗不被拖走：隐着的窗在屏幕上看不见，跟着跑只会在下次打开时跑到
/// 一个莫名其妙的位置。
test "吸附：收起的窗不跟着走" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let left = app.create_window("左", LogicalSize(300.0, 200.0))
  let hidden = app.create_window("藏", LogicalSize(300.0, 200.0))
  left.set_position(LogicalPoint(100.0, 100.0))
  hidden.set_position(LogicalPoint(406.0, 100.0))
  left.show()
  // hidden 不 show：位置贴着，但不在屏幕上
  MockBackend::push_window_moved(b, left.handle(), LogicalPoint(140.0, 125.0))
  let _ = app.step()
  assert_eq(hidden.position(), LogicalPoint(406.0, 100.0))
  Backend::terminate(b)
}

///|
/// 往**左上**拖（负位移）——回归：这是"拖离邻居"的方向，邻居在右/下。若按
/// 移动后的几何判连通，mover 的框一步跨出容差就与旧邻居断开、邻居掉队。
test "吸附：往左上拖主窗，右边与下边的邻居都跟" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let main = app.create_window("主", LogicalSize(380.0, 176.0))
  let lyrics = app.create_window("词", LogicalSize(408.0, 176.0))
  let pl = app.create_window("列", LogicalSize(794.0, 320.0))
  main.set_position(LogicalPoint(100.0, 100.0))
  // 词在主右（缝 6）；列在主下、横跨（缝 6）——与默认布局同形
  lyrics.set_position(LogicalPoint(486.0, 100.0))
  pl.set_position(LogicalPoint(100.0, 282.0))
  for w in [main, lyrics, pl] {
    w.show()
  }
  // 往左上拖 (-40, -25)
  MockBackend::push_window_moved(b, main.handle(), LogicalPoint(60.0, 75.0))
  let _ = app.step()
  assert_eq(main.position(), LogicalPoint(60.0, 75.0))
  assert_eq(lyrics.position(), LogicalPoint(446.0, 75.0))
  assert_eq(pl.position(), LogicalPoint(60.0, 257.0))
  Backend::terminate(b)
}

///|
/// 延迟修复（live 直达）：拖动的**同步栈上**邻居就该跟上——不等 `step`。
/// 拖拽跑在系统模态循环里（mac 的窗口跟踪循环、Win32 的 sizing 循环），
/// `App::step` 被泵卡住、队列排不动；走队列的话松手前邻居一动不动（延迟跟）。
test "吸附：live 直达——拖动当场邻居就跟着走，不等事件循环" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  let left = app.create_window("左", LogicalSize(300.0, 200.0))
  let right = app.create_window("右", LogicalSize(300.0, 200.0))
  left.set_position(LogicalPoint(100.0, 100.0))
  right.set_position(LogicalPoint(406.0, 100.0))
  left.show()
  right.show()
  // 用户把左窗拖到 (+40, +25)——只推事件，**不 step**
  MockBackend::push_window_moved(b, left.handle(), LogicalPoint(140.0, 125.0))
  assert_eq(left.position(), LogicalPoint(140.0, 125.0))
  assert_eq(right.position(), LogicalPoint(446.0, 125.0))
  Backend::terminate(b)
}

///|
/// 直达通道没装（裸后端）的回退：入队、同窗旧 Moved 合并成最新一份，`step`
/// 之后一次性追上——"松手后追上"是这条回退路的全部语义，不是拖多少次跟多少次。
test "吸附：通道没装时入队合并，step 后按最新一份一次追上" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  // 模拟裸后端：没人装直达通道（`App::new` 装上的那条摘掉）
  Backend::set_live_dispatch(b, None)
  let left = app.create_window("左", LogicalSize(300.0, 200.0))
  let right = app.create_window("右", LogicalSize(300.0, 200.0))
  left.set_position(LogicalPoint(100.0, 100.0))
  right.set_position(LogicalPoint(406.0, 100.0))
  left.show()
  right.show()
  // 拖动途中原生连报两次，中间没有 step
  MockBackend::push_window_moved(b, left.handle(), LogicalPoint(140.0, 125.0))
  MockBackend::push_window_moved(b, left.handle(), LogicalPoint(180.0, 150.0))
  // 消费之前邻居不动
  assert_eq(right.position(), LogicalPoint(406.0, 100.0))
  let _ = app.step()
  // 只补一次、按最新那份 (180,150)：右窗 (+80, +50)
  assert_eq(left.position(), LogicalPoint(180.0, 150.0))
  assert_eq(right.position(), LogicalPoint(486.0, 150.0))
  Backend::terminate(b)
}
