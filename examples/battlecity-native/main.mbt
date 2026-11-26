///|
/// 坦克大战（Battle City / Tank 1990）完整复刻示例——入口与渲染层。
///
/// 整窗只有一块自绘面，16ms 定拍一帧。逻辑全在 `game.mbt`（纯规则层），
/// 这里只做三件事：把战场画出来、把键盘翻译成规则输入、驱动 60fps 心跳。
///
/// `moon run examples/battlecity-native` 开真窗口；设 `BC_BENCH_MS=5000`
/// 则跑满 5 秒后自动打印一帧统计并退出，方便无人值守验证。
///
/// 操作：方向键移动，空格开火，Enter 开始/重开，P 或 Esc 暂停，R 重开。

///|
/// 屏幕坐标换算：把战场"格"（0..208 逻辑战场像素）放大到窗口。
struct View {
  s : Double
  ox : Double
  oy : Double
}

///|
/// 坦克调色板：角色 `T`履带 `B`车身 `D`车身暗 `L`车身亮 `G`炮管。
struct TankPal {
  track : Int32
  body : Int32
  dark : Int32
  light : Int32
  gun : Int32
}

///|
/// NES 2C02 PPU 调色板 → 显示 RGB（标准表）。素材对齐原版：地形/坦克/老鹰/
/// 子弹/道具一律用这些 NES 原色（`$xx` 是 PPU 索引），不用手调近似值。
/// 索引取自 `Battle City (J).asm` 的 `SpritePalette`（精灵四组）与
/// `LevelPalette`（背景四组）：0=金(玩家) 1=绿 2=银 3=红；背景 0=砖 1=水
/// 2=树 3=钢。映射到 2C02→RGB 即实际屏幕色。
const NES_BLACK : Int32 = 0x000000 // $00 黑

///|
const NES_RED_DARK : Int32 = 0x540400 // $06 暗红

///|
const NES_GREEN_DARK : Int32 = 0x083A00 // $09 树暗绿

///|
const NES_GREEN_DEEP : Int32 = 0x004000 // $0A 绿坦克暗

///|
const NES_GREEN_MID : Int32 = 0x003C00 // $0B 树中绿

///|
const NES_SILVER_DARK : Int32 = 0x00323C // $0C 银暗（暗青）

///|
const NES_SILVER : Int32 = 0x989696 // $10 银

///|
const NES_BLUE : Int32 = 0x3032EC // $12 水蓝

///|
const NES_RED : Int32 = 0x982220 // $16 砖红

///|
const NES_GOLD_DARK : Int32 = 0x545A00 // $18 金暗

///|
const NES_GREEN : Int32 = 0x007628 // $1B 绿坦克

///|
const NES_WHITE : Int32 = 0xECEEEC // $20 白

///|
const NES_RED_LIGHT : Int32 = 0xEC6C54 // $26 亮红

///|
const NES_GOLD : Int32 = 0xC88E00 // $27 金

///|
const NES_TREE : Int32 = 0x64C000 // $29 树绿

///|
const NES_GOLD_LIGHT : Int32 = 0xCCD278 // $38 亮金

///|
const NES_GREEN_LIGHT : Int32 = 0x80DE90 // $3B 亮绿

///|
const NES_CYAN : Int32 = 0x60C8B8 // $3C 水光

///|
/// 朝上的坦克 16×16 点阵（其余三个方向在绘制时按 90° 旋转，不另存三份）。
let tank_up : Array[Bytes] = [
  b".......GG.......", b".......GG.......", b".......GG.......", b"....LLLLLLLL....",
  b"...LBBBBBBBBL...", b"...LBBBBBBBBL...", b"...LBBBBBBBBL...", b"TT.LBBBBBBBBL.TT",
  b"TT.LBBBBBBBBL.TT", b"TT.LBBBBBBBBL.TT", b"TT.LBBBBBBBBL.TT", b"TT.LDDDDDDDDL.TT",
  b"TT.LDDDDDDDDL.TT", b"TT.LDDDDDDDDL.TT", b"TT..DDDDDDDD..TT", b"................",
]

///|
/// 老鹰徽记 8×8（绘制时按 3× 放大到 24px，居中在 32px 基地里）。
let eagle_sprite : Array[Bytes] = [
  b"..E..E..", b".EEEEEE.", b"EEEEEEEE", b"EEEEEEEE", b".EEEEEE.", b"..EEEE..", b"...EE...",
  b"........",
]

///|
/// 五角星外/内顶点（以中心为原点，外接半径 7 / 内接 3.2），用于道具图标。
let star_pts : Array[(Double, Double)] = [
  (0.0, -7.0),
  (1.88, -2.59),
  (6.66, -2.16),
  (3.04, 0.99),
  (4.11, 5.66),
  (0.0, 3.2),
  (-4.11, 5.66),
  (-3.04, 0.99),
  (-6.66, -2.16),
  (-1.88, -2.59),
]

