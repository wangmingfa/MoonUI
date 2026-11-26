///|
/// 坦克大战（Battle City / Tank 1990）的纯逻辑层。
///
/// 与 UI 完全解耦：不 import 任何后端/平台包，只有战场、坦克、子弹、
/// 道具与关卡状态机。一帧 = 一次 `tick(dt)`；速度单位是"格/帧"，
/// 由 main.mbt 的 60fps 定拍驱动（dt≈16ms 只作占位，规则不读真实时钟，
/// 保证同一份输入在慢机/快机上都得到同一局）。
///
/// 战场口径：13×13 块（每块 16px，共 208px），可破坏物按 8×8 子块记账
/// （26×26 格），一颗子弹打掉一格子块——与原始版"砖墙一块一块碎"一致。
///
/// 复刻口径（Tank 1990 / 小霸王）：
///  - 20 辆敌坦克/关，场上同时最多 4 辆，从顶边三个出生点轮流出；
///  - 四种敌型：普通(100)/快速(200)/火力(300)/装甲(400，4 血)；
///  - 每消灭第 4 辆掉一个道具，按 星→护盾→铁锹→时钟→手雷→坦克 循环；
///  - 基地（老鹰）被毁即游戏结束；星三级子弹可打穿钢板；
///  - 冰面打滑、树林遮坦克、水面挡坦克不挡子弹。
pub const FIELD_TILES : Int32 = 13

///|
pub const TILE_PX : Int32 = 16

///|
pub const CELL_PX : Int32 = 8

///|
pub const CELLS : Int32 = 26

///|
pub const FIELD_PX : Int32 = 208

///|
pub const TANK_PX : Int32 = 16

///|
pub const BULLET_PX : Int32 = 4

///|
/// 基地（老鹰）占据的 2×2 块区域：tile (6..7, 11..12) → px (96..128, 176..208)。
pub const EAGLE_X : Int32 = 96

///|
pub const EAGLE_Y : Int32 = 176

///|
pub const EAGLE_S : Int32 = 32

///|
/// 玩家出生点（tile 4,12）。
pub const PLAYER_SPAWN_X : Int32 = 64

///|
pub const PLAYER_SPAWN_Y : Int32 = 192

///|
/// 玩家坦克速度（1/10 像素/帧）：原 2px/帧，改 70% 后 = 2×7 = 14。
pub const PLAYER_SPEED_TENTHS : Int32 = 14

///|
/// 敌方坦克速度的 70% 因子（×7/10）：`enemy_speed(kind)` 是原始整数 px/帧，
/// 移动时乘这一位再进 `advance_acc` 累积成亚像素步。
pub const ENEMY_SPEED_SCALE : Int32 = 7

///|
/// 敌方出生点横坐标（tile 0,0 / 6,0 / 12,0）。
pub fn spawn_x_at(k : Int32) -> Int32 {
  match k {
    0 => 0
    1 => 96
    _ => 192
  }
}

///|
#derive(Debug, Eq)
pub(all) enum Dir {
  Up
  Down
  Left
  Right
}

///|
pub fn dir_vec(d : Dir) -> (Int32, Int32) {
  match d {
    Up => (0, -1)
    Down => (0, 1)
    Left => (-1, 0)
    Right => (1, 0)
  }
}

///|
pub fn dir_code(d : Dir) -> Int32 {
  match d {
    Up => 0
    Down => 1
    Left => 2
    Right => 3
  }
}

///|
pub fn code_dir(c : Int32) -> Dir {
  match c {
    0 => Up
    1 => Down
    2 => Left
    _ => Right
  }
}

///|
/// 地形子块：一块 8×8。可破坏物按块记账，子弹毁块不毁整块砖。
#derive(Debug, Eq)
pub(all) enum Terrain {
  Empty
  Brick
  Steel
  Water
  Tree
  Ice
}

///|
#derive(Debug, Eq)
pub(all) enum TankKind {
  Basic
  Fast
  Power
  Armor
}

///|
#derive(Debug, Eq)
pub(all) enum PowerKind {
  Star
  Helmet
  Shovel
  Clock
  Grenade
  Life
}

///|
/// 0=吸引（标题） 1=关卡开场 2=进行中 3=过场（过关） 4=结束。
#derive(Debug, Eq)
pub(all) enum State {
  Attract
  StageIntro
  Playing
  StageClear
  GameOver
}

///|
/// 音效事件：规则层只把"发生了什么"记进 `sfx_queue`，由 UI 层（main.mbt）
/// 每帧排空并播放——game.mbt 保持纯逻辑，不碰后端。
#derive(Debug, Eq)
pub(all) enum Sfx {
  Move
  Shoot
  HitWall
  Explode
  ArmorHit
  Pause
  Resume
  StageIntro
  GameOver
  BonusAppear
  BonusTaken
  HqExplode
}

///|
pub fn points(kind : TankKind) -> Int32 {
  match kind {
    Basic => 100
    Fast => 200
    Power => 300
    Armor => 400
  }
}

///|
pub fn enemy_speed(kind : TankKind) -> Int32 {
  match kind {
    Basic => 2
    Fast => 4
    Power => 2
    Armor => 1
  }
}

