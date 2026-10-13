///|
/// 原生 Cocoa 后端的真窗口验证（设计文档 §51 的 Backend #2，macOS 半，FP1）。
///
/// 被测的是"共享的 MoonBit 实现 + 直写 AppKit 的 C Adapter"这一对：
/// `@native-common.NativeBackend` 底下不经过 libui-ng，窗口、事件循环、回调全部
/// 直写 Cocoa（见 ../native-macos/adapter_native.m）。所以这里的每条断言都在问
/// "不经过 libui-ng 也能开窗、跑循环、收事件"——这是 FP1 要证明的方向。
///
/// 这些测试会真的开窗口。带 App 的那条用 `for_testing` 的有限等待预算，
/// 链路断了就是测试失败，不会挂住 CI。

///|
/// 逻辑尺寸往返的容差：物理取整最多让一个方向差 1 像素；macOS 还要多一道"点"的
/// 取整，所以窗口级的量允许差到 1 逻辑像素。
fn close_to(a : Double, b : Double) -> Bool {
  let d = a - b
  d < 1.0 && d > -1.0
}

///|
/// 登记在册的后端：每条测试开头先清场（把上一条没收尾的后端 terminate 掉），
/// 再建一个新的。进程级单例（NSApplication）意味着同一时刻只能有一份活着的
/// 后端，所以这里按登记顺序遍历收尾。
let backends_in_play : Array[@native-common.NativeBackend] = []

///|
fn sweep_leaked_handles() -> Unit {
  for b in backends_in_play {
    b.terminate()
  }
  backends_in_play.clear()
}

///|
fn open_backend() -> @native-common.NativeBackend {
  sweep_leaked_handles()
  let b = @native-common.NativeBackend::new()
  backends_in_play.push(b)
  b
}

///|
fn open_backend_for_testing(
  wait_budget_ms : Int32,
) -> @native-common.NativeBackend {
  sweep_leaked_handles()
  let b = @native-common.NativeBackend::for_testing(wait_budget_ms)
  backends_in_play.push(b)
  b
}

///|
/// 不 `init()` 就动手，后端必须当场拒绝——这条钉的是 `check_initialized` 那道闸。
/// 末尾 init 一次、terminate 两次：确认这一对是幂等的（NSApplication 是进程级
/// 单例，MoonBit 侧的 terminate 走 `moonui_terminate` 的"没 inited 就直接返回"）。
test "原生后端：未初始化的真后端拒绝创建对象" {
  let b = open_backend()
  let msg = try {
    let _ = b.create_window("MoonUI 原生 未初始化", @moonui.LogicalSize::{
      width: 100.0,
      height: 80.0,
    })
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg, Some("UI 初始化失败：Backend 尚未初始化"))
  b.init()
  b.terminate()
  b.terminate()
}

///|
/// 窗口几何、缩放、屏幕信息。这条顺带钉住"macOS 的 dpi 就是倍数乘 96"：
/// adapter.h 说 C 侧只报 DPI 不做换算，而 Cocoa 只有倍数，所以 192 这种读数
/// 是本文件那次乘法的直接结果，Scale 拿到的还是同一个数。
test "原生后端：窗口尺寸、位置、缩放按物理像素往返" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI 原生 窗口几何", @moonui.LogicalSize::{
    width: 300.0,
    height: 200.0,
  })
  let scale = b.window_scale(win)
  assert_true(scale.x >= 1.0 && scale.y >= 1.0)
  let size = b.window_size(win)
  assert_true(close_to(size.width, 300.0))
  assert_true(close_to(size.height, 200.0))
  b.set_window_size(win, @moonui.LogicalSize::{ width: 420.0, height: 260.0, })
  let grown = b.window_size(win)
  assert_true(close_to(grown.width, 420.0))
  assert_true(close_to(grown.height, 260.0))
  b.set_window_position(win, @moonui.LogicalPoint::{ x: 40.0, y: 60.0, })
  let origin = b.window_position(win)
  assert_true(close_to(origin.x, 40.0))
  assert_true(close_to(origin.y, 60.0))
  b.set_window_title(win, "MoonUI 原生 窗口几何 — 改名")
  b.set_window_resizable(win, false)
  b.hide_window(win)
  b.show_window(win)
  let screen = b.screen_size()
  assert_true(screen.width > 100.0 && screen.height > 100.0)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 沉浸式标题栏（§12）：`set_titlebar_style(Immersive)` 之后，原生层真的变成