///|
fn fmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// 战场矩形填充：坐标/尺寸都是战场"格"，内部换算到屏幕。
fn fill(
  dl : @moonui.DrawList,
  v : View,
  fx : Double,
  fy : Double,
  fw : Double,
  fh : Double,
  rgb : Int32,
  alpha : Int32,
) -> Unit {
  dl.fill_rect(
    v.ox + fx * v.s,
    v.oy + fy * v.s,
    fw * v.s,
    fh * v.s,
    radius=0.0,
    rgb~,
    alpha~,
  )
}

///|
fn tank_pal(kind : TankKind, hp : Int32, player : Bool) -> TankPal {
  if player {
    // 原版玩家坦克 = 金（SpritePalette 0：$18/$27/$38）。
    return TankPal::{
      track: NES_GOLD_DARK,
      body: NES_GOLD,
      dark: NES_GOLD_DARK,
      light: NES_GOLD_LIGHT,
      gun: NES_WHITE,
    }
  }
  match kind {
    Power =>
      // 原版火力坦克 = 绿（SpritePalette 1：$A/$1B/$3B）。
      TankPal::{
        track: NES_GREEN_DEEP,
        body: NES_GREEN,
        dark: NES_GREEN_DEEP,
        light: NES_GREEN_LIGHT,
        gun: NES_WHITE,
      }
    Armor =>
      if hp >= 4 {
        // 满血装甲 = 银（SpritePalette 2：$C/$10/$20）。
        TankPal::{
          track: NES_SILVER_DARK,
          body: NES_SILVER,
          dark: NES_SILVER_DARK,
          light: NES_WHITE,
          gun: NES_WHITE,
        }
      } else if hp == 3 {
        TankPal::{
          track: NES_RED_DARK,
          body: NES_RED,
          dark: NES_RED_DARK,
          light: NES_RED_LIGHT,
          gun: NES_WHITE,
        }
      } else if hp == 2 {
        TankPal::{
          track: NES_BLACK,
          body: NES_RED_DARK,
          dark: NES_BLACK,
          light: NES_RED,
          gun: NES_WHITE,
        }
      } else {
        TankPal::{
          track: NES_BLACK,
          body: NES_SILVER,
          dark: NES_BLACK,
          light: NES_WHITE,
          gun: NES_WHITE,
        }
      }
    _ =>
      // 普通/快速 = 银（SpritePalette 2）。
      TankPal::{
        track: NES_SILVER_DARK,
        body: NES_SILVER,
        dark: NES_SILVER_DARK,
        light: NES_WHITE,
        gun: NES_WHITE,
      }
  }
}

///|
fn pal_color(c : Byte, pal : TankPal) -> Int32 {
  if c == b'T' {
    pal.track
  } else if c == b'B' {
    pal.body
  } else if c == b'D' {
    pal.dark
  } else if c == b'L' {
    pal.light
  } else if c == b'G' {
    pal.gun
  } else {
    pal.body
  }
}

///|
/// 朝上点阵 (i,j) 旋转到朝向 `dir` 后的 (行,列)。
fn sprite_xy(dir : Dir, i : Int32, j : Int32, n : Int32) -> (Int32, Int32) {
  match dir {
    Up => (i, j)
    Right => (j, n - 1 - i)
    Down => (n - 1 - i, n - 1 - j)
    Left => (n - 1 - j, i)
  }
}

///|
/// 在战场 (fx, fy) 画一辆 16×16 坦克（fx/fy 是战场格，Int32 顶左角）。
fn draw_tank(
  dl : @moonui.DrawList,
  v : View,
  fx : Double,
  fy : Double,
  dir : Dir,
  pal : TankPal,
) -> Unit {
  let n = tank_up.length()
  for i in 0..<n {
    let row = tank_up[i]
    for j in 0..<n {
      let c = row.at(j)
      if c == b'.' {
        continue
      }
      let (di, dj) = sprite_xy(dir, i, j, n)
      dl.fill_rect(
        v.ox + (fx + dj.to_double()) * v.s,
        v.oy + (fy + di.to_double()) * v.s,
        v.s,
        v.s,
        radius=0.0,
        rgb=pal_color(c, pal),
        alpha=255,
      )
    }
  }
}

///|
/// 单色点阵精灵（老鹰 / 星形等）：每个 `E` 像素画 `scale`×`scale` 战场格。
fn draw_sprite_1c(
  dl : @moonui.DrawList,
  v : View,
  sp : Array[Bytes],
  fx : Double,
  fy : Double,
  scale : Double,
  color : Int32,
) -> Unit {
  let n = sp.length()
  for i in 0..<n {
    let row = sp[i]
    for j in 0..<n {
      if row.at(j) == b'.' {
        continue
      }
      dl.fill_rect(
        v.ox + (fx + j.to_double() * scale) * v.s,
        v.oy + (fy + i.to_double() * scale) * v.s,
        scale * v.s,
        scale * v.s,
        radius=0.0,
        rgb=color,
        alpha=255,
      )
    }
  }
}

