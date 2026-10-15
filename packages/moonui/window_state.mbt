///|
/// 窗口状态持久化（设计文档 §12，`T86⑦`）：尺寸位置 MoonBit 侧 JSON 存档 +
/// 启动恢复，零 C——几何读数走既有 API（`size`/`position`/`window_state`，
/// 批二的"读当下态"快照式），序列化走 Core 的 JSON（builtin `Json` +
/// `@json.parse`），落盘走同包两个按目标门控的文件（native 半声明 libc 的
/// fopen/fwrite/fread，MoonBit 侧声明、零 C 源；wasm 半显式缺席报
/// `Unsupported`——无文件系统的目标上存档整体不可用，不静默）。
///
/// 存档内容最小：宽高/位置/最大化态（`WindowFrame`）。最小化不进档：它是
/// 会话态不是几何态（最小化的窗口恢复时仍按几何开窗，是否最小化由用户
/// 当下决定）。窗口标题/多窗口也不进第一版档（见 `App::save_window_state`
/// 的段注）。

///|
/// 一份窗口几何快照（`T86⑦`）。存档时刻窗口"是什么样"的逐字段账：
/// 宽高为逻辑像素（§30），位置为窗口左上角逻辑坐标（可负——副屏在主屏
/// 左/上方时坐标就是负的，§12），maximized 是批二 `window_state` 读回的
/// 最大化位。
pub(all) struct WindowFrame {
  width : Double
  height : Double
  x : Double
  y : Double
  maximized : Bool
} derive(Debug, Eq)

///|
/// NUL 结尾的 C 字符串（落盘半的 fopen 需要）：MoonBit 的 `String` 内部是
/// UTF-16、`Bytes` 不保证 NUL 结尾——长度显式传的那套（§29）只适合有长度
/// 参数的符号，libc 家族靠 NUL 分界，这里补上。helper 住在门控无关的这半，
/// 两个目标都编译、都消费 `@utf8`——wasm 侧不出现 unused_package 假警报。
/// （门控无关 = 纯 MoonBit 的编码账，没有 extern，wasm 编不出问题。）
fn cstr(text : String) -> Bytes {
  @utf8.encode(text).add(Bytes::make(1, 0))
}

///|
/// 存档路径只进系统临时目录（AGENTS.md 的临时文件规则——仓库里不留任何文件）。
/// 按惯例档查 TMPDIR（mac/Linux）、TEMP/TMP（Windows），都没有落回 "/tmp"。
/// 住在门控无关的这半，`@env` 两个目标都消费（理由同上）。
fn temp_archive_path() -> String {
  let base = match @env.get_env_var("TMPDIR") {
    Some(d) => d
    None =>
      match @env.get_env_var("TEMP") {
        Some(d) => d
        None =>
          match @env.get_env_var("TMP") {
            Some(d) => d
            None => "/tmp/"
          }
      }
  }
  base + "moonui_window_state_native_test.json"
}

///|
/// 存档格式（`T86⑦`）：单层 JSON 对象，一条一份——
/// `{"width":800.0,"height":600.0,"x":560.0,"y":240.0,"maximized":false}`
/// 数字统一按 JSON number 存（整值序列化成 `800`、读回仍得 800.0，
/// 双精度往返逐位精确）。判据"存档→读回往返逐位断言"钉的就是这条格式。
fn frame_to_json(f : WindowFrame) -> Json {
  Json::object(
    Map([
      ("width", Json::number(f.width)),
      ("height", Json::number(f.height)),
      ("x", Json::number(f.x)),
      ("y", Json::number(f.y)),
      ("maximized", Json::boolean(f.maximized)),
    ]),
  )
}

///|
/// 读档：缺字段/类型不对/不是对象都是显式错误（§33——损坏的存档不许静默
/// 解析成"随机的默认值"），错误串带上缺的是哪个字段。
fn frame_from_json(j : Json) -> WindowFrame raise UiError {
  fn field(m : Map[String, Json], key : String) -> Double raise UiError {
    match m.get(key) {
      Some(Number(v, ..)) => v
      Some(_) =>
        raise OperationFailed("窗口存档的字段 \{key} 不是数字")
      None => raise OperationFailed("窗口存档缺少字段 \{key}")
    }
  }
  match j {
    Object(m) =>
      WindowFrame::{
        width: field(m, "width"),
        height: field(m, "height"),
        x: field(m, "x"),
        y: field(m, "y"),
        maximized: match m.get("maximized") {
          Some(True) => true
          Some(False) => false
          Some(_) =>
            raise OperationFailed(
              "窗口存档的字段 maximized 不是布尔",
            )
          None => raise OperationFailed("窗口存档缺少字段 maximized")
        },
      }
    _ => raise OperationFailed("窗口存档不是 JSON 对象")
  }
}

