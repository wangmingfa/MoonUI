///|
/// ABI 编码 → 判定的纯函数表（`T143`）。
///
/// 这里收三张表，它们此前都只活在"必须有真宿主才进得去"的位置：
///
/// 1. **鼠标**（`mouse_decision`）：此前只活在 `native-common/backend.mbt` 的
///    `native_on_mouse` 闭包身体里，读全局 `native_mouse_kind_button()`。
///    `T141` 的缺口——kind 3（双击）在这一档无人认领，`on_double_click` 在原生
///    后端上从来没有事件源——正住在这一张表上，而它要真窗口加真鼠标才看得见。
/// 2. **手势**（`gesture_phase` / `swipe_direction`）：同上，住在
///    `native_on_gesture` 闭包里。
/// 3. **目录行走的打包格式**（`decode_walk_packet`）：住在 `ffi.mbt` 的
///    `native_walk_dir` 里，前半是纯解码、后半才是 C 调用。`T142` 的缺口
///    （C 半把 `readdir` 的 `d_name` 当绝对路径上报）不在这半，但"打包坏了怎么办"
///    那一串逐项隔离逻辑此前一条判据都没有。
///
/// 三张表都是**纯的**：零 C、零 FFI、零宿主状态，输入是整数与字节，输出是值。
/// 于是它们能进 wasm 门，在 ubuntu 上就能跑——这是本包存在的全部理由。
///
/// **本包是这些表的唯一一份**：后端调进来，不另抄一份。抄一份就等于下次改行为
/// 要改两处、漏一处就分叉。

///|
/// 数量与按钮的拆包结果（adapter.h 鼠标段：`kind * 8 + button`）。
#derive(Debug, Eq)
pub(all) struct KindButton {
  kind : Int32
  button : Int32
}

///|
/// `kind * 8 + button` 拆成两半。
///
/// button 用**非负取模**：adapter.h 的编码只有非负值，但 C 侧把 `int` 递过来时
/// 负数也能到。MoonBit 的 `%` 对负数给负余数（`-1 % 8 == -1`），直接拿去做
/// button 会漏出一个负的按钮号，于是显式取正。kind 跟着整除算出来，于是
/// "负的 kb"落在 kind 为负的那一档，`mouse_decision` 里没有分支认它，整条丢掉。
pub fn split_kind_button(kb : Int32) -> KindButton {
  let button = (kb % 8 + 8) % 8
  KindButton::{ kind: (kb - button) / 8, button, }
}

///|
/// 鼠标事件该派给谁（`T143`）。
///
/// 这一层只回答"派给谁、派成什么"：**不带坐标**。坐标是另一本账——adapter.h
/// 鼠标段写了两个口径（`pos` 物理像素、`delta` 已是逻辑像素），换算要按**收件
/// 对象自己**的缩放除回去，那是后端拿得到、这里拿不到的东西。判定表若把坐标
/// 也带上，就得在这里塞假值，判据于是要去比一个假值。
#derive(Debug, Eq)
pub(all) enum MouseDecision {
  /// 整条丢掉：命中不在我们的对象上，或者这个编码没有 Core 侧消费者。
  Drop
  /// 报给这个对象（空白处是窗口自己）。kind 2 移动与 kind 5 离开同一个落点——
  /// 离开由 Core 从"目标换了"里合成，后端只说"现在在谁身上"。
  MoveTo(@moonui.NativeHandle)
  /// 滚轮。增量由调用方给（kind 不是 4 时它没有意义）。
  WheelTo(@moonui.NativeHandle)
  /// 双击。`Event::DoubleClick` 不带点，命中已经在 C 侧做完（adapter.h 命中段
  /// 第 ③ 条）。
  DoubleTo(@moonui.NativeHandle)
  /// 按下。坐标口径是物理像素、客户区原点。
  PressTo(@moonui.NativeHandle, @moonui.MouseButton)
  /// 抬起。口径同按下。
  ReleaseTo(@moonui.NativeHandle, @moonui.MouseButton)
}

