///|
/// 快捷键值类型（设计文档 §26）。
///
/// 文档给了三种写法：`Ctrl + S`、`Ctrl + Shift + P`、`Cmd + S`。这里把修饰键
/// 保持成显式字段——`ctrl` 就是物理 Ctrl，`meta` 在 macOS 上是 Cmd、在
/// Windows/Linux 上是 Win/Super，Core 不做"Cmd 或 Ctrl"的隐式替换。这种归一化
/// 属于平台层（§20/§21 的后端），把它藏在 Core 里会让同一个快捷键在不同
/// 平台上指向不同组合，反而更难推理。

///|
pub(all) struct Shortcut {
  key : String
  ctrl : Bool
  alt : Bool
  shift : Bool
  meta : Bool
} derive(Debug, Eq)

///|
fn shortcut_of(
  key : String,
  ctrl : Bool,
  alt : Bool,
  shift : Bool,
  meta : Bool,
) -> Shortcut {
  Shortcut::{ key, ctrl, alt, shift, meta, }
}

///|
/// 无修饰键的单键（`F5`、`Enter` 这类才有意义；字母键通常需要组合）。
pub fn Shortcut::new(key : String) -> Shortcut {
  shortcut_of(key, false, false, false, false)
}

///|
pub fn Shortcut::ctrl(key : String) -> Shortcut {
  shortcut_of(key, true, false, false, false)
}

///|
pub fn Shortcut::alt(key : String) -> Shortcut {
  shortcut_of(key, false, true, false, false)
}

///|
/// Cmd/Ctrl 之外的那个"系统键"组合（macOS 的 ⌘、Windows 的 Win）。
pub fn Shortcut::meta(key : String) -> Shortcut {
  shortcut_of(key, false, false, false, true)
}

///|
/// 链式追加修饰键。`Shortcut` 是不可变值，每次返回新的组合。
pub fn Shortcut::with_ctrl(self : Shortcut, v : Bool) -> Shortcut {
  shortcut_of(self.key, v, self.alt, self.shift, self.meta)
}

///|
pub fn Shortcut::with_alt(self : Shortcut, v : Bool) -> Shortcut {
  shortcut_of(self.key, self.ctrl, v, self.shift, self.meta)
}

///|
pub fn Shortcut::with_shift(self : Shortcut, v : Bool) -> Shortcut {
  shortcut_of(self.key, self.ctrl, self.alt, v, self.meta)
}

///|
pub fn Shortcut::with_meta(self : Shortcut, v : Bool) -> Shortcut {
  shortcut_of(self.key, self.ctrl, self.alt, self.shift, v)
}

///|
/// 后端把原生按键归一化成 `KeyPress` 后，Core 用它还原成快捷键形态。
pub fn Shortcut::from_key_press(kp : KeyPress) -> Shortcut {
  shortcut_of(kp.key, kp.ctrl, kp.alt, kp.shift, kp.meta)
}

///|
/// 反向：把组合当成一次按键事件（菜单项的 shortcut 需要合成 KeyDown 时用）。
pub fn Shortcut::key_press(self : Shortcut) -> KeyPress {
  KeyPress::{
    key: self.key,
    ctrl: self.ctrl,
    alt: self.alt,
    shift: self.shift,
    meta: self.meta,
  }
}

///|
/// 修饰键组合必须完全一致——多一个 Shift 就是另一个快捷键，不做子集匹配。
pub fn Shortcut::matches(self : Shortcut, kp : KeyPress) -> Bool {
  kp.matches(self.key, self.ctrl, self.alt, self.shift, self.meta)
}

///|
pub fn Shortcut::matches_shortcut(self : Shortcut, other : Shortcut) -> Bool {
  self == other
}

///|
/// 菜单里显示的组合文本。顺序固定为 Ctrl → Alt → Shift → Meta，
/// 与 macOS 的 ⌃⌥⇧⌘ 顺序一致。`meta` 在这里渲染成中性词 "Meta"：
/// ⌘/Win/Super 的图形字形属于渲染层（§18）和平台本地化，Core 只给可读文本。
/// 键名原样输出，所以字母键请传小写字母（`Ctrl+S` 用 `Shortcut::ctrl("s")`）。
pub fn Shortcut::label(self : Shortcut) -> String {
  let parts : Array[String] = []
  if self.ctrl {
    parts.push("Ctrl")
  }
  if self.alt {
    parts.push("Alt")
  }
  if self.shift {
    parts.push("Shift")
  }
  if self.meta {
    parts.push("Meta")
  }
  parts.push(self.key)
  let mut out = ""
  for p in parts {
    out = if out == "" { p } else { out + "+" + p }
  }
  out
}