///|
fn draw_cell(
  dl : @moonui.DrawList,
  v : View,
  cx : Int32,
  cy : Int32,
  t : Terrain,
  frame : Int32,
) -> Unit {
  let fx = (cx * CELL_PX).to_double()
  let fy = (cy * CELL_PX).to_double()
  match t {
    Empty => ()
    Brick => {
      // 砖 = 背景调色板红（$16 砖身 / $26 亮 / $06 暗缝）。
      fill(dl, v, fx, fy, 8.0, 8.0, NES_RED, 255)
      fill(dl, v, fx, fy + 4.0, 8.0, 1.0, NES_RED_DARK, 255)
      fill(dl, v, fx + 4.0, fy, 1.0, 4.0, NES_RED_DARK, 255)
      fill(dl, v, fx, fy + 5.0, 1.0, 3.0, NES_RED_DARK, 255)
      fill(dl, v, fx + 1.0, fy + 1.0, 3.0, 2.0, NES_RED_LIGHT, 255)
    }
    Steel => {
      // 钢 = 背景调色板银（$10 身 / $20 亮棱 / $00 暗缝）。
      fill(dl, v, fx, fy, 8.0, 8.0, NES_SILVER, 255)
      fill(dl, v, fx + 3.0, fy, 1.0, 8.0, NES_WHITE, 255)
      fill(dl, v, fx, fy + 3.0, 8.0, 1.0, NES_WHITE, 255)
      fill(dl, v, fx + 4.0, fy, 1.0, 8.0, NES_BLACK, 255)
      fill(dl, v, fx, fy + 4.0, 8.0, 1.0, NES_BLACK, 255)
    }
    Water => {
      // 水 = $12 蓝底 + $3C 青光闪（原版每帧换 palette 01 的闪烁）。
      fill(dl, v, fx, fy, 8.0, 8.0, NES_BLUE, 255)
      let ph = frame / 12 % 2
      fill(dl, v, fx + 1.0, fy + 2.0 + ph.to_double(), 4.0, 1.0, NES_CYAN, 255)
      fill(dl, v, fx + 4.0, fy + 6.0 - ph.to_double(), 3.0, 1.0, NES_CYAN, 255)
    }
    Tree => ()
    Ice => {
      // 冰 = 白（$20 底 / $20 亮 / $10 灰纹）。
      fill(dl, v, fx, fy, 8.0, 8.0, NES_WHITE, 255)
      fill(dl, v, fx + 1.0, fy + 1.0, 3.0, 1.0, NES_WHITE, 255)
      fill(dl, v, fx + 5.0, fy + 5.0, 2.0, 1.0, NES_SILVER, 255)
    }
  }
}

///|
fn draw_tree_cell(
  dl : @moonui.DrawList,
  v : View,
  cx : Int32,
  cy : Int32,
) -> Unit {
  let fx = (cx * CELL_PX).to_double()
  let fy = (cy * CELL_PX).to_double()
  // 树 = 背景调色板绿（$29 树冠 / $09 暗 / $0B 中）。
  fill(dl, v, fx, fy, 8.0, 8.0, NES_GREEN_DARK, 255)
  fill(dl, v, fx + 1.0, fy + 1.0, 3.0, 2.0, NES_TREE, 255)
  fill(dl, v, fx + 4.0, fy + 3.0, 3.0, 3.0, NES_TREE, 255)
  fill(dl, v, fx + 2.0, fy + 6.0, 4.0, 1.0, NES_GREEN_MID, 255)
}

///|
fn draw_eagle(dl : @moonui.DrawList, v : View, g : Game) -> Unit {
  let x = EAGLE_X.to_double()
  let y = EAGLE_Y.to_double()
  fill(dl, v, x, y, 32.0, 32.0, NES_BLACK, 255)
  if !g.eagle_alive {
    // 被毁：一摊瓦砾（银灰）。
    fill(dl, v, x + 2.0, y + 16.0, 28.0, 14.0, NES_SILVER, 255)
    fill(dl, v, x + 6.0, y + 22.0, 8.0, 4.0, NES_BLACK, 255)
    fill(dl, v, x + 18.0, y + 24.0, 6.0, 4.0, NES_SILVER, 255)
    fill(dl, v, x + 12.0, y + 12.0, 4.0, 4.0, NES_WHITE, 255)
    return
  }
  // 旗杆
  fill(dl, v, x + 2.0, y + 3.0, 2.0, 24.0, NES_SILVER, 255)
  fill(dl, v, x + 4.0, y + 3.0, 7.0, 5.0, NES_GOLD, 255)
  // 徽记（居中，金）
  draw_sprite_1c(dl, v, eagle_sprite, x + 5.0, y + 6.0, 2.7, NES_GOLD)
}