///|
/// ABI 按钮号换成 `MouseButton`：0 Left / 1 Right / 2 Middle / 3 Extra1 /
/// 4 Extra2，和 `packages/moonui/event.mbt` 里 `MouseButton` 的声明顺序一字不差
/// （adapter.h 又是照那份声明写的，所以这里不该有任何映射表）。表外的号按
/// Extra2 兜住——它在 Core 侧没有任何消费者，不会假装成别的按钮。
///
/// **本表目前只有测试在用**：`mouse_decision` 的自绘面左键那一支照原闭包恒报
/// `Left`（见那一支的注），中键/侧键在自绘面上仍按 Left 报——那是重构前就有的
/// 形状，这一轮不改行为。哪天真接中键时改的是这一支，用的是这张表。
pub fn mouse_button_of(button : Int32) -> @moonui.MouseButton {
  match button {
    0 => @moonui.Left
    1 => @moonui.Right
    2 => @moonui.Middle
    3 => @moonui.Extra1
    _ => @moonui.Extra2
  }
}

///|
/// 修饰键位掩码换成 `Mods`（`T102` 第二十三刀）：adapter.h 的编码 bit0 ctrl /
/// bit1 alt / bit2 shift / bit3 meta，与键盘那半 `native_key_modifiers`
/// 同一张表。表外位如实忽略——鼠标事件只认这四格。
pub fn mods_of_bits(m : Int32) -> @moonui.Mods {
  @moonui.Mods::{
    ctrl: (m & 1) != 0,
    alt: (m & 2) != 0,
    shift: (m & 4) != 0,
    meta: (m & 8) != 0,
  }
}

///|
/// 这条编码要不要后端去反查 `native_mouse_owner()`（`T143`）。
///
/// 只有滚轮（kind 4）用得上它：`T102` 第十二刀让 mac 半的滚轮 target 恒报窗口，
/// 真正被滚到的控件走 owner 那一本账。
///
/// 为什么专门问一句而不是"反正都算一遍"：`owner` 的反查是沿**存活控件**表线性
/// 扫，而鼠标移动是最高的频次（kind 2，划过窗口就是几百条）——每移一格白扫一遍
/// 全表。`target` 与 `window` 这两本账照旧无条件算：前者每一路都要，后者的表是
/// `live_windows`（通常个位数），贵的只有这一本。
pub fn needs_owner(kb : Int32) -> Bool {
  split_kind_button(kb).kind == 4
}

