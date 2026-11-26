///|
/// Battle City（坦克大战，1985）原版配乐/音效复刻合成。纯函数：不碰 UI/后端，
/// 可白盒测。输出 16-bit PCM 单声道 22050Hz WAV，交给
/// `@native-common.native_sfx_play` 播。
///
/// **音符数据来源**：`romhack/battle-city-disassembly` 的 Battle City (J).asm 里
/// 的 APU 声音数据表（`Sound_Battle1/2/3`、`Sound_GameOver1/2/3`、`Sound_Shoot`
/// 等），按引擎字节码语义解码成 `(频率, 帧数)`。频率是**原版 NES APU 的实际
/// 频率**（CPU 1789773Hz / (16×(period+1))，period 取自游戏内 Frequency_LUT），
/// 不是 12 平均律——保留原味。
///
/// **波形**：NES 风格。脉冲通道（P1/P2）用可调占空比方波，三角通道（TRI）用
/// 三角波，噪声通道用白噪声（LCG，可复现）。每音符 2ms 起落包络防爆音。
pub const SFX_RATE : Int32 = 22050

///|
/// 一个音符：`f` = 原版 APU 频率（Hz），`n` = 时长（1/60s 帧，游戏/原机都是 60fps）。
struct Note {
  f : Double
  n : Int32
}

///|
/// 原版 Stage Start 主旋律（`Sound_Battle1`，脉冲1 通道，25% 占空比）：上行号角。
let battle1_notes : Array[Note] = [
  { f: 522.7, n: 8, },
  { f: 585.7, n: 8, },
  { f: 621.4, n: 8, },
  { f: 522.7, n: 8, },
  { f: 585.7, n: 8, },
  { f: 621.4, n: 8, },
  { f: 621.4, n: 8, },
  { f: 694.8, n: 8, },
  { f: 782.2, n: 8, },
  { f: 621.4, n: 8, },
  { f: 694.8, n: 8, },
  { f: 782.2, n: 8, },
  { f: 694.8, n: 8, },
  { f: 782.2, n: 8, },
  { f: 873.9, n: 8, },
  { f: 694.8, n: 8, },
  { f: 782.2, n: 8, },
  { f: 873.9, n: 8, },
  { f: 828.6, n: 8, },
  { f: 924.5, n: 8, },
  { f: 1045.4, n: 8, },
  { f: 828.6, n: 8, },
  { f: 924.5, n: 8, },
  { f: 1045.4, n: 8, },
  { f: 1045.4, n: 24, },
  { f: 1045.4, n: 8, },
  { f: 1045.4, n: 8, },
  { f: 1045.4, n: 8, },
  { f: 1045.4, n: 24, },
]

///|
/// 原版 Stage Start 低音和声（`Sound_Battle3`，脉冲2 通道，25% 占空比）。
let battle3_notes : Array[Note] = [
  { f: 195.6, n: 24, },
  { f: 195.6, n: 8, },
  { f: 195.6, n: 8, },
  { f: 195.6, n: 8, },
  { f: 232.6, n: 24, },
  { f: 232.6, n: 8, },
  { f: 232.6, n: 8, },
  { f: 232.6, n: 8, },
  { f: 261.4, n: 24, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 310.7, n: 8, },
  { f: 310.7, n: 8, },
  { f: 310.7, n: 8, },
  { f: 348.5, n: 8, },
  { f: 348.5, n: 8, },
  { f: 348.5, n: 8, },
  { f: 329.0, n: 24, },
  { f: 329.0, n: 8, },
  { f: 329.0, n: 8, },
  { f: 329.0, n: 8, },
  { f: 329.0, n: 24, },
]

///|
/// 原版 Stage Start 中音和声（`Sound_Battle2`，三角波通道）。
let battle2_notes : Array[Note] = [
  { f: 261.4, n: 24, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 310.7, n: 24, },
  { f: 310.7, n: 8, },
  { f: 310.7, n: 8, },
  { f: 310.7, n: 8, },
  { f: 348.5, n: 24, },
  { f: 348.5, n: 8, },
  { f: 348.5, n: 8, },
  { f: 348.5, n: 8, },
  { f: 414.3, n: 8, },
  { f: 414.3, n: 8, },
  { f: 414.3, n: 8, },
  { f: 464.2, n: 8, },
  { f: 464.2, n: 8, },
  { f: 464.2, n: 8, },
  { f: 391.1, n: 24, },
  { f: 391.1, n: 8, },
  { f: 391.1, n: 8, },
  { f: 391.1, n: 8, },
  { f: 391.1, n: 24, },
]

