///|
/// 音频层错误（DESIGN.md C-04）：原生层错误码在壳的适配层里映射到这里，
/// 应用本体只见这三类。Unsupported 专指「本平台未实现」（Windows 半在
/// FP4 之前就是它），与加载/播放失败区分开。
#derive(Debug)
pub(all) suberror AudioError {
  Unsupported
  LoadFailed(String)
  PlayFailed(String)
}

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
  /// 播放速率（`T171`）：千分位，1000 = 原速。夹在 250..4000。
  ///
  /// **不 raise**：设不上不是错误。未实现的一侧（Windows 的 Media Foundation
  /// 还没接）静默忽略，界面上那颗"1.0x"照旧能点、只是不起作用——比弹一个
  /// "本平台不支持"更符合一个菜单项该有的分量。
  ///
  /// 保音高由后端负责（mac 走 `AVAudioUnitTimePitch`），Core 这一层只管传数字。
  fn set_rate(Self, permille : Int32) -> Unit
  /// 读回当前速率千分位（UI 侧据此打勾）。
  fn rate(Self) -> Int32
  fn is_playing(Self) -> Bool
  /// 自然播完回调（不含手动 stop/pause）；重复调用只换回调。
  fn on_finished(Self, cb : () -> Unit) -> Unit
  // ——无缝播放（`T168`）——
  /// 预排下一曲：EOS 之前就把下一段接在当前段后面（同一 player 串联），
  /// EOS 一到直接续上，不等「播完回调→load→play」那一圈。path = None 撤
  /// 预排（已链上的段由引擎侧挤掉）。
  ///
  /// **不 raise**：链不上不是错误。没在播、文件打不开、格式与当前曲不一致、
  /// 平台没接（Windows）都静默退现行路径——on_finished 照旧来，行为与今天
  /// 完全一致，只是衔接处多一个气口。
  fn prime_next(Self, path : String?) -> Unit
  /// 预排曲真正开始出声的回调（handoff）。与 on_finished **互斥**：预排
  /// 链上时 EOS 走这条不走那条；撤了预排/没预排成功，EOS 仍走 on_finished。
  /// handoff 时引擎已经接上预排曲（位置归零、播着不变）——应用侧只推进
  /// 「当前曲」指针，不 load 不 play。重复调用只换回调。
  fn on_primed_start(Self, cb : () -> Unit) -> Unit
  // ——音量归一化（`T170`）——
  /// 挂归一化增益（milli-dB，±12000 = ±12dB，0 = 直通）。**不 raise**：
  /// 未实现的一侧静默直通。换歌时引擎侧自动归零，新曲的增益由应用侧按
  /// 开关与测值现算现挂——测值缺席（未测/测不出）就挂 0，不猜。
  fn set_track_gain(Self, millidb : Int32) -> Unit
  // ——第二期：频谱与均衡器（Luna那两块招牌零件）——
  /// 第 band 段的能量（0..1000 千分位）；没在播/本平台没有频谱都是 0。
  fn level(Self, band : Int32) -> Int32
  /// 均衡器段数：0 = 本平台没有 EQ，UI 侧据此不画假滑块。
  fn eq_band_count(Self) -> Int32
  /// 把整张增益表（milli-dB，±12000 = ±12dB）与旁路开关一次推下去。
  fn eq_apply(Self, bands : Array[Int32], enabled : Bool) -> Unit
  // ——输出设备（`T169`，播放菜单的「输出设备」子菜单）——
  /// 系统音频输出设备名列表；**空 = 本平台枚举不出**（Windows 空桩），
  /// UI 侧据此不挂子菜单（降级，与 eq_band_count=0 同一条形状）。
  fn output_devices(Self) -> Array[String]
  /// 当前设备在列表里的下标；-1 = 未知。UI 侧据此打勾。
  fn output_current(Self) -> Int32
  /// 切到列表第 index 个设备。**返回是否成功**——不 raise：失败（越界/
  /// 底层拒绝/未实现）静默，菜单勾留在原处（与 set_rate 同一条分量判断）。
  fn set_output_device(Self, index : Int32) -> Bool
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
  /// 播放速率千分位（`T171`）：1000 = 原速，夹 250..4000
  mut rate_pm : Int32
  mut finished_cb : (() -> Unit)?
  /// 预排的下一曲 path（`T168`）。None = 没预排/已撤。mirror C 的门：
  /// 没在播时 Some 收不进去（C -1），pause/stop/load/seek 一律清。
  mut primed : String?
  /// handoff 回调（`T168`）：预排曲开始出声时触发，与 finished_cb 互斥
  mut primed_cb : (() -> Unit)?
  /// 频谱：测试侧可编排的段能量（level_probe 为空时恒 0）
  level_probe : Array[Int32]
  /// 均衡器：最后一次 eq_apply 的增益表与开关（断言用）
  eq_bands : Array[Int32]
  mut eq_on : Bool
  /// 输出设备（`T169`）：测试侧可编排的设备表与当前下标
  outputs : Array[String]
  mut output_idx : Int32
  /// 编排 set_output_device 失败（断言"失败静默、勾留在原处"）
  mut fail_output_set : Bool
  /// 归一化增益（`T170`）：最后一次 set_track_gain 的值（断言用）。
  /// load 会清零——mirror C 半"换歌归零"，应用侧换曲后现挂。
  mut track_gain : Int32
  /// 编排「这一侧整段没接」（`T38` 的错误码那一半）：真机上来自 ABI 的 -3
  /// （Windows 半的音频是 FP4 空桩，每个入口如实返回 -3），壳按 adapter.h 的
  /// 口径映射成 `Unsupported`。这里直接让 load/play/unpause 先抛这个，mirror
  /// 的是**平台没接**，不是「这个文件坏了」——文件坏了走 `fail_load_paths`。
  mut stub_unsupported_mode : Bool
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
    rate_pm: 1000,
    finished_cb: None,
    primed: None,
    primed_cb: None,
    level_probe: [],
    eq_bands: [],
    eq_on: false,
    outputs: [],
    output_idx: -1,
    fail_output_set: false,
    track_gain: 0,
    stub_unsupported_mode: false,
  }
}