///|
/// 鼠标判定的全表（`T143`）。
///
/// 入参是**已经反查好**的账，与后端那三条反查一一对应：
/// - `target`：`native_mouse_target()` 的反查结果（命中控件；空白处 mac 半报窗口）；
/// - `window`：`drop_target_window()` 的结果（"空白处退到窗口自己"）；
/// - `owner`：`native_mouse_owner()` 的反查结果（`T102` 第十二刀的第二本账，
///   滚轮改判给自绘面时才用）；
/// - `target_is_custom` / `owner_is_custom`：这两只控件是不是自绘面（`T110` 的
///   登记表）。用两个 Bool 而不是一个判据函数：判定要纯，测试不想为了喂一个值
///   就造一个闭包。
///
/// 分支顺序**照着原闭包一字不差**，这不是风格问题：右键按下（kind 0 button 1）
/// 排在自绘面左键那支前面，于是自绘面上按右键走 Right 而不是 Left；双击
/// （kind 3）排在最前，它不看控件种类。调换任何两支都会改行为。
pub fn mouse_decision(
  kb : Int32,
  target : @moonui.NativeHandle?,
  window : @moonui.NativeHandle?,
  owner : @moonui.NativeHandle?,
  target_is_custom : Bool,
  owner_is_custom : Bool,
) -> MouseDecision {
  let k = split_kind_button(kb)
  // ---- 悬停通道：kind 2 移动 / kind 5 离开窗口 ----
  //
  // 两支同一个落点：空白处在 C 侧报**窗口自己**，Core 拿"target 是窗口"当
  // unhover 信号。kind 5 是 `T98①` 从 kind 3 挪出来的——kind 3 让给双击。
  // 这两支**不看**是不是自绘面：悬停在谁身上就报谁。
  if k.kind == 2 || k.kind == 5 {
    return match target {
      Some(h) => MouseDecision::MoveTo(h)
      None =>
        match window {
          Some(w) => MouseDecision::MoveTo(w)
          None => MouseDecision::Drop
        }
    }
  }
  // ---- 滚轮（kind 4）----
  //
  // 只改判给自绘面：原生控件的滚轮照旧归窗口（它们的滚动被 NSScrollView 之类
  // 自己吃掉，控件级没有消费者），而自绘面没有原生滚动容器，除了这条没有别的
  // 路能收到滚轮（`T102` 第八刀记的缺口正是这个）。
  if k.kind == 4 {
    // 收件人按"命中控件 → 自绘面 owner → 窗口"三级退，任何一级认出来就在那里
    // 停住；三级全空才整条丢掉。
    let recipient = match target {
      Some(h) => Some(h)
      None =>
        match owner {
          Some(o) if owner_is_custom => Some(o)
          _ => window
        }
    }
    return match recipient {
      Some(h) => MouseDecision::WheelTo(h)
      None => MouseDecision::Drop
    }
  }
  // ---- 按键类：只有命中我们的控件才有 Core 侧消费者 ----
  let h = match target {
    Some(h) => h
    None => return MouseDecision::Drop
  }
  // 双击（`T141` 补的那一支）：mac 的 clickCount>=2、Win32 的
  // WM_*BUTTONDBLCLK 都报 kind 3，第二次按下**不再产 kind 0**。
  if k.kind == 3 {
    return MouseDecision::DoubleTo(h)
  }
  // 只有右键按下有消费者。左键按下的消费者是控件回调自己发的 Click，
  // 这里不重复建一条。
  if k.kind == 0 && k.button == 1 {
    return MouseDecision::PressTo(h, @moonui.Right)
  }
  // 自绘面的左键：kind 0 按下 / kind 1 抬起。
  //
  // 键位**恒报 `Left`**，照原闭包一字不差：那一支从来没读过 button 位，
  // 于是自绘面上的中键（C 侧报 kind 0 button 2）重构前也报 Left。这一轮是
  // 搬运、不是改行为，所以照抄这个形状；中键接不接是另一笔账，接的时候改
  // 这里、用 `mouse_button_of`。
  if target_is_custom && (k.kind == 0 || k.kind == 1) {
    return if k.kind == 0 {
      MouseDecision::PressTo(h, @moonui.Left)
    } else {
      MouseDecision::ReleaseTo(h, @moonui.Left)
    }
  }
  // 原生控件的**左键**按下/抬起（`T263`）：此前只有自绘面翻译这两支，原生
  // 控件的左键消费者只有控件回调自己发的 `Click`（`MoonuiClickPanel` /
  // `MoonuiCustomView` 的 mouseUp）。那条路在两点上不够用，而且两点都是
  // 真机才暴露的：
  //   ① 拖放会话（`T102` 第二十四刀）只能从 `MouseDown` 发起（`App::begin_drag`
  //      用 `in_flight` 锚窗口），于是原生控件从来开不了会话——`T176` 的队列
  //      拖拽因此在 mac 上「拖不动」，三轮真机验收都没查出原因；
  //   ② 修饰键（`T259` 的 ⌘ 累加 / ⇧ 范围）靠 `MouseDown` 把 `Mods` 存下来，
  //      `Click` 不带修饰键，于是原生端永远只走「单选替换」。
  // `Click` 仍然照发（它来自控件自己的 mouseUp，与这里不是同一条），订阅
  // `Click` 的既有代码一字不动。只认**左键**（button 0）：右键抬起、中键
  // 按下/抬起都不在这里建事件（右键菜单在按下就开，中键没有消费者）。
  //
  // 附带效果：长按识别（`T86⑧`）从"只对自绘面生效"扩到所有原生控件——
  // 它的消费者是应用自己订阅的 `LongPress`，框架内没有内置行为。
  if k.button == 0 && (k.kind == 0 || k.kind == 1) {
    return if k.kind == 0 {
      MouseDecision::PressTo(h, @moonui.Left)
    } else {
      MouseDecision::ReleaseTo(h, @moonui.Left)
    }
  }
  MouseDecision::Drop
}

