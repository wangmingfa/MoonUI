///|
/// HUD 运行时指标与监听（`T343`）。
///
/// 这一层只做**采集 + 分发**，不碰任何平台 API：指标由宿主在 `App::step`
/// 的末尾喂进来（FPS/帧耗时走注入的单调钟，见 `App::set_hud_clock`），
/// 订阅者通过 `App::on_hud_metrics` 拿到节流后的快照。显示是另一件事——
/// `backends/native-common/hud.mbt` 的置顶窗消费同一份快照。
///
/// 为什么要节流：FPS 这类读数每帧都在抖，逐帧回调 == 逐帧重绘 HUD == HUD
/// 自己把被测的帧率拖下去。默认 500ms 一跳，只有值真的变了才回调。

///|
/// 一份 HUD 指标快照。全是值语义，订阅者拿去随便存。
pub(all) struct HudMetrics {
  /// 采样窗口内的平均帧率（帧/秒）。
  fps : Double
  /// 采样窗口内的平均帧耗时（毫秒），即 `1000 / fps`。
  frame_ms : Double
  /// 累计观测到的帧数。
  frames : Int32
  /// 累计观测到的毫秒数。
  elapsed_ms : Int32
  /// 最近一帧的绘制命令数（由绘制方经 `App::report_hud_cmds` 上报）。
  draw_cmds : Int32
}

///|
pub fn HudMetrics::HudMetrics() -> HudMetrics {
  { fps: 0.0, frame_ms: 0.0, frames: 0, elapsed_ms: 0, draw_cmds: 0, }
}

///|
/// 一条 HUD 监听。`id` 用来退订，`every_ms` 是这条监听自己的节流间隔。
priv struct HudListener {
  id : Int32
  every_ms : Int32
  mut last_fired : Int32
  mut last_fps : Double
  callback : (HudMetrics) -> Unit raise UiError
}

///|
/// App 侧的 HUD 账。默认没有（钟没接 = 一分钱不花）；接上钟才创建。
struct HudBus {
  clock : () -> Int32
  /// 上次采样的时刻（注入钟的原点）。
  mut last : Int32
  /// 当前采样窗口已累计的毫秒与帧数。
  mut window_ms : Int32
  mut window_frames : Int32
  /// 最近一次成形的快照。
  mut current : HudMetrics
  mut listeners : Array[HudListener]
  mut next_id : Int32
}

///|
fn HudBus::HudBus(clock : () -> Int32) -> HudBus {
  {
    clock,
    last: 0,
    window_ms: 0,
    window_frames: 0,
    current: HudMetrics::HudMetrics(),
    listeners: [],
    next_id: 1,
  }
}

///|
/// 接上 HUD 的时钟。时钟是单调毫秒（native 侧 `@native-common.native_time_ms`）。
/// 不接时钟时所有 HUD API 都是空操作：`metrics` 返回全零、`on_hud_metrics`
/// 返回 -1——与 `set_anim_clock` 同一条"Core 不读墙钟"的纪律。
pub fn[B] App::set_hud_clock(self : App[B], clock : () -> Int32) -> Unit {
  self.hud = Some(HudBus::HudBus(clock))
}

///|
/// 上报最近一帧的绘制命令数。只改快照里的 `draw_cmds`，不单独触发监听
/// （跟下一帧的 FPS 一起发，省得一个数字抖两遍）。没有 HUD 账时是空操作。
pub fn[B] App::report_hud_cmds(self : App[B], count : Int32) -> Unit {
  match self.hud {
    Some(bus) => {
      let prev = bus.current
      bus.current = HudMetrics::{ ..prev, draw_cmds: count, }
    }
    None => ()
  }
}

///|
/// 取当前快照。数值在 `App::step` 末尾按窗口更新，两次调用之间读到的
/// 是同一份（值拷贝）。没有 HUD 账时返回全零。
pub fn[B] App::hud_metrics(self : App[B]) -> HudMetrics {
  match self.hud {
    Some(bus) => bus.current
    None => HudMetrics::HudMetrics()
  }
}

///|
/// 订阅 HUD 指标。`every_ms` 是这条监听的节流下限：窗口算出一帧读数后，
/// 距上次回调不足 `every_ms` 或 FPS 与上次相等（值相等即视为没变）都不回调。
/// 返回监听 id（>=1），用 `App::off_hud_metrics` 退订；没有 HUD 账时返回 -1。
///
/// 回调签名带 `raise UiError`，因为最常见的用途就是 `face.repaint()`——
/// 直接在回调里重画，不必再绕一层 `post`。
pub fn[B] App::on_hud_metrics(
  self : App[B],
  every_ms : Int32,
  callback : (HudMetrics) -> Unit raise UiError,
) -> Int32 {
  match self.hud {
    Some(bus) => {
      let id = bus.next_id
      bus.next_id = id + 1
      let gap = if every_ms < 0 { 0 } else { every_ms }
      let listener : HudListener = {
        id,
        every_ms: gap,
        last_fired: -1000000000,
        last_fps: -1.0,
        callback,
      }
      bus.listeners.push(listener)
      id
    }
    None => -1
  }
}