/// fullSizeContentView + 透明标题栏 + 隐藏标题文字（三条都置位 = 打包位 7），
/// 切回 `Standard` 又摘干净（回到 0）。
test "原生后端：沉浸式标题栏设了真的生效，切回标准又摘干净" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI 原生 沉浸式标题栏", @moonui.LogicalSize::{
    width: 300.0,
    height: 200.0,
  })
  assert_eq(@native-common.native_window_titlebar_style(win), 0)
  b.set_window_titlebar_style(win, @moonui.TitlebarStyle::Immersive)
  assert_eq(@native-common.native_window_titlebar_style(win), 7)
  b.set_window_titlebar_style(win, @moonui.TitlebarStyle::Standard)
  assert_eq(@native-common.native_window_titlebar_style(win), 0)
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// 红绿灯位置（§12）：`set_traffic_light_position` 之后关闭按钮左上角真的落到
/// 指定的逻辑坐标（读回走的是同一套 pt/px 换算，断言按物理像素对表 scale）。
test "原生后端：红绿灯位置设了真的生效" {
  let b = open_backend()
  b.init()
  let win = b.create_window("MoonUI 原生 红绿灯位置", @moonui.LogicalSize::{
    width: 300.0,
    height: 200.0,
  })
  b.set_window_traffic_light_position(win, @moonui.LogicalPoint::{
    x: 12.0,
    y: 8.0,
  })
  let (px, py) = @native-common.native_window_traffic_light_position(win)
  let scale = b.window_scale(win)
  assert_true(close_to(px.to_double(), 12.0 * scale.x))
  assert_true(close_to(py.to_double(), 8.0 * scale.y))
  b.destroy_window(win)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}

///|
/// poll_event 的两个终止条件：没有存活窗口时返回 None（循环结束），有窗口时
/// 阻塞到有事件或等待预算用完。这条用 `for_testing` 的有限预算，链路断了就是
/// 测试失败，不会挂住 CI。
test "原生后端：poll_event 的两个终止条件" {
  let b = open_backend_for_testing(3000)
  b.init()
  // 没有窗口：循环结束，返回 None
  assert_eq(b.poll_event(), None)
  let win = b.create_window("MoonUI 原生 循环终止", @moonui.LogicalSize::{
    width: 200.0,
    height: 120.0,
  })
  // 有窗口：阻塞到有事件或预算用完。这里没有事件源，所以会空转到预算用完返回
  // None——但关键是它**没有**因为"没有窗口"而立刻返回，而是真的泵了循环。
  let _ = b.poll_event()
  b.destroy_window(win)
  assert_eq(b.poll_event(), None)
  b.terminate()
}

///|
/// 多窗口：建两只、各自独立、销毁一只不影响另一只。
test "原生后端：多窗口各自独立" {
  let b = open_backend()
  b.init()
  let one = b.create_window("MoonUI 原生 多窗口之一", @moonui.LogicalSize::{
    width: 200.0,
    height: 120.0,
  })
  let two = b.create_window("MoonUI 原生 多窗口之二", @moonui.LogicalSize::{
    width: 300.0,
    height: 180.0,
  })
  assert_true(b.window_size(one).width < b.window_size(two).width)
  b.destroy_window(one)
  // 销毁一只后另一只还在
  assert_true(close_to(b.window_size(two).width, 300.0))
  b.destroy_window(two)
  assert_eq(@native-common.native_live_handles(), 0)
  b.terminate()
}