///|
/// 手势相位编码（adapter.h 手势段）：0 began / 1 changed / 2 ended / 3 cancelled。
/// 表外的值按 `Changed` 算——那是"这一步的增量"最保守的一档，不把一条来路不明
/// 的读数说成手势开始或结束。
pub fn gesture_phase(code : Int32) -> @moonui.GesturePhase {
  match code {
    0 => @moonui.GesturePhase::Began
    2 => @moonui.GesturePhase::Ended
    3 => @moonui.GesturePhase::Cancelled
    _ => @moonui.GesturePhase::Changed
  }
}

///|
/// 滑动方向编码：0 左 / 1 右 / 2 上 / 3 下（表外按左算，静默不猜）。
pub fn swipe_direction(code : Int32) -> @moonui.SwipeDirection {
  match code {
    1 => @moonui.SwipeDirection::Right
    2 => @moonui.SwipeDirection::Up
    3 => @moonui.SwipeDirection::Down
    _ => @moonui.SwipeDirection::Left
  }
}

///|
/// 目录行走的打包格式解码（adapter.h 走行段）：
/// `[int32 count]` + count 个 `[int32 len][len 字节 UTF-8 路径]`。
///
/// **坏了就返回已经解出来的那部分，逐项隔离**（C-10 风险 4）：布局截断、
/// 长度为负、长度越过末尾，三种都停在这里返回当前结果，不 raise、不整份作废。
/// 为什么是这个策略：这条链的另一头是 C 现编的打包，报错也没有能让它变好的
/// 动作，而"多带几条真路径回去"比"一条都不带"对调用者有用。
///
/// 空包（长度不足 4，`T142` 打的"打不开的目录"那格）返回空数组——与"布局坏了
/// 但一条都还没解出来"同一个结果，这是有意的：调用方对两者的处理相同。
pub fn decode_walk_packet(packed : Bytes) -> Array[String] {
  let out : Array[String] = []
  if packed.length() < 4 {
    return out
  }
  fn i32le(at : Int32) -> Int32 {
    packed.get(at).unwrap().to_int() |
    (packed.get(at + 1).unwrap().to_int() << 8) |
    (packed.get(at + 2).unwrap().to_int() << 16) |
    (packed.get(at + 3).unwrap().to_int() << 24)
  }
  let count = i32le(0)
  let mut at = 4
  for i = 0; i < count; i = i + 1 {
    let _ = i
    if at + 4 > packed.length() {
      return out // 布局坏了：返回已收到的部分
    }
    let len = i32le(at)
    at = at + 4
    if len < 0 || at + len > packed.length() {
      return out
    }
    let seg = packed.exact_view(start=at, end=at + len)
    out.push(@utf8.decode_lossy(seg))
    at = at + len
  }
  out
}

///|
/// 输出设备清单的打包格式解码（`T169`，adapter.h 输出设备段）：
/// `[int32 count][int32 current]` + count 个 `[int32 len][len 字节 UTF-8 名]`，
/// current 是当前设备在表里的下标，-1 = 没有当前（枚举不出/未实现）。
///
/// 隔离策略与 `decode_walk_packet` 同一条：坏了一项丢一项、坏到哪算哪，
/// 不 raise、不整份作废。空包/短包（不足 8）返回空表 + current=-1——
/// Windows 空桩就住这一格，调用方据此降级（不挂子菜单）。
/// 设备名列表 + 当前设备下标（-1 = 没有当前）。derive(Debug, Eq) 给失败断言
/// 打差异用（沿本包 moon.pkg 里那一条说明）。
#derive(Debug, Eq)
pub struct AudioOutputs {
  devices : Array[String]
  current : Int32
}

