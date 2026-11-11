///|
/// NativeAudioEngine：AudioEngine → moonui_native_audio_*（adapter.h 音频段）。
/// load 合成「装歌 + 读元数据」两口（C-06）：先探针拿 Track（读不出退文件名），
/// 再把歌装进播放器。
///
/// `T253` 之前这段住在共享装配壳（`../lunamusic-shell`），壳于是整包绑在
/// `@native-common` 上——换第三个后端时失联的是整只壳，不只是音频。现在音频与
/// 宿主能力都收在这一包，共享壳只收 `@lunamusic.AppHost[B]` 与一只 `AudioEngine`。
pub(all) enum NativeAudioEngine {
  Instance
} // 进程级单例：播放器在 C 侧，MoonBit 这侧只是 trait 的载体

///|
/// 进程级单例的取用口：共享壳经参数拿到它，不再自己 import 后端。
pub fn audio_engine() -> NativeAudioEngine {
  Instance
}

///|
fn probe_track(path : String) -> @lunamusic.Track {
  match @native-common.native_audio_probe(path) {
    Some(packed) =>
      match @lunamusic.track_from_probe(path, packed) {
        Some(t) => t
        None => @lunamusic.Track::from_path(path)
      }
    None => @lunamusic.Track::from_path(path)
  }
}

///|
/// ABI 返回码 → `AudioError`（`T18` 方案 (a) 里错误码那一半第一次真被走到）。
///
/// `adapter.h` 音频段的统一口径是 0 成功 / -1 参数残缺 / -2 底层调用失败 /
/// **-3 = 本平台未实现**。此前共享层一处都没读这个码：Windows 的音频整段是
/// FP4 空桩、每个入口如实返回 -3，而壳把 -3 报成 `LoadFailed`——「这侧根本没
/// 接」在界面上长成了「这个文件坏了」。现在只有 -3 改道 `Unsupported`。
///
/// mac 的 -2（文件读不出、解码不了，出处是 `adapter_native.m` 的
/// `moonui_ae_load_ogg` → `moonui_ae_decode_ogg`）照旧归 `LoadFailed`：那确实
/// 是某一首文件的问题，该走逐首跳的恢复路径。
///
/// 纯函数、不碰 C：两侧返回码本来就不同，码表判据钉在这里（audio_wbtest.mbt），
/// 真码按平台钉在各自的后端测试里（`T18` 的分叉口径）。
fn audio_load_error(rc : Int32, path : String) -> @lunamusic.AudioError {
  if rc == -3 {
    @lunamusic.AudioError::Unsupported
  } else {
    @lunamusic.AudioError::LoadFailed(path)
  }
}

