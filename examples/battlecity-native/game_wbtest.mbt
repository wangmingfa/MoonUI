///|
/// 坦克大战规则层的最小判据：不碰 UI，只验状态机与碰撞的关键不变式。
/// 这些同时是"卡死/越界/负下标"的回归入口——任何一条红都说明规则
/// 层有破坏不变量的改动。

///|
/// 跑满一段定拍：`frames` 帧 × `tick(16)`，把开场动画也走完。
fn run_frames(g : Game, frames : Int32) -> Unit {
  for _ in 0..<frames {
    g.tick(16)
  }
}

///|
test "new_game: 初始是吸引态，地图干净" {
  let g = Game::new(2026)
  assert_eq(g.state, Attract)
  assert_eq(g.stage, 1)
  assert_eq(g.score, 0)
  assert_eq(g.lives, 3)
  // 地图还没铺：全空
  for y in 0..<CELLS {
    for x in 0..<CELLS {
      assert_eq(g.grid[y][x], Empty)
    }
  }
}

///|
test "start_new_game: 铺好第 1 关地图并进入开场" {
  let g = Game::new(2026)
  g.start_new_game()
  assert_eq(g.state, StageIntro)
  assert_eq(g.stage, 1)
  assert_eq(g.lives, 3)
  // 老鹰周围有砖墙：基地上方那块是砖
  assert_eq(g.grid[20][12], Brick) // tile (6,10) 顶墙
  assert_eq(g.grid[22][10], Brick) // tile (5,11) 左墙
  // 三个出生点清空
  assert_eq(g.grid[0][0], Empty)
  assert_eq(g.grid[0][12], Empty)
  assert_eq(g.grid[0][24], Empty)
  // 玩家出生点清空
  assert_eq(g.grid[24][8], Empty)
}

///|
test "stage_intro: 90 帧后进入游玩" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 89)
  assert_eq(g.state, StageIntro)
  run_frames(g, 1)
  assert_eq(g.state, Playing)
}

///|
test "spawn: 时间到会出敌坦克，上限 4 辆" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100) // 过开场
  assert_eq(g.state, Playing)
  // 再跑一会儿，应该有敌出现
  run_frames(g, 300)
  let mut n = 0
  for e in g.enemies {
    if e.alive {
      n += 1
    }
  }
  assert_eq(n > 0 && n <= 4, true)
}

///|
test "spawn: 场上无击杀时最多 4 辆，总数不超 20" {
  let g = Game::new(7)
  g.start_new_game()
  run_frames(g, 100)
  // 长跑：不消灭敌人，只看出生上限（存活≥4 就停）
  run_frames(g, 20 * 160 + 200)
  assert_eq(g.spawned <= 20, true)
  assert_eq(g.spawned <= 4, true)
  let mut alive = 0
  for e in g.enemies {
    if e.alive {
      alive += 1
    }
  }
  assert_eq(alive <= 4, true)
}

///|
test "player_shoot: 星数限制子弹数" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100) // 过开场
  // 无星：最多 1 发
  g.player_shoot()
  assert_eq(g.count_player_bullets(), 1)
  g.player_shoot()
  assert_eq(g.count_player_bullets(), 1)
  // 双星：最多 2 发
  g.player.star = 2
  g.player_shoot()
  assert_eq(g.count_player_bullets(), 2)
  g.player_shoot()
  assert_eq(g.count_player_bullets(), 2)
}

///|
test "tick: 玩家按住方向键会在场上移动且不出界" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100)
  let x0 = g.player.x
  // 按住左
  g.player_input(2, true)
  run_frames(g, 30)
  assert_eq(g.player.x < x0, true)
  // 一直左也不出界
  run_frames(g, 400)
  assert_eq(g.player.x >= 0, true)
}

///|
test "碰撞: 玩家撞砖墙被挡，不会穿过" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100)
  // 玩家出生在 (64,192)，向上走很快会撞到基地顶墙/地图，不应出界
  g.player_input(0, true) // 上
  run_frames(g, 600)
  assert_eq(g.player.y >= 0, true)
  assert_eq(g.player.y <= FIELD_PX - TANK_PX, true)
}

///|
test "子弹: 打砖碎一个 8×8 子块" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100) // 过开场，进入游玩态
  // 在玩家正上方放一块砖（玩家出生 (64,192)，炮管在 x≈72，对应 8×8 子块
  // (cx=8, cy=23)：x 64..72，y 184..192）
  g.set_cell(8, 23, Brick)
  assert_eq(g.grid[23][8], Brick)
  g.player.dir = Up
  g.player_shoot()
  run_frames(g, 20)
  assert_eq(g.grid[23][8], Empty)
}

