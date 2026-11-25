///|
/// 8-bit 风格音效合成（Tank 1990 复刻）。纯函数：不碰 UI/后端，可白盒测。
/// 输出 16-bit PCM 单声道 22050Hz 的 WAV 字节，交给
/// `@native-common.native_sfx_play` 播。方波 + 白噪声 + 线性包络，全是
/// 整数/基础浮点运算，不依赖 math 包。
pub const SFX_RATE : Int32 = 22050

///|
/// 确定性 LCG（噪声源）：测试可复现、听感近似白噪。
fn lcg(seed : Int64) -> Int64 {
  seed * 6364136223846793005 + 1442695040888963407
}

///|
/// 一个方波音：从 freq_start Hz 线性滑到 freq_end，时长 dur 秒，幅度 amp，
/// 线性包络（头/尾各 decay 秒内升降，不足全曲则各占一半）。
fn square_sweep(
  freq_start : Double,
  freq_end : Double,
  dur : Double,
  amp : Double,
  decay : Double,
) -> Array[Double] {
  let n = (dur * SFX_RATE.to_double()).to_int()
  let rate = SFX_RATE.to_double()
  let out = Array::make(n, 0.0)
  let mut phase = 0.0
  for i in 0..<n {
    let t = i.to_double() / rate
    let frac = if dur > 0.0 { t / dur } else { 0.0 }
    let freq = freq_start + (freq_end - freq_start) * frac
    // 方波：相位在 [0,1) 里走，过 1 折回（freq < rate/2 时一次就够）
    phase = phase + freq / rate
    if phase >= 1.0 {
      phase = phase - 1.0
    }
    let v = if phase < 0.5 { 1.0 } else { -1.0 }
    // 包络：上升 decay 秒、下降 decay 秒，中间 1.0
    let env = if dur > 0.0 && decay > 0.0 {
      let up = (t / decay).clamp(min=0.0, max=1.0)
      let dn = ((dur - t) / decay).clamp(min=0.0, max=1.0)
      up * dn
    } else {
      0.0
    }
    out[i] = v * amp * env
  }
  out
}

///|
/// 白噪声爆：时长 dur 秒、幅度 amp、线性衰减（尾 decay 秒内掉到 0）。
fn noise_burst(
  dur : Double,
  amp : Double,
  decay : Double,
  seed : Int64,
) -> Array[Double] {
  let n = (dur * SFX_RATE.to_double()).to_int()
  let rate = SFX_RATE.to_double()
  let out = Array::make(n, 0.0)
  let mut s = seed
  for i in 0..<n {
    s = lcg(s)
    // 取高 31 位归一化到 [-1,1)
    let u = (s >> 33).to_double() / 2147483648.0 - 1.0
    let t = i.to_double() / rate
    let env = if dur > 0.0 && decay > 0.0 {
      ((dur - t) / decay).clamp(min=0.0, max=1.0)
    } else {
      0.0
    }
    out[i] = u * amp * env
  }
  out
}

///|
/// 把一串音首尾拼接（各段用 5ms 静音隔开）。
fn concat_sounds(parts : Array[Array[Double]]) -> Array[Double] {
  let gap = (0.005 * SFX_RATE.to_double()).to_int()
  let mut total = 0
  for p in parts {
    total += p.length() + gap
  }
  let out = Array::make(total, 0.0)
  let mut w = 0
  for p in parts {
    for i in 0..<p.length() {
      out[w + i] = p[i]
    }
    w += p.length() + gap
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
/// 移动履带声：低频方波短震（0.10s，55Hz）。
pub fn sfx_move() -> Bytes {
  wav(square_sweep(55.0, 55.0, 0.10, 0.30, 0.06))
}

///|
/// 发射子弹：方波下滑 700→160Hz（0.14s）。
pub fn sfx_shoot() -> Bytes {
  wav(square_sweep(700.0, 160.0, 0.14, 0.50, 0.08))
}

///|
/// 子弹打墙：低频方波 + 一点噪声（0.09s）。
pub fn sfx_hit_wall() -> Bytes {
  let tone = square_sweep(180.0, 120.0, 0.09, 0.50, 0.05)
  let noise = noise_burst(0.09, 0.35, 0.05, 1234567)
  let mix = Array::make(tone.length(), 0.0)
  for i in 0..<tone.length() {
    let nv = if i < noise.length() { noise[i] } else { 0.0 }
    mix[i] = (tone[i] + nv).clamp(min=-1.0, max=1.0)
  }
  wav(mix)
}

///|
/// 坦克爆炸（击杀/玩家阵亡）：白噪声爆（0.42s，长衰减）。
pub fn sfx_explode() -> Bytes {
  wav(noise_burst(0.42, 0.75, 0.30, 987654))
}

///|
/// 装甲坦克掉一格血：金属"叮"——高频方波（0.12s）。
pub fn sfx_armor() -> Bytes {
  wav(square_sweep(1100.0, 1000.0, 0.12, 0.50, 0.07))
}

///|
/// 暂停：两个下行音符（740→370Hz）。
pub fn sfx_pause() -> Bytes {
  let a = square_sweep(740.0, 740.0, 0.12, 0.45, 0.06)
  let b = square_sweep(370.0, 370.0, 0.12, 0.45, 0.06)
  wav(concat_sounds([a, b]))
}

///|
/// 继续（取消暂停）：两个上行音符（370→740Hz）。
pub fn sfx_resume() -> Bytes {
  let a = square_sweep(370.0, 370.0, 0.12, 0.45, 0.06)
  let b = square_sweep(740.0, 740.0, 0.12, 0.45, 0.06)
  wav(concat_sounds([a, b]))
}

///|
/// 每关开场音乐：四音小旋律（660→880→740→1100，各 0.18s）。
pub fn sfx_stage_intro() -> Bytes {
  let notes = [660.0, 880.0, 740.0, 1100.0]
  let parts : Array[Array[Double]] = []
  for f in notes {
    parts.push(square_sweep(f, f, 0.18, 0.45, 0.09))
  }
  wav(concat_sounds(parts))
}

///|
/// 游戏失败音乐：五个下行音符（880→740→660→440→330，各 0.24s）。
pub fn sfx_game_over() -> Bytes {
  let notes = [880.0, 740.0, 660.0, 440.0, 330.0]
  let parts : Array[Array[Double]] = []
  for f in notes {
    parts.push(square_sweep(f, f, 0.24, 0.45, 0.12))
  }
  wav(concat_sounds(parts))
}
