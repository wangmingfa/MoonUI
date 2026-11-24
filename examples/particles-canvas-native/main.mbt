///|
/// 120Hz 粒子沙盒（T367）：自绘后端上的一块整窗自绘面，每帧重建一份
/// DrawList。CanvasBackend 的整帧重绘没有增量账，屏幕上量到的 FPS 就是
/// "模拟 + 重建清单 + 画布配方 + present" 的端到端读数。
///
/// 右下角是运行时控制台：常用窗口尺寸一键切换、最大帧率（60/90/120）与
/// 垂直同步开关——都是为了在同一台机器上量不同窗口面积 / 不同节拍的帧率。
/// 最大帧率走 `CanvasBackend::set_max_fps`（不调用默认 60），垂直同步走
/// `CanvasBackend::set_vsync`（默认开）。
///
/// `PARTICLES_BENCH_MS=5000` 跑满 5 秒后打印帧率统计并退出；
/// `PARTICLES_HZ` 覆盖启动时的最大帧率（不设就走 API 默认的 60）。

///|
let max_particles : Int32 = 40000

///|
let default_particles : Int32 = 8000

///|
let view_w : Double = 640.0

///|
let view_h : Double = 480.0

///|
/// 常用窗口尺寸的快速切换档（逻辑像素）：性能随面积线性掉，量几个典型档
/// 就能看出这一版的自绘上限在哪。
let size_labels : Array[String] = [
  "640×480", "800×600", "1024×768", "1280×800", "1440×900", "1080P", "2K", "4K",
]

///|
let size_ws : Array[Int32] = [640, 800, 1024, 1280, 1440, 1920, 2560, 3840]

///|
let size_hs : Array[Int32] = [480, 600, 768, 800, 900, 1080, 1440, 2160]

///|
/// 尺寸档数：`size_labels` / `size_ws` / `size_hs` 三份同长的账，按钮 id
/// 0..7 都是窗口尺寸。超出工作区的档在点击时夹到工作区（4K 在小屏上等于
/// 铺满可用区域）。
let size_count : Int32 = 8

///|
let fps_options : Array[Int32] = [60, 90, 120]

///|
/// 控制面板的尺寸（逻辑像素）。
let panel_w : Double = 372.0

///|
let panel_h : Double = 112.0

///|
/// 控制面板上的一个按钮：`id` 0..7 = 窗口尺寸档，10..12 = 最大帧率档，
/// 20 = 垂直同步开关。矩形与 `paint` 共用（`button_layout`），点击命中才
/// 不会和画面错位。
struct Btn {
  id : Int32
  x : Double
  y : Double
  w : Double
  h : Double
}

///|
/// 面板锚在右下角（左上角已经有 HUD）：窗口再窄也不会盖住读数。
fn panel_origin(w : Double, h : Double) -> (Double, Double) {
  (w - panel_w - 16.0, h - panel_h - 40.0)
}

///|
fn button_layout(w : Double, h : Double) -> Array[Btn] {
  let (px, py) = panel_origin(w, h)
  let out : Array[Btn] = []
  // 尺寸档两行各 4 个（3 行布局比把 8 个挤成一行更省窗口宽度）
  for i in 0..<size_count {
    let col = i % 4
    let row = i / 4
    out.push(Btn::{
      id: i,
      x: px + 52.0 + col.to_double() * 80.0,
      y: py + 10.0 + row.to_double() * 28.0,
      w: 68.0,
      h: 24.0,
    })
  }
  for i in 0..<3 {
    out.push(Btn::{
      id: 10 + i,
      x: px + 52.0 + i.to_double() * 60.0,
      y: py + 68.0,
      w: 56.0,
      h: 24.0,
    })
  }
  out.push(Btn::{ id: 20, x: px + 264.0, y: py + 68.0, w: 96.0, h: 24.0, })
  out
}