///|
/// 置上「这一侧整段没接」：`load` / `play` / `unpause` 一律先 raise
/// `AudioError::Unsupported`，但**照旧记 calls**——判据要靠 calls 数调用次数
/// （平台没接时该一次止损，不许退化成逐首重试整队列）。
pub fn MockAudioEngine::stub_unsupported(self : MockAudioEngine) -> Unit {
  self.stub_unsupported_mode = true
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
///
/// 预排链着的时候（`T168`）EOS 不再是"播完"：引擎自己无缝接上预排曲——
/// 位置归零、播着不变、**不发 load/play**（这正是判据"不重 load"的来源），
/// 通知走 primed_cb 而不是 finished_cb。预排的 path 没登记过（stub 缺席）
/// 与 C 的 -2 同款：退回"自然播完"老路。
pub fn MockAudioEngine::fire_finished(self : MockAudioEngine) -> Unit {
  match self.primed {
    Some(p) =>
      match self.tracks.get(p) {
        Some(t) => {
          self.loaded = Some(t)
          self.pos_ms = 0L
          self.primed = None
          match self.primed_cb {
            Some(cb) => {
              cb()
              return
            }
            None => () // 没人接 handoff：照旧走播完（不丢事件）
          }
        }
        None => () // 预排曲装不上：退回自然播完
      }
    None => ()
  }
  self.playing = false
  match self.finished_cb {
    Some(cb) => cb()
    None => ()
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn load(self, path : String) -> Track raise AudioError {
  self.calls.push("load:\{path}")
  if self.stub_unsupported_mode {
    raise Unsupported
  }
  for bad in self.fail_load_paths {
    if bad == path {
      raise LoadFailed(path)
    }
  }
  match self.tracks.get(path) {
    Some(t) => {
      self.loaded = Some(t)
      self.pos_ms = 0L
      // 换歌清预排（`T168`，mirror C）：新歌自己的"下一首"由调用方重算
      self.primed = None
      // 换歌增益归零（`T170`，mirror C）：新曲的增益由应用侧现算现挂
      self.track_gain = 0
      t
    }
    None => raise LoadFailed(path)
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn play(self) -> Unit raise AudioError {
  self.calls.push("play")
  if self.stub_unsupported_mode {
    raise Unsupported
  }
  self.playing = true
}

///|
pub impl AudioEngine for MockAudioEngine with fn pause(self) -> Unit {
  self.calls.push("pause")
  self.playing = false
  // 暂停清预排（`T168`，mirror C）：node stop 把链上的段一起丢掉
  self.primed = None
}

///|
pub impl AudioEngine for MockAudioEngine with fn unpause(self) -> Unit raise AudioError {
  self.calls.push("unpause")
  if self.stub_unsupported_mode {
    raise Unsupported
  }
  self.playing = true
}

///|
pub impl AudioEngine for MockAudioEngine with fn stop(self) -> Unit {
  self.calls.push("stop")
  self.playing = false
  self.pos_ms = 0L
  self.primed = None
}

///|
pub impl AudioEngine for MockAudioEngine with fn seek(self, ms : Int64) -> Unit {
  self.calls.push("seek:\{ms}")
  self.pos_ms = ms
  // seek 清预排（`T168`，mirror C）：排段入口作废旧令牌、丢弃链上的段
  self.primed = None
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
/// 与 C 侧同一套夹法（250..4000）：mock 也夹，否则无头判据验的是"没夹"的
/// 那个世界，真机上用户看到的又是另一个。
pub impl AudioEngine for MockAudioEngine with fn set_rate(
  self : MockAudioEngine,
  permille : Int32,
) -> Unit {
  self.calls.push("rate:\{permille}")
  let mut p = permille
  if p < 250 {
    p = 250
  }
  if p > 4000 {
    p = 4000
  }
  self.rate_pm = p
}

///|
pub impl AudioEngine for MockAudioEngine with fn rate(self : MockAudioEngine) -> Int32 {
  self.rate_pm
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
/// 预排（`T168`）：mirror C 的门——没在播时 Some 收不进去（C -1 静默），
/// None 恒撤。
pub impl AudioEngine for MockAudioEngine with fn prime_next(
  self,
  path : String?,
) -> Unit {
  match path {
    Some(p) => if self.playing { self.primed = Some(p) }
    None => self.primed = None
  }
}

///|
pub impl AudioEngine for MockAudioEngine with fn on_primed_start(
  self,
  cb : () -> Unit,
) -> Unit {
  self.calls.push("on_primed_start")
  self.primed_cb = Some(cb)
}

///|
/// 归一化增益（`T170`）：mock 与 C 同式同夹（±12000），calls 记一笔、
/// track_gain 存最后一挂的值。
pub impl AudioEngine for MockAudioEngine with fn set_track_gain(
  self : MockAudioEngine,
  millidb : Int32,
) -> Unit {
  let mut g = millidb
  if g < -12000 {
    g = -12000
  }
  if g > 12000 {
    g = 12000
  }
  self.calls.push("gain:\{g}")
  self.track_gain = g
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

///|
/// 编排输出设备表（`T169`）：给设备名与当前下标（-1 = 没有当前）。
pub fn MockAudioEngine::stub_outputs(
  self : MockAudioEngine,
  names : Array[String],
  current : Int32,
) -> Unit {
  self.outputs.clear()
  for n in names {
    self.outputs.push(n)
  }
  self.output_idx = current
}

///|
pub impl AudioEngine for MockAudioEngine with fn output_devices(
  self : MockAudioEngine,
) -> Array[String] {
  self.outputs
}

///|
pub impl AudioEngine for MockAudioEngine with fn output_current(
  self : MockAudioEngine,
) -> Int32 {
  self.output_idx
}

///|
pub impl AudioEngine for MockAudioEngine with fn set_output_device(
  self : MockAudioEngine,
  index : Int32,
) -> Bool {
  self.calls.push("set_output_device:\{index}")
  if self.fail_output_set {
    return false
  }
  if index < 0 || index >= self.outputs.length() {
    return false
  }
  self.output_idx = index
  true
}