///|
pub fn enemy_hp(kind : TankKind) -> Int32 {
  match kind {
    Armor => 4
    _ => 1
  }
}

///|
pub fn enemy_name(kind : TankKind) -> String {
  match kind {
    Basic => "普通"
    Fast => "快速"
    Power => "火力"
    Armor => "装甲"
  }
}

///|
pub fn power_name(kind : PowerKind) -> String {
  match kind {
    Star => "星"
    Helmet => "护盾"
    Shovel => "铁锹"
    Clock => "时钟"
    Grenade => "手雷"
    Life => "坦克"
  }
}

///|
pub fn power_kind(idx : Int32) -> PowerKind {
  let i = (idx % 6 + 6) % 6
  match i {
    0 => Star
    1 => Helmet
    2 => Shovel
    3 => Clock
    4 => Grenade
    _ => Life
  }
}

///|
pub(all) struct Tank {
  mut x : Int32
  mut y : Int32
  mut dir : Dir
  speed : Int32
  kind : TankKind
  mut hp : Int32
  mut alive : Bool
  mut shoot_cd : Int32
  mut move_cd : Int32
  mut frozen : Bool
  mut spawn_anim : Int32
  // 亚像素进度（1/10 像素）：速度 70% 后 2px/帧 → 1.4px/帧，整数像素装不下，
  // 用余数累积——每帧 acc += 速度×7，整数步 = acc/10，余数留下帧。
  mut speed_acc : Int32
}

///|
pub(all) struct Player {
  mut x : Int32
  mut y : Int32
  mut dir : Dir
  mut alive : Bool
  mut moving : Bool
  mut star : Int32
  mut shield : Int32
  mut respawn : Int32
  mut speed_acc : Int32
}

///|
pub(all) struct Bullet {
  mut x : Int32
  mut y : Int32
  dir : Dir
  speed : Int32
  from_player : Bool
  power : Bool
}

///|
pub(all) struct Power {
  x : Int32
  y : Int32
  kind : PowerKind
  life : Int32
}

///|
pub(all) struct Game {
  mut state : State
  mut stage : Int32
  mut score : Int32
  mut hi : Int32
  mut lives : Int32
  mut spawned : Int32
  mut destroyed : Int32
  mut spawn_timer : Int32
  grid : Array[Array[Terrain]]
  mut player : Player
  mut enemies : Array[Tank]
  mut bullets : Array[Bullet]
  mut powers : Array[Power]
  mut spawn_queue : Array[TankKind]
  mut power_cycle : Int32
  mut freeze_t : Int32
  mut shovel_t : Int32
  mut state_t : Int32
  mut eagle_alive : Bool
  mut frame : Int32
  mut seed : Int64
  mut extra_life : Bool
  mut paused : Bool
  // 音效队列：规则层 push，UI 层每帧排空（`Sfx` 见上）。
  mut sfx_queue : Array[Sfx]
  // 输入保持态（哪几个方向键按着）：放在规则层是为了让同一帧内
  // "按方向键 → tick 前进" 的先后顺序可复现，不依赖 UI 层的闭包捕获。
  mut key_left : Bool
  mut key_right : Bool
  mut key_up : Bool
  mut key_down : Bool
}

///|
fn cell_solid(t : Terrain) -> Bool {
  match t {
    Brick | Steel | Water => true
    _ => false
  }
}

///|
fn box_overlap(
  ax : Int32,
  ay : Int32,
  aw : Int32,
  ah : Int32,
  bx : Int32,
  by : Int32,
  bw : Int32,
  bh : Int32,
) -> Bool {
  ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah
}