///|
/// 出生点闪光：一个旋转的十字星。
fn draw_spawn_star(
  dl : @moonui.DrawList,
  v : View,
  fx : Double,
  fy : Double,
  frame : Int32,
) -> Unit {
  let cx = fx + 8.0
  let cy = fy + 8.0
  let ph = frame / 4 % 4
  let s = 3.0 + ph.to_double() * 2.0
  fill(dl, v, cx - s, cy - 0.5, s * 2.0, 1.0, NES_GOLD, 255)
  fill(dl, v, cx - 0.5, cy - s, 1.0, s * 2.0, NES_GOLD, 255)
  fill(dl, v, cx - s * 0.6, cy - s * 0.6, s * 1.2, 1.0, NES_GOLD_LIGHT, 255)
}

///|
fn draw_power(
  dl : @moonui.DrawList,
  v : View,
  p : Power,
  frame : Int32,
) -> Unit {
  // 寿命将尽时闪烁消失
  if p.life < 120 && frame / 6 % 2 == 0 {
    return
  }
  let x = p.x.to_double()
  let y = p.y.to_double()
  fill(dl, v, x, y, 16.0, 16.0, NES_BLACK, 240)
  fill(dl, v, x + 1.0, y + 1.0, 14.0, 14.0, NES_SILVER_DARK, 255)
  let cx = x + 8.0
  let cy = y + 8.0
  match p.kind {
    Star => {
      let pts : Array[(Double, Double)] = []
      for k in star_pts {
        let (px_, py_) = k
        pts.push((v.ox + (cx + px_) * v.s, v.oy + (cy + py_) * v.s))
      }
      dl.fill_polygon(pts, rgb=NES_GOLD, alpha=255)
    }
    Helmet => {
      let pts : Array[(Double, Double)] = [
        (v.ox + (x + 3.0) * v.s, v.oy + (y + 2.0) * v.s),
        (v.ox + (x + 13.0) * v.s, v.oy + (y + 2.0) * v.s),
        (v.ox + (x + 13.0) * v.s, v.oy + (y + 7.0) * v.s),
        (v.ox + (x + 8.0) * v.s, v.oy + (y + 14.0) * v.s),
        (v.ox + (x + 3.0) * v.s, v.oy + (y + 7.0) * v.s),
      ]
      dl.fill_polygon(pts, rgb=NES_SILVER, alpha=255)
      let inner : Array[(Double, Double)] = [
        (v.ox + (x + 5.0) * v.s, v.oy + (y + 4.0) * v.s),
        (v.ox + (x + 11.0) * v.s, v.oy + (y + 4.0) * v.s),
        (v.ox + (x + 11.0) * v.s, v.oy + (y + 7.0) * v.s),
        (v.ox + (x + 8.0) * v.s, v.oy + (y + 12.0) * v.s),
        (v.ox + (x + 5.0) * v.s, v.oy + (y + 7.0) * v.s),
      ]
      dl.fill_polygon(inner, rgb=NES_SILVER_DARK, alpha=255)
    }
    Shovel => {
      fill(dl, v, cx - 1.0, y + 2.0, 2.0, 8.0, NES_GOLD, 255)
      fill(dl, v, cx - 3.0, y + 10.0, 6.0, 4.0, NES_SILVER, 255)
      fill(dl, v, cx - 3.0, y + 10.0, 6.0, 1.0, NES_WHITE, 255)
    }
    Clock => {
      fill(dl, v, x + 3.0, y + 3.0, 10.0, 10.0, NES_WHITE, 255)
      dl.stroke_arc(
        v.ox + cx * v.s,
        v.oy + cy * v.s,
        4.2 * v.s,
        0.0,
        360.0,
        width=1.2 * v.s,
        rgb=NES_BLACK,
      )
      dl.line(
        v.ox + cx * v.s,
        v.oy + cy * v.s,
        v.ox + cx * v.s,
        v.oy + (cy - 3.0) * v.s,
        width=1.0 * v.s,
        rgb=NES_BLACK,
      )
      dl.line(
        v.ox + cx * v.s,
        v.oy + cy * v.s,
        v.ox + (cx + 3.0) * v.s,
        v.oy + cy * v.s,
        width=1.0 * v.s,
        rgb=NES_BLACK,
      )
    }
    Grenade => {
      fill(dl, v, x + 5.0, y + 5.0, 6.0, 8.0, NES_BLACK, 255)
      fill(dl, v, x + 5.0, y + 5.0, 6.0, 3.0, NES_SILVER_DARK, 255)
      fill(dl, v, x + 8.0, y + 3.0, 2.0, 2.0, NES_GOLD, 255)
      let ph = frame / 4 % 2
      fill(dl, v, x + 9.0, y + 2.0 - ph.to_double(), 2.0, 2.0, NES_GOLD, 255)
    }
    Life => draw_tank(dl, v, x, y, Up, tank_pal(Basic, 1, false))
  }
}