///|
/// 这一档放不放得进当前屏的工作区：放不进就禁用（点了也只会被夹成整屏，
/// 与更大的档落成同一个尺寸）。
fn size_fits(state : Sandbox, id : Int32) -> Bool {
  !(state.work_w > 0.0 &&
  (
    size_ws[id].to_double() > state.work_w ||
    size_hs[id].to_double() > state.work_h
  ))
}

///|
fn hit_button(btns : Array[Btn], x : Double, y : Double) -> Int32 {
  for b in btns {
    if x >= b.x && x < b.x + b.w && y >= b.y && y < b.y + b.h {
      return b.id
    }
  }
  -1
}

///|
struct ParticleWorld {
  mut n : Int32
  mut seed : Int64
  /// 当前画布尺寸（逻辑像素）：每帧 paint 从 env 回写，窗口缩放后模拟区跟着变。
  mut w : Double
  mut h : Double
  xs : Array[Double]
  ys : Array[Double]
  vxs : Array[Double]
  vys : Array[Double]
}

///|
fn ParticleWorld::next_unit(self : ParticleWorld) -> Double {
  self.seed = self.seed * 48271L % 2147483647L
  self.seed.to_double() / 2147483647.0
}

///|
fn ParticleWorld::new(count : Int32) -> ParticleWorld {
  let w = ParticleWorld::{
    n: count,
    seed: 12345L,
    w: view_w,
    h: view_h,
    xs: [],
    ys: [],
    vxs: [],
    vys: [],
  }
  for _i in 0..<max_particles {
    w.xs.push(0.0)
    w.ys.push(0.0)
    w.vxs.push(0.0)
    w.vys.push(0.0)
  }
  w.reset()
  w
}

///|
/// 重置到同一种子：位置与速度确定可复现，`R` 两次得到同一片沙。
fn ParticleWorld::reset(self : ParticleWorld) -> Unit {
  self.seed = 12345L
  for i in 0..<max_particles {
    self.xs[i] = self.next_unit() * self.w
    self.ys[i] = self.next_unit() * self.h
    self.vxs[i] = (self.next_unit() * 2.0 - 1.0) * 180.0
    self.vys[i] = (self.next_unit() * 2.0 - 1.0) * 180.0
  }
}

///|
/// 固定 dt 推进一步：鼠标力场（默认斥力、按住左键变引力）→ 阻尼 →
/// 速度限幅 → 边界环绕。
fn ParticleWorld::step(
  self : ParticleWorld,
  mx : Double,
  my : Double,
  inside : Bool,
  attract : Bool,
) -> Unit {
  let dt = 1.0 / 120.0
  let radius = 220.0
  let r2 = radius * radius
  let strength = if attract { 3200.0 } else { -4200.0 }
  let max_speed = 900.0
  for i in 0..<self.n {
    let x = self.xs[i]
    let y = self.ys[i]
    let mut vx = self.vxs[i]
    let mut vy = self.vys[i]
    if inside {
      let dx = mx - x
      let dy = my - y
      let d2 = dx * dx + dy * dy
      if d2 < r2 {
        let d = if d2 < 1.0 { 1.0 } else { d2.sqrt() }
        let falloff = 1.0 - d / radius
        let a = strength * falloff * falloff / d
        vx = vx + dx * a * dt
        vy = vy + dy * a * dt
      }
    }
    // 只做极轻的阻尼：0.992 那种每秒掉 60% 的速度会让粒子几秒内就冻住，
    // 看起来像"不会动"。这里每秒只掉约 6%，力场仍有空间加/减能量。
    vx = vx * 0.9995
    vy = vy * 0.9995
    let sp = (vx * vx + vy * vy).sqrt()
    if sp > max_speed {
      vx = vx * max_speed / sp
      vy = vy * max_speed / sp
    }
    let mut nx = x + vx * dt
    let mut ny = y + vy * dt
    if nx < 0.0 {
      nx = nx + self.w
    }
    if nx >= self.w {
      nx = nx - self.w
    }
    if ny < 0.0 {
      ny = ny + self.h
    }
    if ny >= self.h {
      ny = ny - self.h
    }
    self.xs[i] = nx
    self.ys[i] = ny
    self.vxs[i] = vx
    self.vys[i] = vy
  }
}

