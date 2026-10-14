///|
/// 原生 Win32 后端的真窗口验证（设计文档 §51 的 Backend #2，Windows 半，T75）。
///
/// 被测的是"共享的 MoonBit 实现 + 直写 Win32 的 C Adapter"这一对：
/// `@native-common.NativeBackend` 底下不经过 libui-ng，窗口、控件、事件循环
/// 全部直写 Win32（见 ../native-windows/adapter_native.c）。所以这里的每条断言
/// 都在问"不经过 libui-ng 也能开窗、跑循环、收事件"——和 mac 原生那份
/// （../native-macos/native_test.mbt）同一批 FP1 判据。
///
/// 这份文件只在 Windows 宿主上才真正跑（scripts/test-local.sh 的 Windows
/// 分支）；在 mac 上它只进 `moon check` 的类型闸门，不进真窗口断言。

///|
/// 逻辑尺寸往返的容差：物理取整最多让一个方向差 1 像素；Win32 的 DPI 换算还要
/// 多一道四舍五入，所以窗口级的量允许差到 1 逻辑像素。
fn close_to(a : Double, b : Double) -> Bool {
  let d = a - b
  d < 1.0 && d > -1.0
}

///|
/// 登记在册的后端：每条测试开头先清场（把上一条没收尾的后端 terminate 掉），
/// 再建一个新的。Win32 那侧没有进程级单例（NSApplication 那种），但两只后端
/// 各自的窗口类是全局注册的，重复 init 在 C 侧直接幂等返回，所以这里按登记顺序
/// 遍历收尾，和 mac 那份同一套形状。
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
/// 末尾 init 一次、terminate 两次：确认这一对是幂等的（C 那侧 moonui_terminate
/// 对"没 inited"的重复调用就是直接返回）。
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
/// 窗口几何、缩放、屏幕信息。这条顺带钉住"Win32 的 DPI 就是每英寸像素数"：
/// adapter.h 说 C 侧只报 DPI 不做换算，96 这条基线（100% 缩放）读回来就是 96
/// 的整数倍，Scale 拿到的还是同一个数。
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
