///|
/// 俄罗斯方块的纯逻辑层：不依赖 UI、后端或平台，只有棋盘与状态机。
/// 这一层刻意保持"一帧能跑很多次也不心疼"的小数据结构，帧率基准里
/// 真正吃时间的是绘制命令，不是规则计算。

///|
pub const BOARD_W : Int32 = 10

///|
pub const BOARD_H : Int32 = 20

///|
/// 方块种类：0=I 1=O 2=T 3=S 4=Z 5=J 6=L。
pub fn block_color(kind : Int32) -> Int32 {
  match kind {
    0 => 0x22D3EE
    1 => 0xFACC15
    2 => 0xA78BFA
    3 => 0x4ADE80
    4 => 0xF87171
    5 => 0x60A5FA
    6 => 0xFB923C
    _ => 0x94A3B8
  }
}

///|
fn box_size(kind : Int32) -> Int32 {
  if kind == 0 {
    4
  } else if kind == 1 {
    2
  } else {
    3
  }
}

///|
/// 出生形态写在边长为 n 的方框里，y 向下。
fn base_cells(kind : Int32) -> Array[(Int32, Int32)] {
  match kind {
    0 => [(0, 1), (1, 1), (2, 1), (3, 1)]
    1 => [(0, 0), (1, 0), (0, 1), (1, 1)]
    2 => [(1, 0), (0, 1), (1, 1), (2, 1)]
    3 => [(1, 0), (2, 0), (0, 1), (1, 1)]
    4 => [(0, 0), (1, 0), (1, 1), (2, 1)]
    5 => [(0, 0), (0, 1), (1, 1), (2, 1)]
    6 => [(2, 0), (0, 1), (1, 1), (2, 1)]
    _ => [(0, 0), (1, 0), (0, 1), (1, 1)]
  }
}

///|
/// 某一旋转态的四格坐标。旋转是顺时针 90° 的整数变换，
/// 四个态都从出生态推出来，不另抄四张表。
pub fn cells(kind : Int32, rot : Int32) -> Array[(Int32, Int32)] {
  let n = box_size(kind)
  let times = (rot % 4 + 4) % 4
  let out : Array[(Int32, Int32)] = []
  for c in base_cells(kind) {
    let (x0, y0) = c
    let mut x = x0
    let mut y = y0
    for _k in 0..<times {
      let nx = n - 1 - y
      y = x
      x = nx
    }
    out.push((x, y))
  }
  out
}

///|
/// 踢墙表：y 已经从 SRS 的"向上为正"换成屏幕的"向下为正"。
/// 只按旋转方向分两组，够用且不引入一整套四元表。
fn kick_offsets(kind : Int32, cw : Bool) -> Array[(Int32, Int32)] {
  if kind == 0 {
    if cw {
      [(0, 0), (-2, 0), (1, 0), (-2, 1), (1, -2)]
    } else {
      [(0, 0), (-1, 0), (2, 0), (-1, -2), (2, 1)]
    }
  } else if cw {
    [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)]
  } else {
    [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)]
  }
}

///|
/// 状态：0=待开始 1=进行中 2=暂停 3=结束。
pub(all) struct Game {
  mut board : Array[Int32]
  mut bag : Array[Int32]
  mut bag_pos : Int32
  mut queue : Array[Int32]
  mut kind : Int32
  mut rot : Int32
  mut px : Int32
  mut py : Int32
  mut hold : Int32
  mut hold_used : Bool
  mut score : Int32
  mut lines : Int32
  mut level : Int32
  mut state : Int32
  mut drop_acc : Int32
  mut lock_acc : Int32
  mut lock_resets : Int32
  mut combo : Int32
  mut last_clear : Int32
  mut rng : Int32
  mut pieces : Int32
}

///|
fn spawn_y(kind : Int32) -> Int32 {
  if kind == 0 {
    -1
  } else {
    0
  }
}