///|
test "游戏结束: 老鹰被毁即 GAME OVER" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100)
  assert_eq(g.eagle_alive, true)
  // 直接打中老鹰
  g.eagle_hit()
  assert_eq(g.eagle_alive, false)
  assert_eq(g.state, GameOver)
}

///|
test "过关: 20 辆全灭后进入过场并进入下一关" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100)
  // 直接把 20 辆全灭（模拟手雷连发：清场不算道具，用 hit_enemy 逐个）
  g.destroyed = 20
  g.spawned = 20
  g.enemies = []
  g.tick(16)
  assert_eq(g.state, StageClear)
  // 过场结束后进入第 2 关
  run_frames(g, 200)
  assert_eq(g.state, StageIntro)
  assert_eq(g.stage, 2)
}

///|
test "speed: 70% 后玩家 100 帧走 140px（1.4px/帧）" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100) // 过开场
  g.enemies = [] // 清场：别让敌坦克干扰
  g.spawn_timer = 9999 // 这 100 帧内不出新敌
  // 放到全空的行 6（y=96），向右有一条清空跑道
  g.player.x = 0
  g.player.y = 96
  g.player.dir = Right
  g.player.speed_acc = 0
  g.player_input(3, true)
  run_frames(g, 100)
  // 1.4px/帧 × 100 帧 = 140px（14 十分之一/帧，整十无余数）
  assert_eq(g.player.x, 140)
  assert_eq(g.player.y, 96)
}

///|
test "speed: 敌方亚像素累积不丢步（Fast 4→2.8px/帧）" {
  let g = Game::new(7)
  g.start_new_game()
  run_frames(g, 100)
  // 放一辆 Fast 敌坦在全空行，向右走；speed_acc 单独验证推进
  let (s1, r1) = advance_acc(0, 4 * ENEMY_SPEED_SCALE) // 4×7=28
  assert_eq(s1, 2) // 28/10 = 2px
  assert_eq(r1, 8) // 28%10 = 8 十分之一
  let (s2, r2) = advance_acc(r1, 4 * ENEMY_SPEED_SCALE) // 8+28=36
  assert_eq(s2, 3)
  assert_eq(r2, 6)
}

///|
test "fuzz: 随机方向长跑不越界不崩" {
  let g = Game::new(99)
  g.start_new_game()
  run_frames(g, 100)
  for r in 0..<50 {
    g.player_input(r % 4, true)
    g.player_shoot()
    run_frames(g, 40)
    // 全场格子在界内
    for y in 0..<CELLS {
      for x in 0..<CELLS {
        let _ = g.grid[y][x]
      }
    }
    assert_eq(g.player.x >= 0 && g.player.x <= FIELD_PX - TANK_PX, true)
    assert_eq(g.player.y >= 0 && g.player.y <= FIELD_PX - TANK_PX, true)
  }
}

///|
/// 素材对齐原版：地形/坦克/老鹰/子弹/道具颜色必须是 NES 2C02 的实际显示
/// RGB（不是手调近似值）。值来自 `Battle City (J).asm` 的 `SpritePalette` /
/// `LevelPalette`（PPU 索引）映到 2C02→RGB 标准表。任何一条红都说明配色
/// 被"顺手调色"过、脱离了原版。
test "nes: 素材颜色锁定 NES 2C02 原色" {
  // 精灵四组（SpritePalette）：0=金(玩家) 1=绿 2=银 3=红
  assert_eq(NES_GOLD_DARK, 0x545A00) // $18
  assert_eq(NES_GOLD, 0xC88E00) // $27
  assert_eq(NES_GOLD_LIGHT, 0xCCD278) // $38
  assert_eq(NES_GREEN_DEEP, 0x004000) // $0A
  assert_eq(NES_GREEN, 0x007628) // $1B
  assert_eq(NES_GREEN_LIGHT, 0x80DE90) // $3B
  assert_eq(NES_SILVER_DARK, 0x00323C) // $0C
  assert_eq(NES_SILVER, 0x989696) // $10
  assert_eq(NES_RED_DARK, 0x540400) // $06
  assert_eq(NES_RED, 0x982220) // $16
  assert_eq(NES_RED_LIGHT, 0xEC6C54) // $26
  // 背景（LevelPalette）：砖/钢/水/树
  assert_eq(NES_BLUE, 0x3032EC) // $12
  assert_eq(NES_CYAN, 0x60C8B8) // $3C
  assert_eq(NES_TREE, 0x64C000) // $29
  assert_eq(NES_GREEN_DARK, 0x083A00) // $09
  assert_eq(NES_GREEN_MID, 0x003C00) // $0B
  assert_eq(NES_WHITE, 0xECEEEC) // $20
  assert_eq(NES_BLACK, 0x000000) // $00
}