///|
/// 原版 Game Over 主旋律（`Sound_GameOver1`，脉冲1）：下行。
let gameover1_notes : Array[Note] = [
  { f: 522.7, n: 6, },
  { f: 464.2, n: 6, },
  { f: 522.7, n: 24, },
  { f: 391.1, n: 8, },
  { f: 348.5, n: 8, },
  { f: 310.7, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 24, },
]

///|
/// 原版 Game Over 和声（`Sound_GameOver2`，脉冲2）。
let gameover2_notes : Array[Note] = [
  { f: 391.1, n: 6, },
  { f: 391.1, n: 6, },
  { f: 391.1, n: 24, },
  { f: 310.7, n: 8, },
  { f: 292.8, n: 8, },
  { f: 246.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 8, },
  { f: 261.4, n: 24, },
]

///|
/// 原版 Game Over 三角波（`Sound_GameOver3`）。
let gameover3_notes : Array[Note] = [
  { f: 658.0, n: 6, },
  { f: 621.4, n: 6, },
  { f: 658.0, n: 24, },
  { f: 522.7, n: 8, },
  { f: 464.2, n: 8, },
  { f: 391.1, n: 8, },
  { f: 391.1, n: 8, },
  { f: 391.1, n: 8, },
  { f: 391.1, n: 8, },
  { f: 391.1, n: 24, },
]

///|
/// 原版射击（`Sound_Shoot`，脉冲1，12.5% 占空比）：短促高音"piu"。
let shoot_notes : Array[Note] = [{ f: 1165.2, n: 15, }]

///|
/// 原版敌方坦克爆炸（`Sound_EnemyExplode`，噪声通道）：低鸣白噪爆。
let enemyexplode_notes : Array[Note] = [
  { f: 195.6, n: 2, },
  { f: 195.6, n: 2, },
  { f: 195.6, n: 10, },
]

///|
/// 原版碎砖（`Sound_BrickRicochet`，三角波）：短促三连。
let brickricochet_notes : Array[Note] = [
  { f: 329.0, n: 1, },
  { f: 492.8, n: 1, },
  { f: 279.0, n: 1, },
]

///|
/// 原版装甲坦克掉血（`Sound_ArmourRicochetTank`，脉冲2，12.5%）：金属"叮"。
let armourricochettank_notes : Array[Note] = [
  { f: 2601.4, n: 1, },
  { f: 2728.3, n: 2, },
  { f: 73.4, n: 2, },
]

///|
/// 原版暂停（`Sound_Pause`，脉冲2，25%）：上行琶音 + 尾音。
let pause_notes : Array[Note] = [
  { f: 522.7, n: 4, },
  { f: 585.7, n: 4, },
  { f: 658.0, n: 4, },
  { f: 1045.4, n: 4, },
  { f: 1165.2, n: 4, },
  { f: 1316.0, n: 4, },
  { f: 782.2, n: 12, },
]

///|
/// 一个音符的样本数：`n` 帧 × 每帧 22050/60 样本。
fn note_samples(note : Note) -> Int32 {
  note.n * SFX_RATE / 60
}

///|
/// 线性起落包络（防爆音）：头 `edge` 样本从 0 爬到 1，尾 `edge` 样本从 1 掉到 0；
/// 音符太短则两段各占一半。
fn env_at(i : Int32, len : Int32, edge : Int32) -> Double {
  if len <= 0 {
    return 0.0
  }
  if edge <= 0 {
    return 1.0
  }
  let e = if edge * 2 >= len { len / 2 } else { edge }
  if i < e {
    return i.to_double() / e.to_double()
  }
  if i >= len - e {
    return (len - 1 - i).to_double() / e.to_double()
  }
  1.0
}

///|
/// 渲染一串音符成脉冲（方波）样本：占空比 `duty`（0..1）、幅度 `amp`。
fn render_pulse(
  notes : Array[Note],
  duty : Double,
  amp : Double,
) -> Array[Double] {
  let mut total = 0
  for note in notes {
    total += note_samples(note)
  }
  let out = Array::make(total, 0.0)
  let rate = SFX_RATE.to_double()
  let edge = (0.002 * rate).to_int() // 2ms 起落
  let mut w = 0
  for note in notes {
    let ns = note_samples(note)
    let period = if note.f > 1.0 { rate / note.f } else { rate }
    let mut phase = 0.0
    for i in 0..<ns {
      phase = phase + 1.0 / period
      if phase >= 1.0 {
        phase = phase - 1.0
      }
      let v = if phase < duty { 1.0 } else { -1.0 }
      out[w + i] = v * amp * env_at(i, ns, edge)
    }
    w += ns
  }
  out
}

