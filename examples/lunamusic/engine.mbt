///|
/// 音频层错误（DESIGN.md C-04）：原生层错误码在壳的适配层里映射到这里，
/// 应用本体只见这三类。Unsupported 专指「本平台未实现」（Windows 半在
/// FP4 之前就是它），与加载/播放失败区分开。
pub(all) suberror AudioError {
  Unsupported
  LoadFailed(String)
  PlayFailed(String)
} derive(Debug)

///|
/// 应用侧的音频引擎接口（DESIGN.md C-06）：native 壳用原生 ABI 实现，
/// 测试用 MockAudioEngine。单位约定：时长/位置毫秒，音量千分位（0..1000）。
/// 单实例一次只装一首歌——load 新歌即换掉旧的。
pub(open) trait AudioEngine {
  /// 装上并读出元数据；失败时调用方退回 Track::from_path 的文件名兜底。
  fn load(Self, path : String) -> Track raise AudioError
  fn play(Self) -> Unit raise AudioError
  fn pause(Self) -> Unit
  fn unpause(Self) -> Unit raise AudioError
  fn stop(Self) -> Unit
  fn seek(Self, ms : Int64) -> Unit
  fn position(Self) -> Int64
  /// -1 = 未知。
  fn duration(Self) -> Int64
  fn set_volume(Self, permille : Int32) -> Unit
  fn is_playing(Self) -> Bool
  /// 自然播完回调（不含手动 stop/pause）；重复调用只换回调。
  fn on_finished(Self, cb : () -> Unit) -> Unit
  // ——第二期：频谱与均衡器（Luna那两块招牌零件）——
  /// 第 band 段的能量（0..1000 千分位）；没在播/本平台没有频谱都是 0。
  fn level(Self, band : Int32) -> Int32
  /// 均衡器段数：0 = 本平台没有 EQ，UI 侧据此不画假滑块。
  fn eq_band_count(Self) -> Int32
  /// 把整张增益表（milli-dB，±12000 = ±12dB）与旁路开关一次推下去。
  fn eq_apply(Self, bands : Array[Int32], enabled : Bool) -> Unit
}

///|
/// 测试用纯 MoonBit 引擎：记录调用序列（断言状态机的行为表），
/// position 用 step_ms 人工推进，「播完」用 fire_finished() 人工回放——
/// 无头测试的确定性来源（C-05 的约束 2）。
pub(all) struct MockAudioEngine {
  calls : Array[String]
  tracks : Map[String, Track]
  fail_load_paths : Array[String]
  mut playing : Bool
  mut loaded : Track?
  mut pos_ms : Int64
  mut volume : Int32
  mut finished_cb : (() -> Unit)?
  /// 频谱：测试侧可编排的段能量（level_probe 为空时恒 0）
  level_probe : Array[Int32]
  /// 均衡器：最后一次 eq_apply 的增益表与开关（断言用）
  eq_bands : Array[Int32]
  mut eq_on : Bool
}

///|
pub fn MockAudioEngine::new() -> MockAudioEngine {
  {
    calls: [],
    tracks: Map([]),
    fail_load_paths: [],
    playing: false,
    loaded: None,
    pos_ms: 0L,
    volume: 1000,
    finished_cb: None,
    level_probe: [],
    eq_bands: [],
    eq_on: false,
  }
}

///|
/// 预置一首歌的元数据（load 命中即返回），并指定 load 一定失败的路径。
pub fn MockAudioEngine::stub(
  self : MockAudioEngine,
  track : Track,
  fail_load : Array[String],
) -> Unit {
  self.tracks.set(track.path, track)
  for p in fail_load {
    self.fail_load_paths.push(p)
  }
}

///|
/// 人工回放「自然播完」：置停 + 触发回调，模拟原生层行为。
pub fn MockAudioEngine::fire_finished(self : MockAudioEngine) -> Unit {
  self.playing = false
  match self.finished_cb {
    Some(cb) => cb()
    None => ()
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn load(self, path : String) -> Track raise AudioError {
  self.calls.push("load:\{path}")
  for bad in self.fail_load_paths {
    if bad == path {
      raise LoadFailed(path)
    }
  }
  match self.tracks.get(path) {
    Some(t) => {
      self.loaded = Some(t)
      self.pos_ms = 0L
      t
    }
    None => raise LoadFailed(path)
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn play(self) -> Unit raise AudioError {
  self.calls.push("play")
  self.playing = true
}

///|
pub impl AudioEngine for MockAudioEngine with fn pause(self) -> Unit {
  self.calls.push("pause")
  self.playing = false
}

///|
pub impl AudioEngine for MockAudioEngine with fn unpause(self) -> Unit raise AudioError {
  self.calls.push("unpause")
  self.playing = true
}

///|
pub impl AudioEngine for MockAudioEngine with fn stop(self) -> Unit {
  self.calls.push("stop")
  self.playing = false
  self.pos_ms = 0L
}

///|
pub impl AudioEngine for MockAudioEngine with fn seek(self, ms : Int64) -> Unit {
  self.calls.push("seek:\{ms}")
  self.pos_ms = ms
}

///|
pub impl AudioEngine for MockAudioEngine with fn position(self) -> Int64 {
  self.pos_ms
}

///|
pub impl AudioEngine for MockAudioEngine with fn duration(self) -> Int64 {
  match self.loaded {
    Some(t) => t.duration_ms
    None => -1L
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn set_volume(
  self,
  permille : Int32,
) -> Unit {
  self.calls.push("volume:\{permille}")
  self.volume = permille
}

///|
pub impl AudioEngine for MockAudioEngine with fn is_playing(self) -> Bool {
  self.playing
}

///|
pub impl AudioEngine for MockAudioEngine with fn on_finished(
  self,
  cb : () -> Unit,
) -> Unit {
  self.calls.push("on_finished")
  self.finished_cb = Some(cb)
}

///|
/// 编排频谱：按段给能量（0..1000），给几段就有几段，其余读 0。
pub fn MockAudioEngine::set_levels(
  self : MockAudioEngine,
  levels : Array[Int32],
) -> Unit {
  self.level_probe.clear()
  for v in levels {
    self.level_probe.push(v)
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn level(self, band : Int32) -> Int32 {
  if band < 0 || band >= self.level_probe.length() {
    0
  } else {
    self.level_probe[band]
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn eq_band_count(_self) -> Int32 {
  10
}

///|
pub impl AudioEngine for MockAudioEngine with fn eq_apply(
  self,
  bands : Array[Int32],
  enabled : Bool,
) -> Unit {
  self.eq_bands.clear()
  for g in bands {
    self.eq_bands.push(g)
  }
  self.eq_on = enabled
}