///|
/// 速度分四档上色：越快的粒子越亮，120Hz 下拖尾感主要靠这层色差。
fn speed_color(vx : Double, vy : Double) -> Int32 {
  let s2 = vx * vx + vy * vy
  if s2 < 14400.0 {
    0x3B4B7A
  } else if s2 < 90000.0 {
    0x38BDF8
  } else if s2 < 360000.0 {
    0xA78BFA
  } else {
    0xF472B6
  }
}

///|
struct Monitor {
  mut last : Int32
  mut frames : Int32
  mut acc : Int32
  mut fps : Double
  mut paint_ms : Double
  mut total : Int32
  mut elapsed : Int32
  mut dropped : Int32
  mut cmds : Int32
  mut worst : Double
  mut hud_tick : Int32
  mut hud_fps : String
  mut hud_paint : String
  mut hud_count : String
  mut hud_draw : String
  mut hud_mode : String
}

///|
struct Sandbox {
  mut paused : Bool
  mut attract : Bool
  mut quit : Bool
  mut mx : Double
  mut my : Double
  mut inside : Bool
  /// 当前窗口尺寸档（-1 = 手动拖过，不对应任何预设）。
  mut size_idx : Int32
  /// 控制面板回显的最大帧率 / 垂直同步（真值在 CanvasBackend 上）。
  mut max_fps : Int32
  mut vsync : Bool
  /// 当前实际用的拍长（毫秒）：`present_interval_ms()` 的结果，面板底部回显。
  mut pace_ms : Int32
  /// 当前屏幕工作区的尺寸（逻辑像素）：比它大的尺寸档在面板上禁点——那些档
  /// 夹到工作区后尺寸一模一样（2K 与 4K 在小屏上都是整屏），没有可切的语义。
  mut work_w : Double
  mut work_h : Double
}

///|
/// 帧节拍的自调度器。CanvasBackend 的真绘制发生在 poll_event 的脏窗重绘里，
/// 不在 tick 任务内，所以 `post_animation` 的"扣掉本拍已用"扣不到这块耗时——
/// 实际周期会变成 interval + 绘制。这里按上一拍实测的 `周期 - 上次 delay`
/// 低通估计绘制成本，再从下一拍 delay 里扣掉，让周期贴着目标走。
struct Runner {
  app : @moonui.App[@canvas-macos.CanvasBackend]
  backend : @canvas-macos.CanvasBackend
  win : @moonui.Window[@canvas-macos.CanvasBackend]
  face : @moonui.Widget[@canvas-macos.CanvasBackend]
  world : ParticleWorld
  mon : Monitor
  state : Sandbox
  intervals : Array[Int32]
  bench_ms : Int32
  mut delay : Int32
  mut draw_est : Double
}

///|
fn fixed1(v : Double) -> String {
  let n = (v * 10.0 + 0.5).to_int()
  "\{n / 10}.\{n % 10}"
}

///|
fn percentile(sorted : Array[Int32], p : Double) -> Double {
  let len = sorted.length()
  if len == 0 {
    return 0.0
  }
  let raw = (len.to_double() * p).to_int()
  let i = if raw < 0 { 0 } else if raw >= len { len - 1 } else { raw }
  sorted[i].to_double()
}

///|
/// HUD 文案每 10 帧刷一次：读数不需要逐帧变，省下的是每帧的字符串分配。
fn refresh_hud(mon : Monitor, n : Int32, state : Sandbox) -> Unit {
  mon.hud_fps = "FPS  \{fixed1(mon.fps)}"
  mon.hud_paint = "PAINT  \{fixed1(mon.paint_ms)} ms"
  mon.hud_count = "PARTICLES  \{n}"
  mon.hud_draw = "CMDS  \{mon.cmds}   DROPPED  \{mon.dropped}"
  mon.hud_mode = if state.paused {
    "PAUSED"
  } else if state.attract {
    "引力 · 松开左键回到斥力"
  } else {
    "斥力 · 按住左键改吸引"
  }
}