///|
/// 常用快捷键的预设分类（`T129`）：`App::standard_shortcut` 按它给组合，
/// `App::standard_menu_item` 按它造菜单项。单独成枚举而不是散几个函数，
/// 是为了让"平台标准组合"这份清单有一个能被引用的名字。
pub(all) enum StandardShortcut {
  Quit
  Cut
  Copy
  Paste
  SelectAll
  Save
  Close
} derive(Debug, Eq)

///|
/// 平台标准组合（`T129`）：mac 上是 ⌘（`meta`），其余平台是 `ctrl`。Core
/// 仍然不做"⌘ 或 Ctrl"的隐式替换（上面那份归一化注记）——这条归一化写
/// 在这里、由 `backend().host_platform()` 当场裁决，因为它量的是"这份组合
/// 在这个平台上的标准写法"，不是把应用声明的组合偷换成另一个。
pub fn[B : Backend] App::standard_shortcut(
  self : App[B],
  which : StandardShortcut,
) -> Shortcut {
  let key = match which {
    Quit => "q"
    Cut => "x"
    Copy => "c"
    Paste => "v"
    SelectAll => "a"
    Save => "s"
    Close => "w"
  }
  if self.backend().host_platform() == Macos {
    Shortcut::meta(key)
  } else {
    Shortcut::ctrl(key)
  }
}

///|
/// 按预设造一颗菜单项（`T129`）：组合走 `standard_shortcut`，自定义菜单栏
/// 里拿来即用、不用手写快捷键。只有 `Quit` 自带行为（接 `App::quit`）；
/// 其余**不带回调**——`Save`/`Close` 是应用自己的语义，`.on()` 接上即用。
/// `Cut`/`Copy`/`Paste`/`SelectAll` 在 mac 上建议不要再造一份：无自定义
/// 菜单栏的应用由原生后端的默认「编辑」菜单用系统 responder 链接好了
/// （对文本框真正生效靠标准 selector，走 Core 回调的那份得自己做剪贴板
/// 读写）；真要造，同一个组合两份菜单项时按主菜单顺序先命中先赢。
pub fn[B : Backend] App::standard_menu_item(
  self : App[B],
  which : StandardShortcut,
  label : String,
) -> MenuItem {
  let item = MenuItem::new(label)
  item.set_shortcut(self.standard_shortcut(which))
  match which {
    Quit => {
      let _ = item.on(fn(_) { self.quit() })
    }
    _ => ()
  }
  item
}

///|
test "Shortcut 组合出文档 §26 的三个例子" {
  assert_eq(Shortcut::ctrl("s").label(), "Ctrl+s")
  assert_eq(Shortcut::ctrl("p").with_shift(true).label(), "Ctrl+Shift+p")
  assert_eq(Shortcut::meta("s").label(), "Meta+s")
  let mixed = Shortcut::new("p").with_ctrl(true).with_alt(true).with_shift(true)
  assert_eq(mixed.label(), "Ctrl+Alt+Shift+p")
}

///|
test "Shortcut 与 KeyPress 往返回，匹配要求修饰键全等" {
  let sc = Shortcut::ctrl("s").with_shift(true)
  let kp = sc.key_press()
  assert_true(sc.matches(kp))
  assert_eq(Shortcut::from_key_press(kp), sc)
  // 少一个 Shift 就是另一个快捷键
  assert_false(
    sc.matches(KeyPress::{
      key: "s",
      ctrl: true,
      alt: false,
      shift: false,
      meta: false,
    }),
  )
  // 大小写不同也是不同的键
  assert_false(
    Shortcut::ctrl("s").matches(KeyPress::{
      key: "S",
      ctrl: true,
      alt: false,
      shift: false,
      meta: false,
    }),
  )
}