///|
/// 侧栏迷你坦克图标（屏幕坐标，直接用）。
fn draw_mini_tank(
  dl : @moonui.DrawList,
  x : Double,
  y : Double,
  s : Double,
  color : Int32,
) -> Unit {
  dl.fill_rect(x, y, s, s, radius=0.0, rgb=color, alpha=255)
  dl.fill_rect(
    x + s * 0.3,
    y,
    s * 0.4,
    s * 0.4,
    radius=0.0,
    rgb=0x0B0E15,
    alpha=255,
  )
}

///|
fn text_center(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  text : String,
  cx : Double,
  y : Double,
  size : Double,
  bold : Bool,
  rgb : Int32,
) -> Unit {
  let (tw, _) = env.measure_text(text, size, bold)
  dl.text(text, cx - tw / 2.0, y, size~, bold~, rgb~)
}

///|
/// 侧栏：剩余敌人、生命、关卡、当前道具状态与操作提示。
fn draw_panel(
  dl : @moonui.DrawList,
  g : Game,
  px : Double,
  py : Double,
  pw : Double,
  ph : Double,
) -> Unit {
  dl.fill_rect(px, py, pw, ph, radius=10.0, rgb=0x11151F, alpha=255)
  dl.stroke_rect(px, py, pw, ph, radius=10.0, width=1.0, rgb=0x24324A)
  // 剩余敌人
  dl.text("剩余敌人", px + 12.0, py + 12.0, size=11.0, rgb=0x8FA3BF)
  let mut remain = 20 - g.destroyed
  if remain < 0 {
    remain = 0
  }
  let icon = 13.0
  let gap = 3.0
  for i in 0..<remain {
    let row = i / 5
    let col = i % 5
    draw_mini_tank(
      dl,
      px + 12.0 + col.to_double() * (icon + gap),
      py + 32.0 + row.to_double() * (icon + gap),
      icon,
      NES_SILVER,
    )
  }
  // 生命
  dl.text("生命", px + 12.0, py + 104.0, size=11.0, rgb=0x8FA3BF)
  let lives = if g.lives < 0 { 0 } else { g.lives }
  for i in 0..<lives {
    draw_mini_tank(
      dl,
      px + 12.0 + i.to_double() * (icon + gap),
      py + 124.0,
      icon,
      NES_GOLD,
    )
  }
  // 关卡
  dl.text("关卡", px + 12.0, py + 156.0, size=11.0, rgb=0x8FA3BF)
  dl.text(
    "\{g.stage}",
    px + 12.0,
    py + 172.0,
    size=22.0,
    bold=true,
    rgb=0xF2F6FF,
  )
  // 道具状态
  let mut status = ""
  if g.freeze_t > 0 {
    status = "敌人冻结 \{g.freeze_t / 60 + 1}s"
  } else if g.shovel_t > 0 {
    status = "基地钢化 \{g.shovel_t / 60 + 1}s"
  } else if g.player.shield > 0 {
    status = "护盾 \{g.player.shield / 60 + 1}s"
  }
  if status.length() > 0 {
    dl.text(status, px + 12.0, py + 210.0, size=11.0, rgb=0x7FD4FF)
  }
  // 火力等级
  dl.text(
    "火力 Lv\{g.player.star}",
    px + 12.0,
    py + 236.0,
    size=11.0,
    rgb=0x8FA3BF,
  )
  // 底部提示
  dl.line(px, py + 268.0, px + pw, py + 268.0, width=1.0, rgb=0x1D2636)
  dl.text("方向键 移动", px + 12.0, py + 280.0, size=11.0, rgb=0x9AAAC2)
  dl.text("空格 开火", px + 12.0, py + 298.0, size=11.0, rgb=0x9AAAC2)
  dl.text("Enter 开始/重开", px + 12.0, py + 316.0, size=11.0, rgb=0x9AAAC2)
  dl.text("P/Esc 暂停", px + 12.0, py + 334.0, size=11.0, rgb=0x9AAAC2)
}