///|
fn paint(
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
  world : ParticleWorld,
  mon : Monitor,
  state : Sandbox,
) -> Unit {
  let w = env.width()
  let h = env.height()
  // 窗口缩放后布局会把新尺寸通过 PaintEnv 送进来：模拟区跟画布同尺寸，
  // 否则粒子只会在最初那块 640×480 里打转，看着像"画布没自适应"。
  world.w = w
  world.h = h
  dl.fill_rect(0.0, 0.0, w, h, radius=0.0, rgb=0x080B12)
  dl.fill_rect(0.0, 0.0, w, 2.0, radius=0.0, rgb=0x38BDF8)
  for i in 0..<world.n {
    dl.fill_rect(
      world.xs[i] - 1.0,
      world.ys[i] - 1.0,
      2.0,
      2.0,
      radius=0.0,
      rgb=speed_color(world.vxs[i], world.vys[i]),
    )
  }
  // HUD：左上角一块半透面板，读数全部来自 Monitor 的缓存文案。
  dl.fill_rect(16.0, 16.0, 280.0, 116.0, radius=10.0, rgb=0x111827, alpha=216)
  dl.stroke_rect(16.0, 16.0, 280.0, 116.0, radius=10.0, width=1.0, rgb=0x24324A)
  dl.text("PARTICLES", 30.0, 26.0, size=16.0, bold=true, rgb=0xE8F0FC)
  dl.text(mon.hud_mode, 30.0, 48.0, size=10.0, rgb=0x8FA3BF)
  dl.text(mon.hud_fps, 30.0, 66.0, size=13.0, bold=true, rgb=0x4ADE80)
  dl.text(mon.hud_paint, 150.0, 68.0, size=11.0, rgb=0x9AAAC2)
  dl.text(mon.hud_count, 30.0, 88.0, size=11.0, rgb=0x9AAAC2)
  dl.text(mon.hud_draw, 30.0, 106.0, size=11.0, rgb=0x9AAAC2)
  dl.text(
    "＋ / － 粒子数   P 暂停   R 重置   Esc 退出",
    16.0,
    h - 24.0,
    size=11.0,
    rgb=0x64748B,
  )
  paint_controls(dl, w, h, state)
  mon.cmds = dl.len()
}

///|
/// 右下角控制台：窗口尺寸档 + 最大帧率档 + 垂直同步开关。矩形全从
/// `button_layout` 来，和点击命中是同一份账。
fn paint_controls(
  dl : @moonui.DrawList,
  w : Double,
  h : Double,
  state : Sandbox,
) -> Unit {
  let (px, py) = panel_origin(w, h)
  dl.fill_rect(px, py, panel_w, panel_h, radius=10.0, rgb=0x111827, alpha=216)
  dl.stroke_rect(px, py, panel_w, panel_h, radius=10.0, width=1.0, rgb=0x24324A)
  dl.text("窗口", px + 12.0, py + 15.0, size=11.0, rgb=0x8FA3BF)
  dl.text("FPS", px + 12.0, py + 73.0, size=11.0, rgb=0x8FA3BF)
  let pace = if state.pace_ms > 0 { state.pace_ms } else { 1 }
  dl.text(
    "实际 \{1000 / pace} fps · 拍长 \{pace} ms",
    px + 12.0,
    py + 96.0,
    size=9.0,
    rgb=0x64748B,
  )
  for b in button_layout(w, h) {
    // 比屏幕大的尺寸档禁用：灰底灰字，点了不响应。
    let off = b.id < size_count && !size_fits(state, b.id)
    let active = if b.id < size_count {
      state.size_idx == b.id && !off
    } else if b.id < 20 {
      state.max_fps == fps_options[b.id - 10]
    } else {
      state.vsync
    }
    let label = if b.id < size_count {
      size_labels[b.id]
    } else if b.id < 20 {
      "\{fps_options[b.id - 10]}"
    } else if state.vsync {
      "VSYNC ON"
    } else {
      "VSYNC OFF"
    }
    dl.fill_rect(
      b.x,
      b.y,
      b.w,
      b.h,
      radius=7.0,
      rgb=if off { 0x141B26 } else if active { 0x1D4ED8 } else { 0x1E293B },
      alpha=if off { 150 } else if active { 255 } else { 200 },
    )
    dl.text(
      label,
      b.x + 4.0,
      b.y + 6.0,
      size=10.0,
      bold=active,
      rgb=if off { 0x3E4C60 } else if active { 0xFFFFFF } else { 0x9AAAC2 },
    )
  }
}