///|
/// 渲染一串音符成三角波样本：幅度 `amp`。
fn render_triangle(notes : Array[Note], amp : Double) -> Array[Double] {
  let mut total = 0
  for note in notes {
    total += note_samples(note)
  }
  let out = Array::make(total, 0.0)
  let rate = SFX_RATE.to_double()
  let edge = (0.002 * rate).to_int()
  let mut w = 0
  for note in notes {
    let ns = note_samples(note)
    let period = if note.f > 1.0 { rate / note.f } else { rate }
    let mut phase = 0.0
    for i in 0..<ns {
      phase = phase + 1.0 / period
      if phase >= 1.0 {
        phase = phase - 1.0
      }
      // 三角波：phase=0 → -1，0.5 → +1，1 → -1
      let v = 1.0 - 4.0 * (phase - 0.5).abs()
      out[w + i] = v * amp * env_at(i, ns, edge)
    }
    w += ns
  }
  out
}

///|
/// 确定性 LCG（白噪声源）：可复现。
fn lcg(seed : Int64) -> Int64 {
  seed * 6364136223846793005 + 1442695040888963407
}

///|
/// 渲染噪声爆（爆炸类）：白噪声 + 轻微低通（更"轰"）+ 指数衰减包络。
/// 时长取 `notes` 总帧数；`dark` 控制低通强度（0..1，越大越闷）。
fn render_noise(
  notes : Array[Note],
  amp : Double,
  dark : Double,
  seed : Int64,
) -> Array[Double] {
  let mut total = 0
  for note in notes {
    total += note_samples(note)
  }
  let out = Array::make(total, 0.0)
  let mut s = seed
  let mut y = 0.0
  for i in 0..<total {
    s = lcg(s)
    let u = (s >> 33).to_double() / 2147483648.0 - 1.0
    // 一阶低通：越大越暗
    y = y + dark * (u - y)
    // 指数衰减：尾段掉到 ~5%
    let t = i.to_double() / total.to_double()
    let decay = (1.0 - t) * (1.0 - t)
    out[i] = y * amp * decay
  }
  out
}

///|
/// 把三路样本逐点求和并限幅（±0.95）。用于三通道音乐混合。
fn mix3(
  a : Array[Double],
  b : Array[Double],
  c : Array[Double],
) -> Array[Double] {
  let n = imin(a.length(), imin(b.length(), c.length()))
  let out = Array::make(n, 0.0)
  for i in 0..<n {
    let v = (a[i] + b[i] + c[i]).clamp(min=-0.95, max=0.95)
    out[i] = v
  }
  out
}

///|
fn le16(v : Int32) -> Bytes {
  Bytes::makei(2, fn(i) { ((v >> (8 * i)) & 0xFF).to_byte() })
}

///|
fn le32(v : Int32) -> Bytes {
  Bytes::makei(4, fn(i) { ((v >> (8 * i)) & 0xFF).to_byte() })
}

///|
/// 幅度样本 → 16-bit PCM mono WAV 字节（RIFF 头 + 数据）。
fn wav(samples : Array[Double]) -> Bytes {
  let n = samples.length()
  let data_len = n * 2
  let total = 44 + data_len
  let header = b"RIFF"
    .add(le32(total - 8))
    .add(b"WAVE")
    .add(b"fmt ")
    .add(le32(16))
    .add(le16(1)) // PCM
    .add(le16(1)) // mono
    .add(le32(SFX_RATE))
    .add(le32(SFX_RATE * 2)) // byte rate
    .add(le16(2)) // block align
    .add(le16(16)) // bits
    .add(b"data")
    .add(le32(data_len))
  let body = Bytes::makei(data_len, fn(i) {
    let si = i / 2
    let v = (samples[si] * 32767.0)
      .round()
      .to_int()
      .clamp(min=-32768, max=32767)
    let shift = (i & 1) * 8
    ((v >> shift) & 0xFF).to_byte()
  })
  header.add(body)
}

///|
/// 每关开场音乐：Stage Start 原版三通道号角（脉冲1 主旋律 + 脉冲2 低音 + 三角波）。
pub fn sfx_stage_intro() -> Bytes {
  let lead = render_pulse(battle1_notes, 0.25, 0.40)
  let bass = render_pulse(battle3_notes, 0.25, 0.30)
  let tri = render_triangle(battle2_notes, 0.45)
  wav(mix3(lead, bass, tri))
}

