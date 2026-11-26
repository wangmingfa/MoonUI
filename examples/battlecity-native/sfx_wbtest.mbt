///|
/// 音效合成的最小判据：产出的字节是合法 16-bit PCM mono WAV 且确实含声音
/// （非静音）。不碰后端——合成是纯函数，只验编码不变式。
/// 断言直接写在 test 块里：`assert_eq` 可 raise，块外助手函数签名不接。

///|
test "sfx: 十二条音效都是合法 WAV 且含声" {
  let all = [
    sfx_move(),
    sfx_shoot(),
    sfx_hit_wall(),
    sfx_explode(),
    sfx_armor(),
    sfx_pause(),
    sfx_resume(),
    sfx_stage_intro(),
    sfx_game_over(),
    sfx_bonus_appear(),
    sfx_bonus_taken(),
    sfx_hq_explode(),
  ]
  for w in all {
    assert_eq(w.length() > 44, true)
    // RIFF/WAVE 魔数
    assert_eq(w.at(0), b'R')
    assert_eq(w.at(1), b'I')
    assert_eq(w.at(2), b'F')
    assert_eq(w.at(3), b'F')
    assert_eq(w.at(8), b'W')
    assert_eq(w.at(9), b'A')
    assert_eq(w.at(10), b'V')
    assert_eq(w.at(11), b'E')
    // fmt chunk：PCM(1)、单声道、16-bit
    assert_eq(w.at(20), 0b1)
    assert_eq(w.at(21), 0b0)
    assert_eq(w.at(22), 0b1)
    assert_eq(w.at(23), 0b0)
    // sample rate = 22050（小端）
    let rate = w.at(24).to_int() |
      (w.at(25).to_int() << 8) |
      (w.at(26).to_int() << 16) |
      (w.at(27).to_int() << 24)
    assert_eq(rate, SFX_RATE)
    assert_eq(w.at(34), 16)
    assert_eq(w.at(35), 0)
    // data 块魔数与长度
    assert_eq(w.at(36), b'd')
    assert_eq(w.at(37), b'a')
    assert_eq(w.at(38), b't')
    assert_eq(w.at(39), b'a')
    let data_len = w.at(40).to_int() |
      (w.at(41).to_int() << 8) |
      (w.at(42).to_int() << 16) |
      (w.at(43).to_int() << 24)
    assert_eq(w.length() - 44, data_len)
    // 非静音：数据段至少一个非零字节
    let mut nonzero = false
    for i in 44..<w.length() {
      if w.at(i) != 0b0 {
        nonzero = true
        break
      }
    }
    assert_eq(nonzero, true)
  }
}

///|
test "sfx: 开场与射击会排音效事件" {
  let g = Game::new(2026)
  g.start_new_game()
  // 开场：关卡音乐
  let evs0 = g.drain_sfx()
  assert_eq(evs0.contains(StageIntro), true)
  run_frames(g, 100) // 过开场
  g.player_shoot()
  let evs = g.drain_sfx()
  assert_eq(evs.contains(Shoot), true)
}

///|
test "sfx: 装甲坦克掉血 ArmorHit、打爆 Explode" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100)
  let _ = g.drain_sfx()
  // 放一辆装甲坦克（4 血，不动不射）
  g.enemies = [
    Tank::{
      x: 100,
      y: 100,
      dir: Up,
      speed: 1,
      kind: Armor,
      hp: 4,
      alive: true,
      shoot_cd: 999,
      move_cd: 999,
      frozen: true,
      spawn_anim: 0,
      speed_acc: 0,
    },
  ]
  g.hit_enemy(0, false) // 4→3
  assert_eq(g.drain_sfx().contains(ArmorHit), true)
  g.hit_enemy(0, false) // 3→2
  g.hit_enemy(0, false) // 2→1
  assert_eq(g.drain_sfx().contains(ArmorHit), true)
  g.hit_enemy(0, false) // 1→爆
  assert_eq(g.drain_sfx().contains(Explode), true)
}

///|
test "sfx: 开场/结束旋律时长符合原版帧数" {
  // 原版 Sound_Battle1/2/3 各 264 帧（4.40s @60fps）；mix3 取三路最短，仍为 264。
  let intro_data = 264 * SFX_RATE / 60 * 2
  assert_eq(sfx_stage_intro().length() - 44, intro_data)
  // 原版 Sound_GameOver1/2/3 各 108 帧（1.80s）。
  let over_data = 108 * SFX_RATE / 60 * 2
  assert_eq(sfx_game_over().length() - 44, over_data)
}

///|
test "sfx: 道具出现/吃到/基地爆炸会排音效事件" {
  let g = Game::new(2026)
  g.start_new_game()
  run_frames(g, 100)
  let _ = g.drain_sfx()
  // 道具掉在场上 → BonusAppear
  g.drop_power(100, 100)
  assert_eq(g.drain_sfx().contains(BonusAppear), true)
  // 玩家压到道具 → BonusTaken
  g.powers = [Power::{ x: g.player.x, y: g.player.y, kind: Star, life: 600, }]
  g.tick_powers()
  assert_eq(g.drain_sfx().contains(BonusTaken), true)
  // 基地被炸 → HqExplode + GameOver
  g.eagle_hit()
  let evs = g.drain_sfx()
  assert_eq(evs.contains(HqExplode), true)
  assert_eq(evs.contains(GameOver), true)
}