///|
fn Runner::report(self : Runner) -> Unit {
  let sorted : Array[Int32] = []
  for v in self.intervals {
    sorted.push(v)
  }
  sorted.sort_by(fn(a : Int32, b : Int32) {
    if a < b {
      -1
    } else if a > b {
      1
    } else {
      0
    }
  })
  let mon = self.mon
  let avg = mon.total.to_double() * 1000.0 / mon.elapsed.to_double()
  let missed = if mon.total > 1 {
    mon.dropped.to_double() * 100.0 / (mon.total - 1).to_double()
  } else {
    0.0
  }
  println(
    "Particles bench: frames=\{mon.total}, elapsed=\{mon.elapsed}ms, avg=\{fixed1(avg)}fps, p50=\{fixed1(percentile(sorted, 0.5))}ms, p99=\{fixed1(percentile(sorted, 0.99))}ms, worst500=\{fixed1(mon.worst)}fps, missed-vsync=\{mon.dropped}(\{fixed1(missed)}%), paint=\{fixed1(mon.paint_ms)}ms, cmds=\{mon.cmds}",
  )
}

///|
fn Runner::frame(self : Runner) -> Unit raise @moonui.UiError {
  let state = self.state
  if state.quit {
    self.app.quit()
    return
  }
  let mon = self.mon
  // 节拍每帧向后端要一次：面板上切最大帧率 / 垂直同步后，下一拍就换挡。
  let interval = self.backend.present_interval_ms()
  state.pace_ms = interval
  let now = @native-common.native_time_ms()
  let first = mon.total == 0
  let dt = if first || mon.last == 0 {
    interval
  } else {
    let d = now - mon.last
    if d > 0 && d < 1000 {
      d
    } else {
      interval
    }
  }
  if !first {
    // 上一拍的实际非睡眠耗时（poll_event 里的真绘制 + 循环开销），低通后
    // 从下一拍 delay 里扣掉——周期才能贴着目标，而不是 interval + 绘制。
    let work = (dt - self.delay).to_double()
    let work = if work < 0.0 { 0.0 } else { work }
    self.draw_est = self.draw_est * 0.7 + work * 0.3
    mon.paint_ms = self.draw_est
    let next = interval - self.draw_est.to_int()
    self.delay = if next < 1 {
      1
    } else if next > interval {
      interval
    } else {
      next
    }
  } else {
    self.delay = interval
  }
  mon.last = now
  mon.frames += 1
  mon.total += 1
  mon.acc += dt
  mon.elapsed += dt
  if !first && dt > interval * 3 / 2 {
    mon.dropped += 1
  }
  if self.bench_ms > 0 {
    self.intervals.push(dt)
  }
  if mon.acc >= 500 {
    mon.fps = mon.frames.to_double() * 1000.0 / mon.acc.to_double()
    if mon.fps < mon.worst {
      mon.worst = mon.fps
    }
    mon.frames = 0
    mon.acc = 0
  }
  let world = self.world
  if !state.paused {
    world.step(state.mx, state.my, state.inside, state.attract)
  }
  mon.hud_tick += 1
  if mon.hud_tick >= 10 {
    mon.hud_tick = 0
    refresh_hud(mon, world.n, state)
    // 窗口可能被拖到另一块屏：每对拍刷新一次工作区，面板上「放不进屏幕」
    // 的禁用档才不会过期。
    let wa = @moonui.Backend::window_work_area(self.backend, self.win.handle())
    state.work_w = wa.size.width
    state.work_h = wa.size.height
  }
  self.face.repaint()
  if self.bench_ms > 0 && mon.elapsed >= self.bench_ms {
    self.report()
    self.app.quit()
    return
  }
  let _ = self.app.post_after(self.delay, fn() -> Unit raise @moonui.UiError {
    self.frame()
  })
}