///|
pub fn decode_audio_outputs_packet(packed : Bytes) -> AudioOutputs {
  let devices : Array[String] = []
  let mut current = -1
  if packed.length() < 8 {
    return { devices, current, }
  }
  fn i32le(at : Int32) -> Int32 {
    packed.get(at).unwrap().to_int() |
    (packed.get(at + 1).unwrap().to_int() << 8) |
    (packed.get(at + 2).unwrap().to_int() << 16) |
    (packed.get(at + 3).unwrap().to_int() << 24)
  }
  let count = i32le(0)
  current = i32le(4)
  let mut at = 8
  for i = 0; i < count; i = i + 1 {
    let _ = i
    if at + 4 > packed.length() {
      break // 布局坏了：返回已收到的部分
    }
    let len = i32le(at)
    at = at + 4
    if len < 0 || at + len > packed.length() {
      break
    }
    let seg = packed.exact_view(start=at, end=at + len)
    devices.push(@utf8.decode_lossy(seg))
    at = at + len
  }
  { devices, current, }
}

///|
/// ---------------------------------------------------------------------------
/// native-common 抽出来的 ABI 编码 / 拆包 / 返回码翻译判定表（`T230`）
/// ---------------------------------------------------------------------------
///
/// `backends/native-common` 整包逐文件 `[native]` 门控（见它的 moon.pkg:41-43）：
/// 226 个 extern 在 wasm 上没有宿主，那里**加不了测试文件**，于是约 6300 行
/// 胶水层一条无头判据都没有，回归全押在本身有偶发红的真窗测试上。
///
/// 这里收的是那些"其实只是整数 / 位运算 / match"的共用算式：它们原先散在
/// `native-common/ffi.mbt`（`unpack2` / `kind_code`）与 `canvas.mbt`
/// （`canvas_check` / measure_text 的 Int64 拆包）里，行为逐字搬过来，调用点
/// 改成一行委托。判据住在本包、进 wasm 门；委托层只有一行，靠
/// `moon check --deny-warn` 与逐字审查兜住——那层没有、也加不了无头判据，
/// 是技术边界而非遗漏，别把"委托层未被判据覆盖"读成本刀没做完。
///
/// 口径：以后新增 `moonui_native_*` 的编码 / 拆包 / 返回码翻译，先放这里并配
/// 判据，别再直接写进 extern 封装的身体里。`T143` 那条"判定表要能喂假输入"
/// 对这半同样成立。

///|
/// C 侧一次回两个 int32 时打包进一个 Int64：高 32 位在前、低 32 位在后。
/// 高位用算术右移还原（`Int64 >>` 保留符号位），低位靠 `<< 32 >> 32` 做符号
/// 扩展再截成 Int32——窗口坐标可以为负，这两条都不能换成无符号 mask。
///
/// 原住 `native-common/ffi.mbt:22` 的 `unpack2`，12 处调用（窗口尺寸/位置、
/// 屏幕工作区、控件 origin/size、鼠标 pos/delta）共用这一条算式。
pub fn unpack_i32_pair(v : Int64) -> (Int32, Int32) {
  ((v >> 32).to_int(), (v << 32 >> 32).to_int())
}

///|
/// `widget_new` 的 kind 编码表：与 C 侧 `moonui_native_widget_new` 的分支逐格
/// 对齐（有效格 0..5 与 13..19；6..12 是 Slider 那一族专属入口**没有**占的
/// 空洞）。纯布局节点和走专属入口的叶子都显式 `Unsupported`，不猜一个码递
/// 下去。
///
/// 原住 `native-common/ffi.mbt:1003` 的 `kind_code`。`WebView = 19` 是最容易
/// 漏的一格：Windows 半没有 WKWebView，但**码表仍要报 19**，由下游 register
/// 的空指针如实报 `OperationFailed`，不能在这里就地改成别的码
/// （T102 第二十五刀）。
pub fn widget_kind_code(
  kind : @moonui.WidgetKind,
) -> Int32 raise @moonui.UiError {
  match kind {
    @moonui.Label => 0
    @moonui.Button => 1
    @moonui.TextInput => 2
    @moonui.Checkbox => 3
    @moonui.PasswordInput => 4
    @moonui.Separator => 5
    @moonui.VSeparator => 13
    @moonui.MenuRow => 14
    @moonui.Scroll => 15
    @moonui.Image => 16
    @moonui.Panel => 17
    @moonui.Custom => 18
    @moonui.WebView => 19
    @moonui.Row
    | @moonui.Column
    | @moonui.Padding
    | @moonui.Spacer
    | @moonui.Center
    | @moonui.Stack
    | @moonui.Grid =>
      raise @moonui.Unsupported(
        "纯布局节点（Row/Column/…）不占原生对象",
      )
    _ =>
      raise @moonui.Unsupported(
        "这个控件种类走专属的创建入口，不走 moonui_native_widget_new",
      )
  }
}