///|
/// 所有可变字段在一处收敛，重开与构造共用（帧循环里不必换掉闭包捕获的变量）。
fn Game::init(self : Game, seed : Int32) -> Unit {
  self.board = Array::make(BOARD_W * BOARD_H, 0)
  self.bag = []
  self.bag_pos = BOARD_W
  self.queue = []
  self.kind = 0
  self.rot = 0
  self.px = 3
  self.py = 0
  self.hold = -1
  self.hold_used = false
  self.score = 0
  self.lines = 0
  self.level = 1
  self.state = 0
  self.drop_acc = 0
  self.lock_acc = 0
  self.lock_resets = 0
  self.combo = -1
  self.last_clear = 0
  self.rng = seed
  self.pieces = 0
  self.refill_queue()
  self.spawn_next()
}

///|
pub fn Game::new(seed : Int32) -> Game {
  let g = Game::{
    board: [],
    bag: [],
    bag_pos: 0,
    queue: [],
    kind: 0,
    rot: 0,
    px: 0,
    py: 0,
    hold: -1,
    hold_used: false,
    score: 0,
    lines: 0,
    level: 1,
    state: 0,
    drop_acc: 0,
    lock_acc: 0,
    lock_resets: 0,
    combo: -1,
    last_clear: 0,
    rng: seed,
    pieces: 0,
  }
  g.init(seed)
  g
}

///|
pub fn Game::restart(self : Game) -> Unit {
  self.init(self.rng + 7919)
}

///|
fn Game::next_rand(self : Game, n : Int32) -> Int32 {
  self.rng = self.rng * 1103515245 + 12345
  if self.rng < 0 {
    self.rng = -self.rng
  }
  self.rng / 65536 % n
}

///|
fn Game::shuffle_bag(self : Game) -> Unit {
  let bag : Array[Int32] = []
  for k in [0, 1, 2, 3, 4, 5, 6] {
    bag.push(k)
  }
  for i in 0..<7 {
    let j = self.next_rand(7 - i)
    let at = i + j
    let tmp = bag[i]
    bag[i] = bag[at]
    bag[at] = tmp
  }
  self.bag = bag
  self.bag_pos = 0
}

///|
fn Game::refill_queue(self : Game) -> Unit {
  while self.queue.length() < 5 {
    if self.bag_pos >= self.bag.length() {
      self.shuffle_bag()
    }
    self.queue.push(self.bag[self.bag_pos])
    self.bag_pos += 1
  }
}

///|
fn Game::take_queue(self : Game) -> Int32 {
  let k = self.queue[0]
  let q : Array[Int32] = []
  for i = 1; i < self.queue.length(); i = i + 1 {
    q.push(self.queue[i])
  }
  self.queue = q
  self.refill_queue()
  k
}

///|
fn Game::spawn_next(self : Game) -> Unit {
  self.kind = self.take_queue()
  self.rot = 0
  self.px = 3
  self.py = spawn_y(self.kind)
  self.pieces += 1
  self.drop_acc = 0
  self.lock_acc = 0
  self.lock_resets = 0
  if self.collides(self.kind, self.rot, self.px, self.py) {
    self.state = 3
  }
}

///|
pub fn Game::start(self : Game) -> Unit {
  self.state = 1
}

///|
pub fn Game::toggle_pause(self : Game) -> Unit {
  if self.state == 1 {
    self.state = 2
  } else if self.state == 2 {
    self.state = 1
  }
}

///|
pub fn Game::collides(
  self : Game,
  kind : Int32,
  rot : Int32,
  px : Int32,
  py : Int32,
) -> Bool {
  for c in cells(kind, rot) {
    let (cx, cy) = c
    let x = px + cx
    let y = py + cy
    if x < 0 || x >= BOARD_W || y >= BOARD_H {
      return true
    }
    if y >= 0 && self.board[y * BOARD_W + x] != 0 {
      return true
    }
  }
  false
}

///|
pub fn Game::shift(self : Game, dx : Int32, dy : Int32) -> Bool {
  if self.state != 1 {
    return false
  }
  if self.collides(self.kind, self.rot, self.px + dx, self.py + dy) {
    return false
  }
  self.px += dx
  self.py += dy
  if dy > 0 {
    self.score += 1
    self.lock_acc = 0
  }
  true
}