///|
fn imin(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn Game::rnd(self : Game) -> Int64 {
  self.seed = self.seed * 48271L % 2147483647L
  self.seed
}

///|
fn Game::rnd_range(self : Game, n : Int32) -> Int32 {
  let r = self.rnd()
  if n <= 0 {
    0
  } else {
    (r % n.to_int64()).to_int()
  }
}

///|
fn Game::cell_at(self : Game, cx : Int32, cy : Int32) -> Terrain {
  if cx < 0 || cy < 0 || cx >= CELLS || cy >= CELLS {
    return Empty
  }
  self.grid[cy][cx]
}

///|
fn Game::set_cell(self : Game, cx : Int32, cy : Int32, t : Terrain) -> Unit {
  if cx >= 0 && cy >= 0 && cx < CELLS && cy < CELLS {
    self.grid[cy][cx] = t
  }
}

///|
/// 坦克 16×16 在 (x,y) 是否被挡（地形 / 老鹰 / 其他坦克）。
/// `ignore_enemy` = 要跳过的敌坦克下标（-1 = 不跳过任何敌），
/// `ignore_player` = 是否跳过玩家自己（移动玩家时为 true）。
fn Game::tank_blocked(
  self : Game,
  x : Int32,
  y : Int32,
  ignore_enemy : Int32,
  ignore_player : Bool,
) -> Bool {
  if x < 0 || y < 0 || x > FIELD_PX - TANK_PX || y > FIELD_PX - TANK_PX {
    return true
  }
  let cx0 = x / CELL_PX
  let cy0 = y / CELL_PX
  let cx1 = (x + TANK_PX - 1) / CELL_PX
  let cy1 = (y + TANK_PX - 1) / CELL_PX
  for cy in cy0..<=cy1 {
    for cx in cx0..<=cx1 {
      if cell_solid(self.cell_at(cx, cy)) {
        return true
      }
    }
  }
  if box_overlap(x, y, TANK_PX, TANK_PX, EAGLE_X, EAGLE_Y, EAGLE_S, EAGLE_S) {
    return true
  }
  if !ignore_player && self.player.alive && self.player.respawn <= 0 {
    if box_overlap(
        x,
        y,
        TANK_PX,
        TANK_PX,
        self.player.x,
        self.player.y,
        TANK_PX,
        TANK_PX,
      ) {
      return true
    }
  }
  for i in 0..<self.enemies.length() {
    if i == ignore_enemy {
      continue
    }
    let e = self.enemies[i]
    if e.alive && e.spawn_anim <= 0 {
      if box_overlap(x, y, TANK_PX, TANK_PX, e.x, e.y, TANK_PX, TANK_PX) {
        return true
      }
    }
  }
  false
}

///|
/// 坦克 (x,y) 正下方是否踩着冰面（打滑用）。
fn Game::on_ice(self : Game, x : Int32, y : Int32) -> Bool {
  let cx0 = x / CELL_PX
  let cy0 = y / CELL_PX
  let cx1 = (x + TANK_PX - 1) / CELL_PX
  let cy1 = (y + TANK_PX - 1) / CELL_PX
  for cy in cy0..<=cy1 {
    for cx in cx0..<=cx1 {
      if self.cell_at(cx, cy) == Ice {
        return true
      }
    }
  }
  false
}

///|
/// 逐像素移动敌坦克（最多 `steps` 步，遇挡即停）。返回是否真的动了。
fn Game::move_enemy(self : Game, i : Int32, steps : Int32) -> Bool {
  let d = self.enemies[i].dir
  let (dx, dy) = dir_vec(d)
  let mut moved = false
  for _s in 0..<steps {
    let nx = self.enemies[i].x + dx
    let ny = self.enemies[i].y + dy
    if self.tank_blocked(nx, ny, i, false) {
      break
    }
    self.enemies[i].x = nx
    self.enemies[i].y = ny
    moved = true
  }
  moved
}

///|
/// 玩家坦克速度 70% 后是 1.4px/帧（原 2px/帧）。整数像素装不下，用 1/10 像素
/// 累积：每帧 acc += 速度×10×0.7 = 速度×7，整数步 = acc/10，余数留在 acc。
fn advance_acc(acc : Int32, speed_tenths : Int32) -> (Int32, Int32) {
  let a = acc + speed_tenths
  (a / 10, a % 10)
}

///|
/// 逐像素移动玩家坦克。返回实际移动的像素数（被墙挡住会少于 steps）。
fn Game::move_player(self : Game, steps : Int32) -> Int32 {
  let d = self.player.dir
  let (dx, dy) = dir_vec(d)
  let mut moved = 0
  for _s in 0..<steps {
    let nx = self.player.x + dx
    let ny = self.player.y + dy
    if self.tank_blocked(nx, ny, -1, true) {
      break
    }
    self.player.x = nx
    self.player.y = ny
    moved += 1
  }
  moved
}

///|
/// 关卡地图：13×13 块（每行一条 `Bytes`），字符含义 `.`空 `#`砖 `%`钢
/// `~`水 `*`树 `_`冰。
fn map_rows(stage : Int32) -> Array[Bytes] {
  match stage {
    2 =>
      [
        b".............", b"..#...#...#..", b"..#.%.#.%.#..", b"..#...#...#..", b".............",
        b"....#.#.#....", b"....#.#.#....", b"....#.#.#....", b".............", b"...##...##...",
        b"...##...##...", b".............", b".............",
      ]
    3 =>
      [
        b".............", b"..#..*.*..#..", b"..#.*...#.*..", b"....*.*.*....", b"....#...#....",
        b"....#...#....", b"....*.*.*....", b"..#.*...#.*..", b"..#..*.*..#..", b".............",
        b".............", b".............", b".............",
      ]
    4 =>
      [
        b".............", b"..#...#...#..", b"..#.%...%.#..", b"..#...#...#..", b"...._._._....",
        b"...._._._....", b"...._._._....", b"..#...#...#..", b"..#.%...%.#..", b"..#...#...#..",
        b".............", b".............", b".............",
      ]
    _ =>
      [
        b".............", b"..#.......#..", b"..#..###..#..", b"..#..#.#..#..", b"..#..#.#..#..",
        b"..#..###..#..", b".............", b"....##.##....", b"...~~...~~...", b"...~~...~~...",
        b".............", b".............", b".............",
      ]
  }
}

///|
fn map_cell(ch : Byte) -> Terrain {
  if ch == b'#' {
    Brick
  } else if ch == b'%' {
    Steel
  } else if ch == b'~' {
    Water
  } else if ch == b'*' {
    Tree
  } else if ch == b'_' {
    Ice
  } else {
    Empty
  }
}

///|
fn Game::build_map(self : Game, stage : Int32) -> Unit {
  let rows = map_rows(stage)
  for ty in 0..<FIELD_TILES {
    let row = if ty < rows.length() { rows[ty] } else { b"............." }
    for tx in 0..<FIELD_TILES {
      let ch = if tx < row.length() { row.at(tx) } else { b'.' }
      let t = map_cell(ch)
      // 一块 16×16 铺成 2×2 个 8×8 子块
      for sy in 0..<2 {
        for sx in 0..<2 {
          self.set_cell(tx * 2 + sx, ty * 2 + sy, t)
        }
      }
    }
  }
  // 基地周边清空，再放 U 形砖墙与老鹰（防止地图内容与基地打架）
  for ty in 10..<13 {
    for tx in 4..<10 {
      for sy in 0..<2 {
        for sx in 0..<2 {
          self.set_cell(tx * 2 + sx, ty * 2 + sy, Empty)
        }
      }
    }
  }
  // 顶墙 (5,10)(6,10)(7,10)(8,10)，侧墙 (5,11)(5,12)(8,11)(8,12)
  self.set_tile(5, 10, Brick)
  self.set_tile(6, 10, Brick)
  self.set_tile(7, 10, Brick)
  self.set_tile(8, 10, Brick)
  self.set_tile(5, 11, Brick)
  self.set_tile(5, 12, Brick)
  self.set_tile(8, 11, Brick)
  self.set_tile(8, 12, Brick)
  // 敌方三个出生点清空
  self.set_tile(0, 0, Empty)
  self.set_tile(6, 0, Empty)
  self.set_tile(12, 0, Empty)
  // 玩家出生点清空
  self.set_tile(4, 12, Empty)
}

///|
fn Game::set_tile(self : Game, tx : Int32, ty : Int32, t : Terrain) -> Unit {
  for sy in 0..<2 {
    for sx in 0..<2 {
      self.set_cell(tx * 2 + sx, ty * 2 + sy, t)
    }
  }
}

///|
fn Game::tile_open(self : Game, tx : Int32, ty : Int32) -> Bool {
  if tx < 0 || ty < 0 || tx >= FIELD_TILES || ty >= FIELD_TILES {
    return false
  }
  let px = tx * TILE_PX
  let py = ty * TILE_PX
  if box_overlap(px, py, TANK_PX, TANK_PX, EAGLE_X, EAGLE_Y, EAGLE_S, EAGLE_S) {
    return false
  }
  for sy in 0..<2 {
    for sx in 0..<2 {
      let t = self.cell_at(tx * 2 + sx, ty * 2 + sy)
      if cell_solid(t) {
        return false
      }
    }
  }
  true
}

///|
fn build_queue(stage : Int32) -> Array[TankKind] {
  // 原始版的常驻构成：普通×4、快速×4、火力×4、装甲×8，共 20 辆。
  // 高关卡让装甲提前进场，增加后期压力。
  let early = if stage >= 3 { 2 } else if stage >= 5 { 4 } else { 0 }
  let q : Array[TankKind] = []
  for _ in 0..<early {
    q.push(Armor)
  }
  for _ in 0..<(4 - early + early) {
    q.push(Basic)
  }
  for _ in 0..<4 {
    q.push(Fast)
  }
  for _ in 0..<4 {
    q.push(Power)
  }
  for _ in 0..<8 {
    q.push(Armor)
  }
  q
}

///|
fn Game::reset_level(self : Game, stage : Int32) -> Unit {
  self.stage = stage
  self.build_map(stage)
  self.spawn_queue = build_queue(stage)
  self.player = Player::{
    x: PLAYER_SPAWN_X,
    y: PLAYER_SPAWN_Y,
    dir: Up,
    alive: true,
    moving: false,
    star: 0,
    shield: 0,
    respawn: 0,
    speed_acc: 0,
  }
  self.enemies = []
  self.bullets = []
  self.powers = []
  self.spawned = 0
  self.destroyed = 0
  self.spawn_timer = 40
  self.power_cycle = 0
  self.freeze_t = 0
  self.shovel_t = 0
  self.eagle_alive = true
  self.paused = false
  self.key_left = false
  self.key_right = false
  self.key_up = false
  self.key_down = false
  self.state = StageIntro
  self.state_t = 90
  self.sfx_queue.push(StageIntro)
}

///|
pub fn Game::new(seed : Int32) -> Game {
  let grid : Array[Array[Terrain]] = []
  for _y in 0..<CELLS {
    let row : Array[Terrain] = []
    for _x in 0..<CELLS {
      row.push(Empty)
    }
    grid.push(row)
  }
  let g = Game::{
    state: Attract,
    stage: 1,
    score: 0,
    hi: 0,
    lives: 3,
    spawned: 0,
    destroyed: 0,
    spawn_timer: 0,
    grid,
    player: Player::{
      x: PLAYER_SPAWN_X,
      y: PLAYER_SPAWN_Y,
      dir: Up,
      alive: false,
      moving: false,
      star: 0,
      shield: 0,
      respawn: 0,
      speed_acc: 0,
    },
    enemies: [],
    bullets: [],
    powers: [],
    spawn_queue: [],
    power_cycle: 0,
    freeze_t: 0,
    shovel_t: 0,
    state_t: 0,
    eagle_alive: true,
    frame: 0,
    seed: seed.to_int64(),
    extra_life: false,
    paused: false,
    sfx_queue: [],
    key_left: false,
    key_right: false,
    key_up: false,
    key_down: false,
  }
  g
}

///|
/// 开始新一局：回到第 1 关，分数/生命清零。
pub fn Game::start_new_game(self : Game) -> Unit {
  self.stage = 1
  self.score = 0
  self.lives = 3
  self.extra_life = false
  self.reset_level(1)
}

///|
pub fn Game::toggle_pause(self : Game) -> Unit {
  if self.state == Playing {
    self.paused = !self.paused
    self.sfx_queue.push(if self.paused { Pause } else { Resume })
  }
}

///|
/// 输入方向：`dir` 0=上 1=下 2=左 3=右，-1=保持当前；`moving` 是否按住方向键。
pub fn Game::player_input(self : Game, dir : Int32, moving : Bool) -> Unit {
  if self.state != Playing || self.paused {
    return
  }
  if dir >= 0 {
    self.player.dir = code_dir(dir)
  }
  self.player.moving = moving
}

///|
pub fn Game::player_shoot(self : Game) -> Unit {
  if self.state != Playing || self.paused {
    return
  }
  let p = self.player
  if !p.alive || p.respawn > 0 {
    return
  }
  let max = if p.star >= 2 { 2 } else { 1 }
  if self.count_player_bullets() >= max {
    return
  }
  let (dx, dy) = dir_vec(p.dir)
  let bx = p.x + 8 + dx * 12 - BULLET_PX / 2
  let by = p.y + 8 + dy * 12 - BULLET_PX / 2
  let speed = if p.star >= 1 { 5 } else { 4 }
  let power = p.star >= 3
  self.bullets.push(Bullet::{
    x: bx,
    y: by,
    dir: p.dir,
    speed,
    from_player: true,
    power,
  })
  self.sfx_queue.push(Shoot)
}

///|
fn Game::count_player_bullets(self : Game) -> Int32 {
  let mut n = 0
  for b in self.bullets {
    if b.from_player {
      n += 1
    }
  }
  n
}

///|
fn Game::count_enemy_bullets(self : Game) -> Int32 {
  let mut n = 0
  for b in self.bullets {
    if !b.from_player {
      n += 1
    }
  }
  n
}

///|
fn Game::enemy_shoot(self : Game, i : Int32) -> Unit {
  if self.count_enemy_bullets() >= 5 {
    return
  }
  let e = self.enemies[i]
  let (dx, dy) = dir_vec(e.dir)
  let bx = e.x + 8 + dx * 12 - BULLET_PX / 2
  let by = e.y + 8 + dy * 12 - BULLET_PX / 2
  self.bullets.push(Bullet::{
    x: bx,
    y: by,
    dir: e.dir,
    speed: 3,
    from_player: false,
    power: false,
  })
  self.sfx_queue.push(Shoot)
}

///|
fn Game::try_spawn(self : Game) -> Unit {
  if self.spawned >= 20 {
    return
  }
  // 场上存活敌数（含出场动画）
  let mut alive = 0
  for e in self.enemies {
    if e.alive {
      alive += 1
    }
  }
  if alive >= 4 {
    return
  }
  // 挑一个空的出生点
  let mut pick = -1
  for k in 0..<3 {
    let sx = spawn_x_at(k)
    let sy = 0
    let mut occ = false
    for e in self.enemies {
      if e.alive &&
        box_overlap(sx, sy, TANK_PX, TANK_PX, e.x, e.y, TANK_PX, TANK_PX) {
        occ = true
      }
    }
    if self.player.alive && self.player.respawn <= 0 {
      if box_overlap(
          sx,
          sy,
          TANK_PX,
          TANK_PX,
          self.player.x,
          self.player.y,
          TANK_PX,
          TANK_PX,
        ) {
        occ = true
      }
    }
    if !occ {
      pick = k
      break
    }
  }
  if pick < 0 {
    return
  }
  let kind = self.spawn_queue[self.spawned]
  self.spawned += 1
  self.enemies.push(Tank::{
    x: spawn_x_at(pick),
    y: 0,
    dir: Down,
    speed: enemy_speed(kind),
    kind,
    hp: enemy_hp(kind),
    alive: true,
    shoot_cd: 60 + self.rnd_range(60),
    move_cd: 30 + self.rnd_range(60),
    frozen: self.freeze_t > 0,
    spawn_anim: 60,
    speed_acc: 0,
  })
}

///|
fn Game::drop_power(self : Game, x : Int32, y : Int32) -> Unit {
  let kind = power_kind(self.power_cycle)
  self.power_cycle += 1
  // 从掉落点起往外找一块空 tile 放道具（原始版道具也会挪到能放的地方）
  let mut px = -1
  let mut py = -1
  let mut start_tx = x / TILE_PX
  if start_tx < 0 {
    start_tx = 0
  }
  if start_tx > FIELD_TILES - 1 {
    start_tx = FIELD_TILES - 1
  }
  let mut start_ty = y / TILE_PX
  if start_ty < 0 {
    start_ty = 0
  }
  if start_ty > FIELD_TILES - 1 {
    start_ty = FIELD_TILES - 1
  }
  for dy in 0..<FIELD_TILES {
    let ty = start_ty + dy
    if ty >= FIELD_TILES {
      break
    }
    for dx in 0..<FIELD_TILES {
      let tx = start_tx + dx
      if tx >= FIELD_TILES {
        break
      }
      if self.tile_open(tx, ty) {
        px = tx * TILE_PX
        py = ty * TILE_PX
      }
    }
    if px >= 0 {
      break
    }
  }
  if px < 0 {
    px = 96
    py = 0
  }
  self.powers.push(Power::{ x: px, y: py, kind, life: 600, })
  self.sfx_queue.push(BonusAppear)
}

///|
fn Game::apply_power(self : Game, kind : PowerKind) -> Unit {
  match kind {
    Star => self.player.star = imin(3, self.player.star + 1)
    Helmet => self.player.shield = 240
    Shovel => {
      self.set_shovel(Steel)
      self.shovel_t = 1200
    }
    Clock => {
      self.freeze_t = 600
      for i in 0..<self.enemies.length() {
        self.enemies[i].frozen = true
      }
    }
    Grenade => {
      let n = self.enemies.length()
      for i in 0..<n {
        if self.enemies[i].alive && self.enemies[i].spawn_anim <= 0 {
          self.hit_enemy(i, true)
        }
      }
    }
    Life => self.lives = imin(9, self.lives + 1)
  }
}

///|
/// 基地周边八块砖：顶(5..8,10)、左(5,11..12)、右(8,11..12)。
fn Game::set_shovel(self : Game, t : Terrain) -> Unit {
  self.set_tile(5, 10, t)
  self.set_tile(6, 10, t)
  self.set_tile(7, 10, t)
  self.set_tile(8, 10, t)
  self.set_tile(5, 11, t)
  self.set_tile(5, 12, t)
  self.set_tile(8, 11, t)
  self.set_tile(8, 12, t)
}

///|
/// 击毁/击伤敌坦克。`no_drop` = 不落道具（手雷清屏不算）。
fn Game::hit_enemy(self : Game, i : Int32, no_drop : Bool) -> Unit {
  if !self.enemies[i].alive {
    return
  }
  if self.enemies[i].spawn_anim > 0 {
    return
  }
  let hp = self.enemies[i].hp
  if hp > 1 {
    self.enemies[i].hp = hp - 1
    self.sfx_queue.push(ArmorHit)
    return
  }
  self.enemies[i].alive = false
  self.sfx_queue.push(Explode)
  let kind = self.enemies[i].kind
  self.score += points(kind)
  if self.score > self.hi {
    self.hi = self.score
  }
  if !self.extra_life && self.score >= 20000 {
    self.extra_life = true
    self.lives = imin(9, self.lives + 1)
  }
  self.destroyed += 1
  if !no_drop && self.destroyed % 4 == 0 {
    self.drop_power(self.enemies[i].x, self.enemies[i].y)
  }
}

///|
fn Game::hit_player(self : Game) -> Unit {
  if !self.player.alive || self.player.respawn > 0 {
    return
  }
  if self.player.shield > 0 {
    return
  }
  self.player.alive = false
  self.lives -= 1
  self.sfx_queue.push(Explode)
  if self.lives <= 0 {
    self.state = GameOver
    self.state_t = 120
    self.sfx_queue.push(GameOver)
  } else {
    self.player.respawn = 90
  }
}

///|
fn Game::eagle_hit(self : Game) -> Unit {
  if !self.eagle_alive {
    return
  }
  self.eagle_alive = false
  self.state = GameOver
  self.state_t = 120
  self.sfx_queue.push(HqExplode)
  self.sfx_queue.push(GameOver)
}

///|
fn Game::respawn_player(self : Game) -> Unit {
  self.player.x = PLAYER_SPAWN_X
  self.player.y = PLAYER_SPAWN_Y
  self.player.dir = Up
  self.player.alive = true
  self.player.star = 0
  self.player.shield = 180
  self.player.moving = false
  self.set_tile(4, 12, Empty)
  self.set_tile(3, 12, Empty)
}

///|
/// 子弹在候选位置 (nx, ny) 的碰撞判定：返回 true=继续飞，false=消亡。
/// 不修改子弹本身（位置由调用方写回数组）。
fn Game::bullet_step(self : Game, b : Bullet, nx : Int32, ny : Int32) -> Bool {
  if nx < 0 || ny < 0 || nx > FIELD_PX - BULLET_PX || ny > FIELD_PX - BULLET_PX {
    return false
  }
  let (dx, dy) = dir_vec(b.dir)
  // 用弹尖（前缘）所在的 8×8 子块判地形，子弹不会"隔块"碎砖
  let fx = nx + dx * (BULLET_PX / 2)
  let fy = ny + dy * (BULLET_PX / 2)
  let cx = fx / CELL_PX
  let cy = fy / CELL_PX
  let t = self.cell_at(cx, cy)
  if t == Brick {
    self.set_cell(cx, cy, Empty)
    self.sfx_queue.push(HitWall)
    return false
  }
  if t == Steel {
    if b.power {
      self.set_cell(cx, cy, Empty)
    }
    self.sfx_queue.push(HitWall)
    return false
  }
  // 老鹰
  if box_overlap(
      nx,
      ny,
      BULLET_PX,
      BULLET_PX,
      EAGLE_X,
      EAGLE_Y,
      EAGLE_S,
      EAGLE_S,
    ) {
    self.eagle_hit()
    return false
  }
  // 坦克
  if b.from_player {
    for i in 0..<self.enemies.length() {
      let e = self.enemies[i]
      if e.alive && e.spawn_anim <= 0 {
        if box_overlap(nx, ny, BULLET_PX, BULLET_PX, e.x, e.y, TANK_PX, TANK_PX) {
          self.hit_enemy(i, false)
          return false
        }
      }
    }
  } else if self.player.alive && self.player.respawn <= 0 {
    if box_overlap(
        nx,
        ny,
        BULLET_PX,
        BULLET_PX,
        self.player.x,
        self.player.y,
        TANK_PX,
        TANK_PX,
      ) {
      self.hit_player()
      return false
    }
  }
  true
}

///|
fn Game::tick_bullets(self : Game) -> Unit {
  let n = self.bullets.length()
  if n == 0 {
    return
  }
  let dead : Array[Bool] = []
  for _ in 0..<n {
    dead.push(false)
  }
  for i in 0..<n {
    if dead[i] {
      continue
    }
    let b = self.bullets[i]
    let (dx, dy) = dir_vec(b.dir)
    let mut alive = true
    // 先查本帧起点：子弹出生时弹尖可能已经贴着一块砖/钢板（炮口抵墙），
    // 只查"移动后"的新位置会漏掉这一格——子弹穿墙。逐像素移动 + 起点判定
    // 一起保证任何 8×8 子块都不会被跳过。
    if self.bullet_step(b, self.bullets[i].x, self.bullets[i].y) {
      for _s in 0..<b.speed {
        let nx = self.bullets[i].x + dx
        let ny = self.bullets[i].y + dy
        if self.bullet_step(b, nx, ny) {
          self.bullets[i].x = nx
          self.bullets[i].y = ny
        } else {
          alive = false
          break
        }
      }
    } else {
      alive = false
    }
    if !alive {
      dead[i] = true
    }
  }
  // 玩家弹 vs 敌弹：对撞抵消
  for i in 0..<n {
    if dead[i] {
      continue
    }
    let bi = self.bullets[i]
    for j in 0..<n {
      if i == j || dead[j] {
        continue
      }
      let bj = self.bullets[j]
      if bi.from_player != bj.from_player {
        if box_overlap(
            bi.x,
            bi.y,
            BULLET_PX,
            BULLET_PX,
            bj.x,
            bj.y,
            BULLET_PX,
            BULLET_PX,
          ) {
          dead[i] = true
          dead[j] = true
        }
      }
    }
  }
  let keep : Array[Bullet] = []
  for i in 0..<n {
    if !dead[i] {
      keep.push(self.bullets[i])
    }
  }
  self.bullets = keep
}

///|
fn Game::tick_enemy(self : Game, i : Int32) -> Unit {
  if !self.enemies[i].alive {
    return
  }
  if self.enemies[i].spawn_anim > 0 {
    self.enemies[i].spawn_anim -= 1
    return
  }
  if self.enemies[i].frozen {
    return
  }
  // 随机改向（冰面上不打滑改向）
  if !self.on_ice(self.enemies[i].x, self.enemies[i].y) {
    if self.enemies[i].move_cd > 0 {
      self.enemies[i].move_cd -= 1
    } else {
      let r = self.rnd_range(100)
      if r < 35 {
        self.enemies[i].dir = Down
      } else if r < 60 {
        self.enemies[i].dir = Left
      } else if r < 85 {
        self.enemies[i].dir = Right
      } else {
        self.enemies[i].dir = Up
      }
      self.enemies[i].move_cd = 60 + self.rnd_range(120)
    }
  }
  // 移动；速度 70%（Basic 2→1.4 / Fast 4→2.8 / Power 2→1.4 / Armor 1→0.7 px/帧）
  // 用亚像素累积，`enemy_speed` 仍是原始整数口径。
  let (steps, rem) = advance_acc(
    self.enemies[i].speed_acc,
    self.enemies[i].speed * ENEMY_SPEED_SCALE,
  )
  self.enemies[i].speed_acc = rem
  let mut moved = false
  if steps > 0 {
    moved = self.move_enemy(i, steps)
  }
  if !moved {
    // 撞墙立即换向，优先往下；累积清零，别让"解挡后瞬间冲出去"
    self.enemies[i].speed_acc = 0
    let r = self.rnd_range(100)
    if r < 55 {
      self.enemies[i].dir = Down
    } else if r < 75 {
      self.enemies[i].dir = Left
    } else if r < 95 {
      self.enemies[i].dir = Right
    } else {
      self.enemies[i].dir = Up
    }
    self.enemies[i].move_cd = 30 + self.rnd_range(60)
  }
  // 开火
  if self.enemies[i].shoot_cd > 0 {
    self.enemies[i].shoot_cd -= 1
  } else {
    let kind = self.enemies[i].kind
    let fast = kind == Power
    if fast || self.rnd_range(100) < 40 {
      self.enemy_shoot(i)
    }
    if fast {
      self.enemies[i].shoot_cd = 40 + self.rnd_range(45)
    } else {
      self.enemies[i].shoot_cd = 90 + self.rnd_range(90)
    }
  }
}

///|
fn Game::spawn_clear(self : Game) -> Bool {
  for e in self.enemies {
    if e.alive &&
      box_overlap(
        PLAYER_SPAWN_X,
        PLAYER_SPAWN_Y,
        TANK_PX,
        TANK_PX,
        e.x,
        e.y,
        TANK_PX,
        TANK_PX,
      ) {
      return false
    }
  }
  true
}

///|
fn Game::tick_player(self : Game) -> Unit {
  let p = self.player
  if p.respawn > 0 {
    self.player.respawn -= 1
    if self.player.respawn == 0 {
      // 出生点被敌方坦克压住就再等等——直接复活会跟它叠死在一起
      if self.spawn_clear() {
        self.respawn_player()
      } else {
        self.player.respawn = 20
      }
    }
    return
  }
  if !p.alive {
    return
  }
  if p.shield > 0 {
    self.player.shield -= 1
  }
  // 按住方向键或踩冰（打滑）都前进；速度 70%（1.4px/帧）用亚像素累积。
  if p.moving || self.on_ice(p.x, p.y) {
    let (steps, rem) = advance_acc(self.player.speed_acc, PLAYER_SPEED_TENTHS)
    self.player.speed_acc = rem
    let mut moved_px = 0
    if steps > 0 {
      moved_px = self.move_player(steps)
      if moved_px < steps {
        // 被墙挡住：清掉累积，别让"解挡后瞬间冲出去"
        self.player.speed_acc = 0
      }
    }
    // 履带声：真在动才响，每 8 帧一响（0.10s 短音重叠成连续震）
    if moved_px > 0 && self.frame % 8 == 0 {
      self.sfx_queue.push(Move)
    }
  }
}

///|
fn Game::tick_powers(self : Game) -> Unit {
  let keep : Array[Power] = []
  for p in self.powers {
    if p.life <= 1 {
      continue
    }
    if self.player.alive && self.player.respawn <= 0 {
      if box_overlap(
          self.player.x,
          self.player.y,
          TANK_PX,
          TANK_PX,
          p.x,
          p.y,
          TANK_PX,
          TANK_PX,
        ) {
        self.apply_power(p.kind)
        self.sfx_queue.push(BonusTaken)
        continue
      }
    }
    keep.push(Power::{ x: p.x, y: p.y, kind: p.kind, life: p.life - 1, })
  }
  self.powers = keep
}

///|
fn Game::tick_playing(self : Game) -> Unit {
  // 计时器
  if self.freeze_t > 0 {
    self.freeze_t -= 1
    if self.freeze_t == 0 {
      for i in 0..<self.enemies.length() {
        self.enemies[i].frozen = false
      }
    }
  }
  if self.shovel_t > 0 {
    self.shovel_t -= 1
    if self.shovel_t == 0 {
      self.set_shovel(Brick)
    }
  }
  // 出生
  if self.spawn_timer > 0 {
    self.spawn_timer -= 1
  } else {
    self.try_spawn()
    self.spawn_timer = 150
  }
  // 玩家
  self.tick_player()
  // 敌 AI
  let n = self.enemies.length()
  for i in 0..<n {
    self.tick_enemy(i)
  }
  // 子弹
  self.tick_bullets()
  // 道具
  self.tick_powers()
  // 清理死亡敌人（手雷/子弹造成的延迟移除）
  let keep : Array[Tank] = []
  for e in self.enemies {
    if e.alive {
      keep.push(e)
    }
  }
  self.enemies = keep
  // 过关判定：出完且清空
  if self.spawned >= 20 && self.enemies.length() == 0 {
    self.state = StageClear
    self.state_t = 180
  }
}

///|
/// 一帧主更新。`dt` 毫秒（保留参数：速度按 60fps 定拍，不读真实时钟）。

///|
/// 排空音效队列并返回本帧应播的条目（main.mbt 每帧调用后播放）。
pub fn Game::drain_sfx(self : Game) -> Array[Sfx] {
  let q = self.sfx_queue
  self.sfx_queue = []
  q
}

///|
pub fn Game::tick(self : Game, _dt : Int32) -> Unit {
  self.frame += 1
  match self.state {
    Attract => ()
    StageIntro =>
      if self.state_t > 0 {
        self.state_t -= 1
        if self.state_t == 0 {
          self.state = Playing
        }
      }
    Playing => {
      if self.paused {
        return
      }
      self.tick_playing()
    }
    StageClear =>
      if self.state_t > 0 {
        self.state_t -= 1
        if self.state_t == 0 {
          self.reset_level(self.stage + 1)
        }
      }
    GameOver => if self.state_t > 0 { self.state_t -= 1 }
  }
}