///|
/// 游戏失败音乐：Game Over 原版三通道下行旋律。
pub fn sfx_game_over() -> Bytes {
  let lead = render_pulse(gameover1_notes, 0.25, 0.40)
  let harm = render_pulse(gameover2_notes, 0.25, 0.30)
  let tri = render_triangle(gameover3_notes, 0.45)
  wav(mix3(lead, harm, tri))
}

///|
/// 移动履带声：原版 Move（87.2/92.4Hz 交替低鸣，无限循环）取 12 帧短版，
/// 让游戏里每 8 帧触发一次时听起来是连续的履带"vroom"。
pub fn sfx_move() -> Bytes {
  let notes : Array[Note] = []
  for _ in 0..<6 {
    notes.push({ f: 87.2, n: 2, })
    notes.push({ f: 92.4, n: 2, })
  }
  wav(render_pulse(notes, 0.5, 0.55))
}

///|
/// 发射子弹：原版 1165Hz 短促"piu"。
pub fn sfx_shoot() -> Bytes {
  wav(render_pulse(shoot_notes, 0.125, 0.55))
}

///|
/// 子弹打墙（碎砖）：原版 BrickRicochet 短促三连。
pub fn sfx_hit_wall() -> Bytes {
  wav(render_triangle(brickricochet_notes, 0.5))
}

///|
/// 敌方坦克爆炸（击杀）：原版噪声爆。
pub fn sfx_explode() -> Bytes {
  wav(render_noise(enemyexplode_notes, 0.75, 0.18, 987654))
}

///|
/// 装甲坦克掉一格血：原版金属"叮"。
pub fn sfx_armor() -> Bytes {
  wav(render_pulse(armourricochettank_notes, 0.125, 0.5))
}

///|
/// 暂停：原版上行琶音。
pub fn sfx_pause() -> Bytes {
  wav(render_pulse(pause_notes, 0.25, 0.5))
}

///|
/// 继续（取消暂停）：原版没有独立的"继续"音，复用小段上行琶音（同 Pause，
/// 但短一截）——游戏需要一声反馈。
pub fn sfx_resume() -> Bytes {
  let short : Array[Note] = [
    { f: 522.7, n: 4, },
    { f: 585.7, n: 4, },
    { f: 658.0, n: 4, },
  ]
  wav(render_pulse(short, 0.25, 0.5))
}

///|
/// 道具出现（原版 `Sound_BonusAppears`，脉冲2，25%）：短促回环叮咚。
pub fn sfx_bonus_appear() -> Bytes {
  let notes : Array[Note] = [
    { f: 391.1, n: 4, },
    { f: 329.0, n: 4, },
    { f: 391.1, n: 4, },
    { f: 438.7, n: 4, },
    { f: 391.1, n: 4, },
    { f: 438.7, n: 4, },
    { f: 492.8, n: 4, },
    { f: 522.7, n: 4, },
  ]
  wav(render_pulse(notes, 0.25, 0.5))
}

///|
/// 吃到道具/奖励（原版 `Sound_BonusTaken`，脉冲2，25%）：上行琶音 + 尾音。
pub fn sfx_bonus_taken() -> Bytes {
  let notes : Array[Note] = [
    { f: 391.1, n: 3, },
    { f: 522.7, n: 3, },
    { f: 658.0, n: 3, },
    { f: 782.2, n: 3, },
    { f: 369.2, n: 3, },
    { f: 492.8, n: 3, },
    { f: 621.4, n: 3, },
    { f: 735.9, n: 3, },
    { f: 522.7, n: 3, },
    { f: 658.0, n: 3, },
    { f: 782.2, n: 3, },
    { f: 1045.4, n: 3, },
    { f: 1316.0, n: 3, },
  ]
  wav(render_pulse(notes, 0.25, 0.5))
}

///|
/// 基地（鹰）被炸（原版 `Sound_HQExplode`，脉冲2）：下坠滑音 + 爆。
pub fn sfx_hq_explode() -> Bytes {
  let notes : Array[Note] = [
    { f: 261.4, n: 3, },
    { f: 246.4, n: 3, },
    { f: 195.6, n: 3, },
    { f: 155.4, n: 3, },
    { f: 130.7, n: 3, },
    { f: 123.3, n: 3, },
    { f: 97.9, n: 3, },
    { f: 77.7, n: 3, },
    { f: 65.4, n: 3, },
  ]
  // 下坠滑音用三角波更像"塌"，再叠一层噪声爆收尾。
  let slide = render_triangle(notes, 0.5)
  let boom = render_noise(notes, 0.55, 0.15, 424242)
  wav(mix3(slide, boom, Array::make(slide.length(), 0.0)))
}