///|
/// 退订一条 HUD 监听。返回是否真的撤掉了一条。
pub fn[B] App::off_hud_metrics(self : App[B], id : Int32) -> Bool {
  match self.hud {
    Some(bus) => {
      let kept : Array[HudListener] = []
      let mut removed = false
      for l in bus.listeners {
        if l.id == id {
          removed = true
        } else {
          kept.push(l)
        }
      }
      bus.listeners = kept
      removed
    }
    None => false
  }
}

///|
/// HUD 账上还挂着几条监听（诊断用）。
pub fn[B] App::hud_listener_count(self : App[B]) -> Int32 {
  match self.hud {
    Some(bus) => bus.listeners.length()
    None => 0
  }
}

///|
/// 采样一帧并分发。由 `App::step` 在**每圈末尾**调——注意是"每圈"
/// 而不是"每次重绘"：主循环每圈至多产出一帧，空转圈（没任务没事件）会
/// 让 `drive` 直接收尾，所以圈数就是实际渲染节拍。
///
/// 第一拍只立锚点不产读数：`dt` 在首拍没有意义，拿它算 FPS 会 spit 出一个
/// 荒唐的大数（起点取开机毫秒）。
pub fn[B] App::sample_hud(self : App[B]) -> Unit raise UiError {
  match self.hud {
    Some(bus) => {
      let now = (bus.clock)()
      if bus.last != 0 {
        let mut dt = now - bus.last
        if dt < 0 || dt > 1000 {
          // 时钟回拨 / 睡过一秒：这一拍不作数，重新立锚点。
          dt = 0
        }
        if dt > 0 {
          let prev = bus.current
          bus.current = HudMetrics::{
            ..prev,
            frames: prev.frames + 1,
            elapsed_ms: prev.elapsed_ms + dt,
          }
          bus.window_frames += 1
          bus.window_ms += dt
        }
        if bus.window_ms >= 500 {
          let denom = bus.window_ms.to_double()
          let fps = bus.window_frames.to_double() * 1000.0 / denom
          let prev = bus.current
          bus.current = HudMetrics::{
            ..prev,
            fps,
            frame_ms: denom / bus.window_frames.to_double(),
          }
          bus.window_ms = 0
          bus.window_frames = 0
        }
        // 快照值传递：回调里退订/重订阅改的是 bus.listeners，与手上这份
        // 迭代用的数组不是一块内存（下面先 copy 出来）。
        let pending = bus.listeners
        let snap = bus.current
        for l in pending {
          if snap.fps != l.last_fps &&
            snap.elapsed_ms - l.last_fired >= l.every_ms {
            // 先记时间再回调：回调里重入不会把同一条监听再点一遍。
            l.last_fired = snap.elapsed_ms
            l.last_fps = snap.fps
            (l.callback)(snap)
          }
        }
      }
      bus.last = now
    }
    None => ()
  }
}

///|
/// `T344` 回归：关窗后 `step` 的尾巴（HUD 采样/动画/长按键）不许再跑。
/// tetris 的 HUD 回调里就写着 `face.repaint()`——内容树在 `Window::release`
/// 里已 close_tree，再 repaint 撞 Destroyed，一路抛到 moonbit_init 变
/// PanicError（owner 点关闭钮实测）。这里在回调里放同一句 repaint，
/// 用计数观测它在关窗后不会再被点；`app.run()` 也必须正常收尾不抛。
test "Close 后 HUD 回调不再复画已销毁控件（T344）" {
  let app = App(MockBackend())
  let b = app.backend()
  Backend::init(b)
  let cell : Array[Int32] = [0]
  app.set_hud_clock(fn() { cell[0] })
  let win = app.create_window("T", LogicalSize(200.0, 100.0))
  let face = Widget::label(b, "x")
  win.set_content(face)
  let fired : Array[Int32] = [0]
  let _ = app.on_hud_metrics(0, fn(_) raise UiError {
    fired[0] = fired[0] + 1
    face.repaint()
  })
  // 推时钟走过两个 500ms 窗口：FPS 读数成形，回调至少点过一次。
  // step 的返回值取决于有没有事件/任务，这里只管驱动拍数，不断言它。
  cell[0] = 0
  let _ = app.step()
  cell[0] = 300
  let _ = app.step()
  cell[0] = 700
  let _ = app.step()
  cell[0] = 1200
  let _ = app.step()
  assert_true(fired[0] > 0)
  let before = fired[0]
  // 关窗那一圈：dispatch(Close) 在 release 里 close_tree 了 face；
  // 短路之前 sample_hud 会再点回调 -> face.repaint() 抛 Destroyed。
  b.push_event(Close(win.target()))
  cell[0] = 600
  app.run()
  assert_true(win.is_closed())
  assert_true(face.is_closed())
  // 关窗圈之后回调一次都没再点（短路生效）
  assert_eq(fired[0], before)
  assert_true(app.quit_requested_now_for_testing())
}