///|
/// 返回码 → `UiError` 的唯一一处翻译。`what` 是完整上下文（调用方传
/// `"画布 填充"` 这类），消息形状 `\{what} 失败（rc=\{rc}）` 与搬来之前一致。
/// **0 是唯一成功值**：正 rc 同样算失败，不能只判 `rc < 0`。
///
/// 原住 `native-common/canvas.mbt:220` 的 `canvas_check`，24 个 `canvas_*`
/// 封装共用；`ffi.mbt` 的 `native_init` / `register` 是另外两条翻译路，不归这里。
pub fn check_rc(rc : Int32, what : String) -> Unit raise @moonui.UiError {
  if rc != 0 {
    raise @moonui.OperationFailed("\{what} 失败（rc=\{rc}）")
  }
}

///|
/// `moonui_canvas_measure_text` 把 (宽, 高) 打包进一个 Int64 的拆包。
/// 与 `unpack_i32_pair` **口径不同**：这里低位用 `& 0xFFFFFFFFL` 当无符号读
/// （文本宽高不会是负数），高位仍是算术右移。这不是笔误，别顺手"统一"成
/// 同一条算式——坐标/尺寸要能是负数，度量结果不要。
pub fn unpack_measure_text(packed : Int64) -> (Double, Double) {
  ((packed >> 32).to_double(), (packed & 0xFFFFFFFFL).to_double())
}

///|
/// ---------------------------------------------------------------------------
/// `T236`：native-common 剩下的返回码翻译与位拆包判定表
/// ---------------------------------------------------------------------------
///
/// `T230` 搬走了四张共用表，这里收第二遍扫出来的两类：
///
/// ① **返回码 → 分支 / 文案**。`ffi.mbt` 里 14 处 `match c_xxx(...)` 其实只有
/// 两种形状：`0 / -1 / 其余`（十处，都是"0 成功、-1 第一类故障、其余第二类
/// 故障"）与 `1 / 0 / -1 / 其余`（四处对话框与文件面板，1/0 是**答案**不是成功
/// 码）。文案由调用方**逐字**传进来，本包只回答"该走哪一档"——和 `check_rc`
/// 的 `what` 同一条口径，不在这里造文案，也不动 `UiError` 的形状。
///
/// ② **C 打包整数的位拆包**。`moonui_native_window_state` 回 bit0/bit1，
/// `moonui_native_image_probe` 回 bit0 + 8..23 宽 + 32..47 高；与
/// `unpack_i32_pair` / `unpack_measure_text` 同族，只是位域不同。
///
/// ③ **`backend.mbt` 里仅剩的两张纯码表**：`host_platform` 的 1/2/其余 →
/// HostPlatform，与无障碍状态的位打包。87 个 `Backend` impl 里其余都是句柄表
/// 与 extern 调用，抽不动（`T236` 取证结论见 `TODO.md`）。
///
/// 同样只收"能喂假输入"的纯判定：句柄表、extern 调用、`c_last_error()` 这类
/// 带求值顺序的都留在 `native-common`。委托层一行，靠
/// `moon check --deny-warn` 与逐字审查；判据在本包、进 wasm 门。