///|
/// `play` / `unpause` 那一支，规则同上。
fn audio_play_error(rc : Int32, op : String) -> @lunamusic.AudioError {
  if rc == -3 {
    @lunamusic.AudioError::Unsupported
  } else {
    @lunamusic.AudioError::PlayFailed(op)
  }
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn load(
  _ : NativeAudioEngine,
  path : String,
) -> @lunamusic.Track raise @lunamusic.AudioError {
  let track = probe_track(path)
  let rc = @native-common.native_audio_load(path)
  if rc != 0 {
    raise audio_load_error(rc, path)
  }
  track
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn play(
  _ : NativeAudioEngine,
) -> Unit raise @lunamusic.AudioError {
  let rc = @native-common.native_audio_play()
  if rc != 0 {
    raise audio_play_error(rc, "play")
  }
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn pause(
  _ : NativeAudioEngine,
) -> Unit {
  let _ = @native-common.native_audio_pause()
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn unpause(
  _ : NativeAudioEngine,
) -> Unit raise @lunamusic.AudioError {
  let rc = @native-common.native_audio_play()
  if rc != 0 {
    raise audio_play_error(rc, "unpause")
  }
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn stop(
  _ : NativeAudioEngine,
) -> Unit {
  let _ = @native-common.native_audio_stop()
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn seek(
  _ : NativeAudioEngine,
  ms : Int64,
) -> Unit {
  let _ = @native-common.native_audio_seek_ms(ms)
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn position(
  _ : NativeAudioEngine,
) -> Int64 {
  @native-common.native_audio_position_ms()
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn duration(
  _ : NativeAudioEngine,
) -> Int64 {
  @native-common.native_audio_duration_ms()
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn set_volume(
  _ : NativeAudioEngine,
  permille : Int32,
) -> Unit {
  let _ = @native-common.native_audio_set_volume(permille)
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn is_playing(
  _ : NativeAudioEngine,
) -> Bool {
  @native-common.native_audio_is_playing()
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn set_rate(
  _ : NativeAudioEngine,
  permille : Int32,
) -> Unit {
  // 返回 -3（本平台没接）就静默收下：UI 那颗菜单项照常能点，只是不起作用
  let _ = @native-common.native_audio_set_rate(permille)
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn rate(
  _ : NativeAudioEngine,
) -> Int32 {
  @native-common.native_audio_rate()
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn on_finished(
  _ : NativeAudioEngine,
  cb : () -> Unit,
) -> Unit {
  let _ = @native-common.native_audio_on_finished(Some(cb))
}

///|
/// 预排下一曲（`T168`）：mac 真 ABI，Windows 返 -3 静默退现行路径
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn prime_next(
  _ : NativeAudioEngine,
  path : String?,
) -> Unit {
  match path {
    Some(p) => {
      let _ = @native-common.native_audio_prime(p)
    }
    None => {
      let _ = @native-common.native_audio_prime_clear()
    }
  }
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn on_primed_start(
  _ : NativeAudioEngine,
  cb : () -> Unit,
) -> Unit {
  let _ = @native-common.native_audio_on_primed(Some(cb))
}

///|
/// 归一化增益（`T170`）：毫分贝直接转给 C 半的链上 EQ；换歌时 Player 会先
/// 调 0（C 半 load 已归零，这里对账）再按测值补挂。Windows 半是空桩直通。
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn set_track_gain(
  _ : NativeAudioEngine,
  millidb : Int32,
) -> Unit {
  let _ = @native-common.native_audio_set_track_gain(millidb)
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn level(
  _ : NativeAudioEngine,
  band : Int32,
) -> Int32 {
  @native-common.native_audio_level(band)
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn eq_band_count(
  _ : NativeAudioEngine,
) -> Int32 {
  @native-common.native_audio_eq_band_count()
}

///|
/// 整张表一次推下去：逐段 set + 开关。段数为 0（Windows 半）时什么都不做——
/// 那边没有 EQ，UI 侧也不画滑块。
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn eq_apply(
  _ : NativeAudioEngine,
  bands : Array[Int32],
  enabled : Bool,
) -> Unit {
  for i, g in bands {
    let _ = @native-common.native_audio_eq_set_band(i, g)
  }
  let _ = @native-common.native_audio_eq_set_enabled(enabled)
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn output_devices(
  _ : NativeAudioEngine,
) -> Array[String] {
  @native-common.native_audio_output_list().devices
}

///|
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn output_current(
  _ : NativeAudioEngine,
) -> Int32 {
  @native-common.native_audio_output_list().current
}

///|
/// 失败（越界/-2/-3）静默：菜单勾留在原处，UI 侧拿 output_current 重读即真。
pub impl @lunamusic.AudioEngine for NativeAudioEngine with fn set_output_device(
  _ : NativeAudioEngine,
  index : Int32,
) -> Bool {
  @native-common.native_audio_output_set(index) == 0
}

///|
/// 组装共享壳要的宿主能力束（`T253`）：五条非音频入口 + 音频探针/响度。
///
/// `B` 只出现在 `worker_run` 的 App 参数上，调用点（两个 native 壳）按 App 的
/// 实际后端类型推断；`lunamusic-shell.launch` 的签名接得住。两壳都在构造它的
/// 同一作用域里立即交给 `launch`，所以不会出现"裸 let 退化成 Unit"的推断。
pub fn[B] app_host() -> @lunamusic.AppHost[B] {
  {
    now_ms: fn() { @native-common.native_time_ms() },
    worker_run: (app, work, land) => @native-common.worker_run(app, work, land),
    walk_dir: fn(path) { @native-common.native_walk_dir(path) },
    snapshot_all: fn(dir) { @native-common.native_snapshot_all(dir) },
    probe_track: fn(path) { probe_track(path) },
    loudness_start: fn(path) {
      @native-common.native_audio_loudness_start(path)
    },
    loudness_on: fn(cb) { let _ = @native-common.native_audio_on_loudness(cb) },
  }
}

///|
/// 把 trait 方法提升成 `NativeAudioEngine` 的普通方法：否则 22 个 `pub impl`
/// 方法会被隐式提升并触发 `implicit_impl_as_method` 弃用警告。形状与
/// `backends/native-common/backend.mbt` 末尾那两条一致。
pub extend NativeAudioEngine with @lunamusic.AudioEngine::{
  load,
  play,
  pause,
  unpause,
  stop,
  seek,
  position,
  duration,
  set_volume,
  is_playing,
  set_rate,
  rate,
  on_finished,
  prime_next,
  on_primed_start,
  set_track_gain,
  level,
  eq_band_count,
  eq_apply,
  output_devices,
  output_current,
  set_output_device,
}