///|
pub fn Game::rotate(self : Game, dir : Int32) -> Bool {
  if self.state != 1 || self.kind == 1 {
    return false
  }
  let to = (self.rot + dir + 4) % 4
  for off in kick_offsets(self.kind, dir > 0) {
    let (dx, dy) = off
    if !self.collides(self.kind, to, self.px + dx, self.py + dy) {
      self.rot = to
      self.px += dx
      self.py += dy
      self.lock_acc = 0
      return true
    }
  }
  false
}

///|
pub fn Game::ghost_y(self : Game) -> Int32 {
  let mut y = self.py
  while !self.collides(self.kind, self.rot, self.px, y + 1) {
    y += 1
  }
  y
}

///|
pub fn Game::hard_drop(self : Game) -> Int32 {
  if self.state != 1 {
    return 0
  }
  let gy = self.ghost_y()
  let dist = gy - self.py
  self.score += dist * 2
  self.py = gy
  self.lock()
  dist
}

///|
fn Game::clear_lines(self : Game) -> Int32 {
  let mut cleared = 0
  let mut y = BOARD_H - 1
  while y >= 0 {
    let mut full = true
    for x in 0..<BOARD_W {
      if self.board[y * BOARD_W + x] == 0 {
        full = false
      }
    }
    if full {
      cleared += 1
      for yy in y..<BOARD_H {
        for x in 0..<BOARD_W {
          self.board[yy * BOARD_W + x] = self.board[(yy - 1) * BOARD_W + x]
        }
      }
      for x in 0..<BOARD_W {
        self.board[x] = 0
      }
    } else {
      y -= 1
    }
  }
  cleared
}

///|
fn Game::lock(self : Game) -> Unit {
  for c in cells(self.kind, self.rot) {
    let (cx, cy) = c
    let x = self.px + cx
    let y = self.py + cy
    if y < 0 {
      self.state = 3
      return
    }
    self.board[y * BOARD_W + x] = self.kind + 1
  }
  let n = self.clear_lines()
  if n > 0 {
    let base = match n {
      1 => 100
      2 => 300
      3 => 500
      4 => 800
      _ => 0
    }
    if n == 4 && self.last_clear == 4 {
      self.score += base * self.level * 3 / 2
    } else {
      self.score += base * self.level
    }
    if self.combo >= 0 {
      self.score += 50 * (self.combo + 1) * self.level
    }
    self.combo += 1
    self.last_clear = n
    self.lines += n
    self.level = self.lines / 10 + 1
  } else {
    self.combo = -1
    self.last_clear = 0
  }
  self.hold_used = false
  self.spawn_next()
}

///|
fn Game::gravity_ms(self : Game) -> Int32 {
  let speeds = [
    800, 720, 630, 550, 470, 380, 300, 230, 170, 120, 95, 80, 70, 65, 60, 55,
  ]
  let i = if self.level <= 0 {
    0
  } else if self.level > 16 {
    15
  } else {
    self.level - 1
  }
  speeds[i]
}

///|
pub fn Game::tick(self : Game, dt : Int32) -> Unit {
  if self.state != 1 {
    return
  }
  if self.collides(self.kind, self.rot, self.px, self.py + 1) {
    self.lock_acc += dt
    if self.lock_acc >= 500 && self.lock_resets < 15 {
      self.lock()
    }
  } else {
    self.lock_acc = 0
    self.drop_acc += dt
    let step = self.gravity_ms()
    while self.drop_acc >= step {
      self.drop_acc -= step
      if self.collides(self.kind, self.rot, self.px, self.py + 1) {
        break
      }
      self.py += 1
    }
  }
}

///|
pub fn Game::hold_piece(self : Game) -> Unit {
  if self.state != 1 || self.hold_used {
    return
  }
  let cur = self.kind
  if self.hold < 0 {
    self.hold = cur
    self.spawn_next()
  } else {
    let h = self.hold
    self.hold = cur
    self.kind = h
    self.rot = 0
    self.px = 3
    self.py = spawn_y(h)
    self.drop_acc = 0
    self.lock_acc = 0
    if self.collides(self.kind, self.rot, self.px, self.py) {
      self.state = 3
    }
  }
  self.hold_used = true
}