///|
/// `T86⑦` 存档：把**第一只存活的窗口**当下的几何快照成 JSON 写进 path。
/// 单窗口档——第一版判据是"启动恢复建窗的往返"，多窗口各存一份是档格式
/// 分期的账，不在这里夹带。没有存活窗口是显式错误（§33），不写空档。
///
/// 几何读数一律问后端（§12：Core 不缓存窗口状态），最大化位走批二
/// `window_state` 的快照式读回。落盘的失败形态（打不开/写不完）由门控半
/// 翻译成 `UiError`（§33）。
pub fn[B : Backend] App::save_window_state(
  self : App[B],
  path : String,
) -> Unit raise UiError {
  match self.window_frame() {
    Some(f) => archive_write(path, frame_to_json(f).stringify())
    None => raise OperationFailed("没有存活的窗口可存档")
  }
}

///|
/// 存档文本 → JSON 的翻译口：`@json.parse` 抛的是它自己的 `ParseError`，
/// 这里统一收进 `UiError`（§33 的错误口径——框架只对外抛一种错误），串带上
/// 底层原因。
fn parse_archive(content : String) -> Json raise UiError {
  @json.parse(content) catch {
    e => raise OperationFailed("窗口存档解析失败：\{e}")
  }
}

///|
/// `T86⑦` 读档：path 上的 JSON 翻回 `WindowFrame`。存档不存在返回 `None`
/// （第一次启动没有档是常态，不是错误——恢复点在 `create_window` 前，调用方
/// 拿 `None` 走默认尺寸即可）；档存在但解析不了是显式错误（§33，损坏的档
/// 不许静默变成"没有档"）。wasm 目标无文件系统，两半都报 `Unsupported`。
pub fn[B] App::load_window_state(
  self : App[B],
  path : String,
) -> WindowFrame? raise UiError {
  // 读档不经后端（窗口存档是 Core 自己的文件账，零 ABI）——self 在签名上
  // 只为与 `save_window_state` 配对成一条读写对称的 API。
  let _ = self
  match archive_read(path) {
    None => None
    Some(content) => Some(frame_from_json(parse_archive(content)))
  }
}

///|
/// 当下第一只存活窗口的几何快照（`T86⑦` 的读数半）：不落盘的那半条 API，
/// Mock 上直接快照/直接恢复就能断往返，不依赖文件系统。没有存活窗口返回
/// `None`。读数全部问后端（§12），最大化位走批二 `window_state`。
pub fn[B : Backend] App::window_frame(
  self : App[B],
) -> WindowFrame? raise UiError {
  for w in self.windows {
    if !w.is_closed() {
      let size = w.size()
      let pos = w.position()
      let st = w.window_state()
      return Some(WindowFrame::{
        width: size.width,
        height: size.height,
        x: pos.x,
        y: pos.y,
        maximized: st.maximized,
      })
    }
  }
  None
}

///|
/// `T86⑦` 启动恢复半：拿一份快照（或没有）建窗——`Some(f)` 按档里的宽高
/// 开窗、位置与最大化态照档恢复；`None`（第一次启动）按 default_size 开窗。
/// 这是恢复点在 `create_window` 前的那条路：先读档再建窗，档里的几何在建窗
/// 那一刻就落上，不用"先建错一版再改一版"。尺寸过档时走既有 setter
/// （min/max 夹紧照旧），负值按零处理。
pub fn[B : Backend] App::create_window_restored(
  self : App[B],
  title : String,
  default_size : LogicalSize,
  frame : WindowFrame?,
) -> Window[B] raise UiError {
  match frame {
    None => self.create_window(title, default_size)
    Some(f) => {
      let win = self.create_window(title, LogicalSize(f.width, f.height))
      win.apply_frame(f)
      win
    }
  }
}

///|
/// 把一份几何快照逐字段设回窗口（`T86⑦` 的恢复半）。全部走既有 setter
/// （`set_size`/`set_position`/`set_maximized`，批二已查证在案——零 C 的
/// 理由之一）：尺寸过 min/max 夹紧、负值归零；位置可负（副屏）；最大化
/// 只恢复 `true` 那一档（档里是 false 就不动——最大化位的"恢复"由原生层
/// 记账，重复设 false 无意义）。
pub fn[B : Backend] Window::apply_frame(
  self : Window[B],
  f : WindowFrame,
) -> Unit raise UiError {
  self.set_size(LogicalSize(f.width, f.height))
  self.set_position(LogicalPoint(f.x, f.y))
  if f.maximized {
    self.set_maximized(true)
  }
}

