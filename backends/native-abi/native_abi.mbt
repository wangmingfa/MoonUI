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
pub(all) struct KindButton {
  kind : Int32
  button : Int32
} derive(Debug, Eq)

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
} derive(Debug, Eq)

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
  // 自绘面的左键：kind 0 按下 / kind 1 抬起。原生控件不翻译这两支——
  // 它们的左键消费者是控件回调发的 Click，补上会改既有行为（长按识别
  // `T86⑧` 也吃 MouseDown(Left)，一并会动）。
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