///|
/// 三档返回码表：0 成功；-1 → `first_msg`；其余（含 -2、正数、INT32_MIN）
/// → `other_msg`。**0 是唯一成功值**，别把 `rc != 0` 写成 `rc < 0`。
///
/// 原住 `native-common/ffi.mbt` 十处 `match c_xxx(...)`：clipboard_set_text /
/// dialog_message / set_menu_bar / set_app_icon / image_set_{path,data} /
/// tray_set_{icon,menu} / set_focus_chain / show_context_menu。`native_notify`
/// 多一档 -3（无 bundle 专属文案），形状不同，**不走这条表**。
pub fn check_two_stage_rc(
  rc : Int32,
  first_msg : String,
  other_msg : String,
) -> Unit raise @moonui.UiError {
  match rc {
    0 => ()
    -1 => raise @moonui.OperationFailed(first_msg)
    _ => raise @moonui.OperationFailed(other_msg)
  }
}

///|
/// 对话框 / 文件面板四态表：`true` = 用户选了（或选了路径）、`false` = 取消；
/// -1 是"文案没能交给系统"，其余是"没弹出来"。**1 与 0 都是正常答案**，不是
/// 成功码 / 失败码，别拿 `check_rc` 套它。
///
/// 原住 `native-common/ffi.mbt` 四处：`native_dialog_confirm` 与
/// `native_{open_file,save_file,select_folder}`；后三者在 `true` 时才去取
/// `file_dialog_result()`，取路径的时机由委托层保持原样。
pub fn dialog_answer_rc(
  rc : Int32,
  first_msg : String,
  other_msg : String,
) -> Bool raise @moonui.UiError {
  match rc {
    1 => true
    0 => false
    -1 => raise @moonui.OperationFailed(first_msg)
    _ => raise @moonui.OperationFailed(other_msg)
  }
}

///|
/// `moonui_native_window_state` 的 bit0 = 最小化、bit1 = 最大化，其余位忽略。
/// 两侧 C 都只置这两位（`adapter_native.m:1469` / `adapter_native.c:3705`）。
/// 负数按 Int32 取模的既有行为读：C 侧不会回负数，判据里仍钉一格，防止有人
/// 把 `== 1` 改成 `!= 0` 时悄悄把负 bit 认成"最小化"。
pub fn window_state_of_bits(bits : Int32) -> @moonui.WindowState {
  @moonui.WindowState::{
    minimized: bits % 2 == 1,
    maximized: bits / 2 % 2 == 1,
  }
}

///|
/// `moonui_native_image_probe` 的打包：bit0 有没有图、8..23 位像素宽、
/// **32..47 位像素高**。两侧 C 都是 `1 | (w << 8) | (h << 32)`
/// （`adapter_native.m:3318` / `adapter_native.c:4433`）；`adapter.h:1729`
/// 的老注释写"24..39 位 = 像素高"是文档漂移，本刀只订正注释、不改行为。
/// -1（句柄不指 Image 控件）由委托层先挡掉，这里收的是非负 packed 值。
pub fn unpack_image_probe(bits : Int64) -> (Bool, Int32, Int32) {
  (
    bits % 2L == 1L,
    ((bits >> 8) % 65536L).to_int(),
    ((bits >> 32) % 65536L).to_int(),
  )
}

///|
/// `moonui_native_host_platform` 的码表：1 = macOS、2 = Windows，其余（含 0、
/// 负数、将来新加而共享层没跟上的宿主）一律降级 `Unknown`，不 panic——血统读
/// 数错了顶多是多画一排窗口钮。原住 `native-common/backend.mbt:1111`。
pub fn host_platform_of_code(code : Int32) -> @moonui.HostPlatform {
  match code {
    1 => @moonui.Macos
    2 => @moonui.Windows
    _ => @moonui.Unknown
  }
}

///|
/// `AccessState` → ABI 位包：bit0 visible、bit1 enabled、bits2-3 checked
/// （None = 0、Some(false) = 4、Some(true) = 8）。原住
/// `native-common/backend.mbt:1713`，那里留一行委托；位布局见 `adapter.h`。
pub fn access_state_code(st : @moonui.AccessState) -> Int32 {
  let base = (if st.visible { 1 } else { 0 }) + (if st.enabled { 2 } else { 0 })
  match st.checked {
    None => base
    Some(false) => base + 4
    Some(true) => base + 8
  }
}