///|
test "窗口存档的 JSON 格式逐字段往返（T86⑦判据·格式半）" {
  let f = WindowFrame::{
    width: 800.0,
    height: 600.0,
    x: 560.0,
    y: 240.0,
    maximized: false,
  }
  let text = frame_to_json(f).stringify()
  // 格式钉死：一条一份、单层对象、字段名固定——读档半靠这个名字集合解析；
  // 整值序列化成 `800`（JSON number 无小数位），读回仍得 800.0
  assert_eq(
    text, "{\"width\":800,\"height\":600,\"x\":560,\"y\":240,\"maximized\":false}",
  )
  let back = frame_from_json(parse_archive(text))
  assert_eq(back, f)
  // 负坐标（副屏）与带小数的度量（真后端排出来的宽度）往返也逐位精确
  let odd = WindowFrame::{
    width: 192.8,
    height: 28.0,
    x: -1040.0,
    y: 0.5,
    maximized: true,
  }
  assert_eq(frame_from_json(parse_archive(frame_to_json(odd).stringify())), odd)
}

///|
test "损坏的存档显式报错，字段缺失带名字（T86⑦·§33）" {
  let msgs : Array[String] = []
  // 不是对象
  msgs.push(
    frame_error(fn() raise UiError {
      let _ = frame_from_json(parse_archive("[]"))
    }),
  )
  // 缺字段：错误串带字段名
  msgs.push(
    frame_error(fn() raise UiError {
      let _ = frame_from_json(parse_archive("{\"width\":800.0}"))
    }),
  )
  // 类型不对
  msgs.push(
    frame_error(fn() raise UiError {
      let _ = frame_from_json(parse_archive("{\"width\":\"800\"}"))
    }),
  )
  assert_eq(msgs, [
    "操作失败：窗口存档不是 JSON 对象", "操作失败：窗口存档缺少字段 height",
    "操作失败：窗口存档的字段 width 不是数字",
  ])
}

///|
test "落盘半 helper 的契约在两个目标都成立（T86⑦·跨目标）" {
  // cstr/temp_archive_path 是纯 MoonBit 的编码与档查账（没有 extern），
  // 门控无关——native 半的 fopen 靠"NUL 结尾"这条契约分界，这里把它钉死；
  // wasm 半没有落盘（Unsupported 显式缺席），但编码账照常编译照常跑。
  // 消费点兼做契约测试：删 helper 前先看这条。
  let mode = cstr("w")
  assert_eq(mode.length(), 2)
  assert_eq(mode[0], 119)
  assert_eq(mode[1], 0)
  let path = cstr(temp_archive_path())
  assert_eq(path[path.length() - 1], 0)
  // 临时目录读数落在系统临时目录的惯例档（TMPDIR/TEMP/TMP 有一条就在）
  assert_true(temp_archive_path() != "")
}

///|
/// 把 handler 的失败收成语明（§33 的测试惯例，window_state 专用）。
fn frame_error(body : () -> Unit raise UiError) -> String {
  try {
    body()
    "no error"
  } catch {
    e => e.message()
  }
}

///|
test "window_frame 快照恢复的 Mock 往返（T86⑦判据·往返半）" {
  let b = MockBackend::new()
  Backend::init(b)
  let app = App::new(b)
  // 开窗 → 设几何 → 最大化 → 快照；默认居中先被显式位置覆盖（§12）
  let win = app.create_window("MoonUI", LogicalSize(800.0, 600.0))
  win.set_position(LogicalPoint(30.0, 40.0))
  Backend::set_window_maximized(b, win.handle(), true)
  let f = app.window_frame()
  assert_eq(
    f,
    Some(WindowFrame::{
      width: 800.0,
      height: 600.0,
      x: 30.0,
      y: 40.0,
      maximized: true,
    }),
  )
  win.close()
  // 恢复点在 create_window 前：快照直接交给建窗半，几何逐位落上
  let restored = app.create_window_restored(
    "MoonUI",
    LogicalSize(400.0, 300.0),
    f,
  )
  assert_eq(restored.size(), LogicalSize(800.0, 600.0))
  assert_eq(restored.position(), LogicalPoint(30.0, 40.0))
  assert_true(Backend::window_state(b, restored.handle()).maximized)
  // 没有档的那半条：走默认尺寸（第一次启动的形状）
  let fresh = app.create_window_restored(
    "Fresh",
    LogicalSize(400.0, 300.0),
    None,
  )
  assert_eq(fresh.size(), LogicalSize(400.0, 300.0))
  // 没有存活窗口的快照是 None（显式缺席，不是空档）
  fresh.close()
  restored.close()
  assert_eq(app.window_frame(), None)
  Backend::terminate(b)
}