///|
/// 状态覆盖层：压在战场上，不额外开窗。
fn draw_overlay(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  g : Game,
  v : View,
  fpx : Double,
) -> Unit {
  let ox = v.ox
  let oy = v.oy
  match g.state {
    Playing =>
      if g.paused {
        dl.fill_rect(ox, oy, fpx, fpx, radius=0.0, rgb=0x05080F, alpha=200)
        text_center(
          dl,
          env,
          "已暂停",
          ox + fpx / 2.0,
          oy + fpx / 2.0 - 22.0,
          20.0,
          true,
          0xF2F6FF,
        )
        text_center(
          dl,
          env,
          "P / Esc 继续",
          ox + fpx / 2.0,
          oy + fpx / 2.0 + 10.0,
          11.0,
          false,
          0xA9B7CD,
        )
      }
    StageIntro => {
      dl.fill_rect(ox, oy, fpx, fpx, radius=0.0, rgb=0x05080F, alpha=196)
      text_center(
        dl,
        env,
        "第 \{g.stage} 关",
        ox + fpx / 2.0,
        oy + fpx / 2.0 - 24.0,
        24.0,
        true,
        0xF2F6FF,
      )
      text_center(
        dl,
        env,
        "守住基地 · 20 辆敌坦克",
        ox + fpx / 2.0,
        oy + fpx / 2.0 + 10.0,
        11.0,
        false,
        0xA9B7CD,
      )
    }
    StageClear => {
      dl.fill_rect(ox, oy, fpx, fpx, radius=0.0, rgb=0x05080F, alpha=196)
      text_center(
        dl,
        env,
        "关卡完成！",
        ox + fpx / 2.0,
        oy + fpx / 2.0 - 24.0,
        22.0,
        true,
        0x4ADE80,
      )
      text_center(
        dl,
        env,
        "得分 \{g.score}",
        ox + fpx / 2.0,
        oy + fpx / 2.0 + 10.0,
        12.0,
        false,
        0xA9B7CD,
      )
    }
    GameOver => {
      dl.fill_rect(ox, oy, fpx, fpx, radius=0.0, rgb=0x05080F, alpha=210)
      text_center(
        dl,
        env,
        "GAME OVER",
        ox + fpx / 2.0,
        oy + fpx / 2.0 - 24.0,
        26.0,
        true,
        0xF87171,
      )
      text_center(
        dl,
        env,
        "得分 \{g.score}",
        ox + fpx / 2.0,
        oy + fpx / 2.0 + 12.0,
        12.0,
        false,
        0xA9B7CD,
      )
      if g.state_t <= 0 {
        text_center(
          dl,
          env,
          "按 Enter 重新开始",
          ox + fpx / 2.0,
          oy + fpx / 2.0 + 34.0,
          11.0,
          false,
          0x7FD4FF,
        )
      }
    }
    Attract => {
      dl.fill_rect(ox, oy, fpx, fpx, radius=0.0, rgb=0x05080F, alpha=220)
      text_center(
        dl,
        env,
        "BATTLE CITY",
        ox + fpx / 2.0,
        oy + fpx / 2.0 - 60.0,
        30.0,
        true,
        0xF2F6FF,
      )
      text_center(
        dl,
        env,
        "坦克大战 · Tank 1990 复刻",
        ox + fpx / 2.0,
        oy + fpx / 2.0 - 22.0,
        13.0,
        false,
        0x8FA3BF,
      )
      // 一排坦克剪影
      let icon = 26.0
      let gap = 14.0
      let startx = ox + fpx / 2.0 - (icon * 5.0 + gap * 4.0) / 2.0
      for i in 0..<5 {
        draw_mini_tank(
          dl,
          startx + i.to_double() * (icon + gap),
          oy + fpx / 2.0 + 24.0,
          icon,
          NES_SILVER,
        )
      }
      text_center(
        dl,
        env,
        "按 Enter 开始",
        ox + fpx / 2.0,
        oy + fpx / 2.0 + 78.0,
        12.0,
        true,
        0xFACC15,
      )
    }
  }
}