///|
/// `moon run examples/particles-canvas-native` 开真窗口；设
/// `PARTICLES_BENCH_MS=5000` 则跑满 5 秒后自动打印统计并退出。
fn main raise {
  let bench_ms = match @env.get_env_var("PARTICLES_BENCH_MS") {
    Some(v) => (@string.from_str(v[:]) : Int32) catch { _ => 0 }
    None => 0
  }
  let b = @canvas-macos.CanvasBackend()
  @moonui.Backend::init(b)
  // 示例默认 120fps、垂直同步关（面板的默认选中档跟这里走）；
  // `PARTICLES_HZ` / `PARTICLES_VSYNC` 是跑分时的覆盖。
  b.set_max_fps(120)
  match @env.get_env_var("PARTICLES_HZ") {
    Some(v) => {
      let hz = (@string.from_str(v[:]) : Int32) catch { _ => 0 }
      if hz > 0 {
        b.set_max_fps(hz)
      }
    }
    None => ()
  }
  b.set_vsync(false)
  match @env.get_env_var("PARTICLES_VSYNC") {
    Some(v) => b.set_vsync(v != "0")
    None => ()
  }
  let app = @moonui.App(b)
  // 帧钟接线：CanvasBackend 不持事件循环，post_after 的节拍读数走 anim_clock，
  // 等待预算经 set_frame_budget 转发到内嵌原生 inner。
  app.set_anim_clock(fn() { @native-common.native_time_ms() })
  app.set_anim_wake(fn(active : Bool) { b.set_frame_budget(active) })

  let world = ParticleWorld::new(default_particles)
  let mon = Monitor::{
    last: 0,
    frames: 0,
    acc: 0,
    fps: 0.0,
    paint_ms: 0.0,
    total: 0,
    elapsed: 0,
    dropped: 0,
    cmds: 0,
    worst: 999.0,
    hud_tick: 0,
    hud_fps: "FPS  0.0",
    hud_paint: "PAINT  0.0 ms",
    hud_count: "PARTICLES  \{default_particles}",
    hud_draw: "CMDS  0   DROPPED  0",
    hud_mode: "斥力 · 按住左键改吸引",
  }
  let state = Sandbox::{
    paused: false,
    attract: false,
    quit: false,
    mx: 0.0,
    my: 0.0,
    inside: false,
    size_idx: 0,
    max_fps: b.max_fps(),
    vsync: b.vsync(),
    pace_ms: b.present_interval_ms(),
    work_w: 0.0,
    work_h: 0.0,
  }

  // 窗口先建：面板上的尺寸档要 `win.set_size`，事件闭包得拿到它。
  let win = app.create_window(
    "Particles · MoonUI high-rate sandbox",
    @moonui.LogicalSize(view_w, view_h),
  )
  // 窗口大小只走面板上的预设档：关掉手动拖边，量到的帧率才对得上档位。
  win.set_resizable(false)
  // 面板拿工作区判断哪些档放得下（比屏幕大的档禁用）。
  let work = @moonui.Backend::window_work_area(b, win.handle())
  state.work_w = work.size.width
  state.work_h = work.size.height
  let face = @moonui.Widget::custom(
    b,
    @moonui.LogicalSize(view_w, view_h),
    fn(dl, env) { paint(dl, env, world, mon, state) },
    focusable=true,
  )
  let _ = face.on_any(fn(ev) -> Unit raise @moonui.UiError {
    match ev {
      @moonui.MouseMove(_, p) => {
        state.mx = p.x
        state.my = p.y
        state.inside = true
      }
      @moonui.MouseDown(_, btn, p, _) => {
        state.mx = p.x
        state.my = p.y
        state.inside = true
        match btn {
          @moonui.Left => {
            let id = hit_button(button_layout(world.w, world.h), p.x, p.y)
            if id >= 0 {
              // 点在面板上：别顺手把粒子吸过来
              state.attract = false
              if id < size_count && !size_fits(state, id) {
                // 比屏幕大的档已禁用：点了什么都不做
              } else if id < size_count {
                // 能点的档都放得进工作区（更大的档在面板上禁用），照常夹一道
                // 兜底后居中；工作区读不到（0）时按原尺寸、也不挪位置。
                let wa = @moonui.Backend::window_work_area(b, win.handle())
                let pw = size_ws[id].to_double()
                let ph = size_hs[id].to_double()
                let bigger = wa.size.width > 0.0 &&
                  (pw > wa.size.width || ph > wa.size.height)
                let tw = if wa.size.width > 0.0 && pw > wa.size.width {
                  wa.size.width
                } else {
                  pw
                }
                let th = if wa.size.height > 0.0 && ph > wa.size.height {
                  wa.size.height
                } else {
                  ph
                }
                win.set_size(@moonui.LogicalSize(tw, th))
                // 兜底：禁用集过期（换屏后没刷新）时点到更大的档，贴左上角
                // 铺满可用区域，别把窗口居中到大半截在屏幕外。
                if bigger {
                  win.set_position(wa.origin)
                } else {
                  win.center()
                }
                state.size_idx = id
              } else if id < 20 {
                let fps = fps_options[id - 10]
                b.set_max_fps(fps)
                state.max_fps = fps
              } else {
                state.vsync = !state.vsync
                b.set_vsync(state.vsync)
              }
            } else {
              state.attract = true
            }
          }
          _ => ()
        }
      }
      @moonui.MouseUp(_, btn, p, _) => {
        state.mx = p.x
        state.my = p.y
        match btn {
          @moonui.Left => state.attract = false
          _ => ()
        }
      }
      _ => ()
    }
  })
  // 自绘后端没有键盘路由（`focusable` 在本后端只是占位），mac 的键事件落在
  // 窗口上而不是自绘面；在窗口 target 上订阅 KeyDown，快捷键才收得到。
  let _ = app.on_event(win.target(), fn(ev) {
    match ev {
      @moonui.KeyDown(_, kp) => {
        let k = kp.key
        if k == "=" || k == "+" {
          let next = world.n + 1000
          world.n = if next > max_particles { max_particles } else { next }
        } else if k == "-" || k == "_" {
          world.n = if world.n > 1000 { world.n - 1000 } else { 0 }
        } else if k == "p" || k == "P" {
          state.paused = !state.paused
        } else if k == "r" || k == "R" {
          world.reset()
        } else if k == "Escape" {
          state.quit = true
        }
      }
      _ => ()
    }
  })
  win.set_content(face)
  win.show()
  let vsync_text = if b.vsync() { "开" } else { "关" }
  println(
    "粒子沙盒已开窗：右下角切窗口尺寸 / 最大帧率 / 垂直同步；鼠标力场按住左键吸引",
  )
  println(
    "  最大帧率 \{b.max_fps()}Hz，垂直同步 \{vsync_text}（屏 \{b.refresh_hz()}Hz），拍长 \{b.present_interval_ms()}ms；设 PARTICLES_BENCH_MS=<毫秒> 可自动跑分退出",
  )

  let runner = Runner::{
    app,
    backend: b,
    win,
    face,
    world,
    mon,
    state,
    intervals: [],
    bench_ms,
    delay: b.present_interval_ms(),
    draw_est: 0.0,
  }
  let _ = app.post_after(runner.delay, fn() -> Unit raise @moonui.UiError {
    runner.frame()
  })
  app.run()
}