///|
fn paint(dl : @moonui.DrawList, env : @moonui.PaintEnv, g : Game) -> Unit {
  let w = env.width()
  let h = env.height()
  dl.fill_rect(0.0, 0.0, w, h, radius=0.0, rgb=0x0B0E15, alpha=255)
  // 顶栏
  dl.fill_rect(0.0, 0.0, w, 52.0, radius=0.0, rgb=0x11151F, alpha=255)
  dl.fill_rect(0.0, 52.0, w, 2.0, radius=0.0, rgb=0x3B5BDB, alpha=255)
  dl.text("BATTLE CITY", 16.0, 10.0, size=20.0, bold=true, rgb=0xF2F6FF)
  dl.text(
    "坦克大战 · Tank 1990 复刻",
    16.0,
    34.0,
    size=11.0,
    rgb=0x8FA3BF,
  )
  dl.text("得分", w - 240.0, 10.0, size=11.0, rgb=0x8FA3BF)
  dl.text(
    g.score.to_string(),
    w - 240.0,
    26.0,
    size=17.0,
    bold=true,
    rgb=0xFACC15,
  )
  dl.text("最高", w - 140.0, 10.0, size=11.0, rgb=0x8FA3BF)
  dl.text(g.hi.to_string(), w - 140.0, 26.0, size=17.0, bold=true, rgb=0x4ADE80)

  // 布局
  let top = 66.0
  let bottom = 16.0
  let panel_w = 180.0
  let field_h = h - top - bottom
  let field_w = w - panel_w - 28.0
  let s = fmin(field_w / 208.0, field_h / 208.0)
  let fpx = 208.0 * s
  let ox = 14.0 + (field_w - fpx) / 2.0
  let oy = top + (field_h - fpx) / 2.0
  let v = View::{ s, ox, oy, }

  // 战场外框与底
  dl.fill_rect(
    ox - 6.0,
    oy - 6.0,
    fpx + 12.0,
    fpx + 12.0,
    radius=8.0,
    rgb=0x121826,
    alpha=255,
  )
  dl.fill_rect(ox, oy, fpx, fpx, radius=0.0, rgb=NES_BLACK, alpha=255)

  // 地形（实心的先画；树林最后叠在坦克上）
  for cy in 0..<CELLS {
    for cx in 0..<CELLS {
      let t = g.grid[cy][cx]
      if t != Empty && t != Tree {
        draw_cell(dl, v, cx, cy, t, g.frame)
      }
    }
  }
  draw_eagle(dl, v, g)

  // 子弹（原版白色细弹）
  for b in g.bullets {
    let col = NES_WHITE
    fill(
      dl,
      v,
      b.x.to_double(),
      b.y.to_double(),
      BULLET_PX.to_double(),
      BULLET_PX.to_double(),
      col,
      255,
    )
  }

  // 玩家
  if g.player.alive {
    draw_tank(
      dl,
      v,
      g.player.x.to_double(),
      g.player.y.to_double(),
      g.player.dir,
      tank_pal(Basic, 1, true),
    )
    if g.player.shield > 0 && g.frame / 4 % 2 == 0 {
      let bx = v.ox + g.player.x.to_double() * v.s
      let by = v.oy + g.player.y.to_double() * v.s
      dl.stroke_rect(
        bx - 2.0,
        by - 2.0,
        16.0 * v.s + 4.0,
        16.0 * v.s + 4.0,
        radius=3.0,
        width=1.5,
        rgb=0x7FD4FF,
      )
    }
  }

  // 敌坦克
  for e in g.enemies {
    if !e.alive {
      continue
    }
    if e.spawn_anim > 0 {
      if g.frame / 4 % 2 == 0 {
        draw_spawn_star(dl, v, e.x.to_double(), e.y.to_double(), g.frame)
      }
      continue
    }
    draw_tank(
      dl,
      v,
      e.x.to_double(),
      e.y.to_double(),
      e.dir,
      tank_pal(e.kind, e.hp, false),
    )
    if e.frozen {
      fill(dl, v, e.x.to_double(), e.y.to_double(), 16.0, 16.0, NES_CYAN, 90)
    }
  }

  // 树林叠绘（盖住坦克与子弹，与原版一致）
  for cy in 0..<CELLS {
    for cx in 0..<CELLS {
      if g.grid[cy][cx] == Tree {
        draw_tree_cell(dl, v, cx, cy)
      }
    }
  }

  // 道具
  for p in g.powers {
    draw_power(dl, v, p, g.frame)
  }

  // 侧栏
  draw_panel(dl, g, ox + fpx + 12.0, top, panel_w, field_h - 20.0)

  // 状态覆盖
  draw_overlay(dl, env, g, v, fpx)
}

///|
/// 键盘翻译成规则输入。这是 UI 层的方法（要读 `@moonui.KeyPress`），
/// 方向键保持态存在 `Game` 上，这样"按住方向键 → 每帧前进"不会因
/// 闭包拷贝而丢状态。
fn Game::apply_key(self : Game, kp : @moonui.KeyPress, down : Bool) -> Unit {
  let k = kp.key
  if k == "Enter" {
    if down {
      if self.state == Attract || self.state == GameOver {
        self.start_new_game()
      } else if self.state == StageClear {
        // 直接进下一关
        self.reset_level(self.stage + 1)
      } else if self.paused {
        self.toggle_pause()
      }
    }
  } else if k == " " || k == "Space" {
    if down {
      self.player_shoot()
    }
  } else if k == "p" || k == "P" || k == "Escape" {
    if down {
      self.toggle_pause()
    }
  } else if k == "r" || k == "R" {
    if down {
      self.start_new_game()
    }
  } else if k == "Left" || k == "Right" || k == "Up" || k == "Down" {
    if k == "Left" {
      self.key_left = down
    } else if k == "Right" {
      self.key_right = down
    } else if k == "Up" {
      self.key_up = down
    } else if k == "Down" {
      self.key_down = down
    }
    let mut dir = -1
    let mut moving = false
    if self.key_left {
      dir = 2
      moving = true
    } else if self.key_right {
      dir = 3
      moving = true
    } else if self.key_up {
      dir = 0
      moving = true
    } else if self.key_down {
      dir = 1
      moving = true
    }
    self.player_input(dir, moving)
  }
}

///|
/// 预生成的音效字节：启动时合成一次（9 条），帧循环里只播不改。
struct SfxBank {
  move_snd : Bytes
  shoot_snd : Bytes
  hit_wall_snd : Bytes
  explode_snd : Bytes
  armor_snd : Bytes
  pause_snd : Bytes
  resume_snd : Bytes
  stage_intro_snd : Bytes
  game_over_snd : Bytes
  bonus_appear_snd : Bytes
  bonus_taken_snd : Bytes
  hq_explode_snd : Bytes
}

///|
fn make_sfx_bank() -> SfxBank {
  {
    move_snd: sfx_move(),
    shoot_snd: sfx_shoot(),
    hit_wall_snd: sfx_hit_wall(),
    explode_snd: sfx_explode(),
    armor_snd: sfx_armor(),
    pause_snd: sfx_pause(),
    resume_snd: sfx_resume(),
    stage_intro_snd: sfx_stage_intro(),
    game_over_snd: sfx_game_over(),
    bonus_appear_snd: sfx_bonus_appear(),
    bonus_taken_snd: sfx_bonus_taken(),
    hq_explode_snd: sfx_hq_explode(),
  }
}

///|
/// 把规则层排出的音效事件播掉。`-3`（Windows/Linux 未接）静默——游戏照常跑。
fn play_sfx(bank : SfxBank, ev : Sfx) -> Unit {
  let wav = match ev {
    Move => bank.move_snd
    Shoot => bank.shoot_snd
    HitWall => bank.hit_wall_snd
    Explode => bank.explode_snd
    ArmorHit => bank.armor_snd
    Pause => bank.pause_snd
    Resume => bank.resume_snd
    StageIntro => bank.stage_intro_snd
    GameOver => bank.game_over_snd
    BonusAppear => bank.bonus_appear_snd
    BonusTaken => bank.bonus_taken_snd
    HqExplode => bank.hq_explode_snd
  }
  let _ = @native-common.native_sfx_play(wav)
}

///|
/// `moon run examples/battlecity-native` 开真窗口。
fn main raise {
  let bench_ms = match @env.get_env_var("BC_BENCH_MS") {
    Some(v) => (@string.from_str(v[:]) : Int32) catch { _ => 0 }
    None => 0
  }
  let app = @moonui-app.new_app()
  let b = app.backend()
  let g = Game::new(20261125)
  // 音效字节启动时合成一次；Windows/Linux 上 `native_sfx_play` 返回 -3，静默。
  let bank = make_sfx_bank()
  // 吸引页背后铺一张第 1 关地图
  g.build_map(1)

  let face = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(600.0, 520.0),
    fn(dl, env) { paint(dl, env, g) },
    focusable=true,
  )
  let on_key = fn(ev : @moonui.Event) {
    match ev {
      @moonui.KeyDown(_, kp) => g.apply_key(kp, true)
      @moonui.KeyUp(_, kp) => g.apply_key(kp, false)
      _ => ()
    }
  }
  let _ = face.on_any(fn(ev) { on_key(ev) })
  let win = app.create_window(
    "Battle City · 坦克大战",
    @moonui.LogicalSize(600.0, 520.0),
  )
  let _ = app.on_event(win.target(), fn(ev) { on_key(ev) })
  win.set_content(face)
  win.show()
  println(
    "坦克大战已开窗：方向键移动，空格开火，Enter 开始/重开，P/Esc 暂停",
  )
  println("  设 BC_BENCH_MS=<毫秒> 可自动跑统计退出")

  let ticker = @moonui.Ticker()
  let mut elapsed : Int32 = 0
  let mut frames : Int32 = 0
  let mut bench_started : Bool = false
  let _ = app.post_animation(ticker, 16, fn(
    first,
  ) -> Bool raise @moonui.UiError {
    let _ = first
    // 跑分模式自动开局、朝上开火（不移动、不朝下——别把自家基地打爆），
    // 把"出生→AI→子弹→道具→过场"整条模拟链路压一遍，无人值守也能验玩法不崩。
    if bench_ms > 0 {
      if !bench_started {
        bench_started = true
        g.start_new_game()
      }
      if frames % 8 == 0 {
        g.player_shoot()
      }
    }
    g.tick(16)
    // 排空本帧的音效事件并播放
    for ev in g.drain_sfx() {
      play_sfx(bank, ev)
    }
    face.repaint()
    if bench_ms > 0 {
      frames += 1
      elapsed += 16
      if elapsed >= bench_ms {
        let avg = frames.to_double() * 1000.0 / elapsed.to_double()
        println(
          "BattleCity bench: frames=\{frames}, elapsed=\{elapsed}ms, avg=\{avg.to_string()}fps, score=\{g.score}, stage=\{g.stage}, spawned=\{g.spawned}, destroyed=\{g.destroyed}, alive=\{g.enemies.length()}, bullets=\{g.bullets.length()}",
        )
        app.quit()
        return false
      }
    }
    true
  })
  app.run()
}
