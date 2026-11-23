///|
/// `UiTextInput` / `UiSpinbox`——自绘外壳 + 内嵌原生编辑（`T352`）。
///
/// **为什么不整只自绘**：文本框要光标、选区、输入法候选窗、中文上屏、剪贴板、
/// 拖选——这些是系统编辑控件的红利（§32 明说"输入法 UI 交给原生控件"），
/// 自己实现一遍就是拿几万行换一个更会丢输入法的输入框。**为什么不整只原生**：
/// 原生编辑框的脸是系统画的（Win32 是白底黑框、深色主题下也是白的），边框、
/// 圆角、内边距、悬停与焦点环一律改不了。
///
/// 折中：**壳自绘，输入原生**。两层 Panel 叠出一个 1px 的圆角边框——
/// 外层涂边框色、内缩 1px，内层涂面色、再内缩出内边距，原生编辑框铺在最里面。
/// 两层底都是"面色"，与编辑框自己的白底同色，于是四角的圆弧里不会露出方角
/// （这是"两层同色"而不是"一层描边"的原因：`StrokeRect` 只画得出线，画不出
/// 线外那圈底色）。焦点/悬停只换外层那一格颜色，编辑框本身一动不动。
///
/// 已知边界：编辑框内部仍是系统配色（Win32 的 `WM_CTLCOLOREDIT` 没接），所以
/// 深色主题下框内的字与底还是系统给的那一套——这是原生输入红利的另一面，
/// 要改得给编辑框接自绘文字层，那是另一笔账，不在本条。

///|
/// 输入壳的可变账：焦点、悬停、使能与回调。注意这里**不存文本**——文本的
/// 唯一事实来源是原生编辑框（`Widget::text()`），壳自己记一份只会多一份过期
/// 的真话。
struct InputState {
  mut theme : UiTheme
  mut enabled : Bool
  mut focused : Bool
  mut hovered : Bool
  mut handler : ((String) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘外壳的文本输入框。
pub struct UiTextInput[B] {
  backend : B
  root : @moonui.Widget[B]
  /// 外层那圈（边框色 / 焦点色靠它换）
  shell : @moonui.Widget[B]
  /// 内层那圈（面色 / 内圆角靠它换）——换主题时要重刷，不能只刷外壳
  inner : @moonui.Widget[B]
  size : UiSize
  /// 原生编辑框
  field : @moonui.Widget[B]
  state : InputState
}

///|
/// 当前该涂什么颜色的边框：禁用 → 焦点 → 悬停 → 静息，四档只换这一格。
fn ui_input_ring(st : InputState) -> Int32 {
  let t = st.theme
  if !st.enabled {
    t.surface_active
  } else if st.focused {
    t.accent
  } else if st.hovered {
    t.border_strong
  } else {
    t.border
  }
}

///|
/// 把边框色刷到外层壳上。整份 `Style` 要重写（`set_style` 是整体替换，不是
/// 合并）：底色、圆角、1px 内缩三样都得带着，少一样就丢一样。
fn[B] ui_input_paint_ring(
  shell : @moonui.Widget[B],
  st : InputState,
) -> Unit raise @moonui.UiError {
  let r = st.theme.radius
  shell.set_style(
    Some(
      @moonui.style(
        background=Some(ui_color(ui_input_ring(st))),
        radius=Some(r),
        padding=Some(@moonui.EdgeInsets::all(1.0)),
      ),
    ),
  )
}

///|
/// 造一个输入框。`password=true` 走系统的密码遮盖（原生编辑框的 `ES_PASSWORD`
/// 那一路，光标与输入法行为与明文框完全一致）。
pub fn[B : @moonui.Backend] UiTextInput::UiTextInput(
  backend : B,
  text~ : String = "",
  placeholder~ : String = "",
  password~ : Bool = false,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  width~ : Double = 220.0,
  enabled~ : Bool = true,
) -> UiTextInput[B] raise @moonui.UiError {
  let metrics = theme.metrics(size)
  let field = if password {
    @moonui.Widget::password_input(backend, text)
  } else {
    @moonui.Widget::text_input(backend, text)
  }
  if placeholder != "" {
    field.set_placeholder(placeholder)
  }
  field.set_enabled(enabled)
  // 原生编辑框自带的那圈边必须摘掉（`T353`）：壳已经画了 1px 圆角边，留着它
  // 就是"圆角边里套一层系统方边"——截图里一眼就能看见的两层框。
  field.set_frameless(true)
  // 内层：面色 + 比外圈小 1 的圆角 + (4,10) 内边距——编辑框落在里面
  let inner = @moonui.Widget::panel(backend, field)
  inner.set_style(
    Some(
      @moonui.style(
        background=Some(ui_color(theme.surface)),
        radius=Some(if theme.radius > 2.0 { theme.radius - 1.0 } else { 0.0 }),
        padding=Some(@moonui.EdgeInsets::symmetric(4.0, 10.0)),
      ),
    ),
  )
  let shell = @moonui.Widget::panel(backend, inner)
  let state = InputState::{
    theme,
    enabled,
    focused: false,
    hovered: false,
    handler: None,
  }
  ui_input_paint_ring(shell, state)
  // 高度钉在档高上：编辑框的原生固有高各平台不同（Win32 ≈ 23、mac 略矮），
  // 由壳统一成一个数，一排输入框才参齐
  let root = @moonui.Widget::sized(
    backend,
    Some(if width > 0.0 { width } else { 220.0 }),
    Some(metrics.height),
    shell,
  )
  // 焦点与悬停挂在**编辑框**上：壳的 1px 边圈几乎不可能被指针命中
  let _ = field.on(
    fn(e) {
      match e {
        @moonui.Focus(_) | @moonui.Blur(_) => true
        @moonui.MouseEnter(_) | @moonui.MouseLeave(_) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.Focus(_) =>
          if !state.focused {
            state.focused = true
            ui_input_paint_ring(shell, state)
          }
        @moonui.Blur(_) =>
          if state.focused {
            state.focused = false
            ui_input_paint_ring(shell, state)
          }
        @moonui.MouseEnter(_) =>
          if !state.hovered {
            state.hovered = true
            ui_input_paint_ring(shell, state)
          }
        @moonui.MouseLeave(_) =>
          if state.hovered {
            state.hovered = false
            ui_input_paint_ring(shell, state)
          }
        _ => ()
      }
    },
  )
  let _ = field.on_input(fn(t) raise @moonui.UiError {
    match state.handler {
      Some(f) => f(t)
      None => ()
    }
  })
  { backend, root, shell, inner, size, field, state, }
}

///|
/// 密码框的糖：与 `UiTextInput` 同一只控件，只是默认走了遮盖那一路。
pub fn[B : @moonui.Backend] UiTextInput::password(
  backend : B,
  text~ : String = "",
  placeholder~ : String = "",
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  width~ : Double = 220.0,
) -> UiTextInput[B] raise @moonui.UiError {
  UiTextInput::UiTextInput(
    backend,
    text~,
    placeholder~,
    password=true,
    theme~,
    size~,
    width~,
  )
}

///|
/// 根（挂进布局用这个）。
pub fn[B] UiTextInput::view(self : UiTextInput[B]) -> @moonui.Widget[B] {
  self.root
}

///|
/// 原生编辑框本身：要设上下文菜单、订阅 `KeyDown`（回车提交）这类深一层的事，
/// 从这里拿。
pub fn[B] UiTextInput::field(self : UiTextInput[B]) -> @moonui.Widget[B] {
  self.field
}

///|
pub fn[B : @moonui.Backend] UiTextInput::text(
  self : UiTextInput[B],
) -> String raise @moonui.UiError {
  self.field.text()
}

///|
/// 程序设文本：与当前一致就不碰原生控件（原生编辑框的 `SetWindowText` 会把
/// 光标挪到末尾，滚动位置也会跳）。
pub fn[B : @moonui.Backend] UiTextInput::set_text(
  self : UiTextInput[B],
  text : String,
) -> Unit raise @moonui.UiError {
  if self.field.text() == text {
    return
  }
  self.field.set_text(text)
}

///|
/// 占位提示（空框时显示）。
pub fn[B : @moonui.Backend] UiTextInput::set_placeholder(
  self : UiTextInput[B],
  text : String,
) -> Unit raise @moonui.UiError {
  self.field.set_placeholder(text)
}

///|
/// 每次内容变化的回调（携带全文）。
pub fn[B] UiTextInput::on_input(
  self : UiTextInput[B],
  f : (String) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 使能开关：禁用时编辑框不接收输入、边框退到禁用档。
pub fn[B : @moonui.Backend] UiTextInput::set_enabled(
  self : UiTextInput[B],
  enabled : Bool,
) -> Unit raise @moonui.UiError {
  if self.state.enabled == enabled {
    return
  }
  self.state.enabled = enabled
  self.field.set_enabled(enabled)
  ui_input_paint_ring(self.shell, self.state)
}

///|
/// 手写整数解析：只认可选负号 + 十进制数字，最多 9 位（超过 2^31 直接放弃）。
///
/// 为什么不用 `@string.parse_int`：数字输入框的输入是"打字途中的半成品"
/// （"-"、"12"、"1200" 都可能出现），要的是"现在还不成数"这种安静的 `None`，
/// 而不是一个为了区分溢出/格式而抛出来的异常。位数上限顺带挡掉了溢出。
fn ui_parse_int(s : String) -> Int32? {
  let t = s.trim().to_owned()
  let cs = t.to_array()
  let n = cs.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if cs[0] == '-' {
    neg = true
    i = 1
    if n == 1 {
      return None
    }
  }
  let mut acc = 0
  let mut digits = 0
  while i < n {
    let c = cs[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    acc = acc * 10 + (c - 48)
    digits = digits + 1
    if digits > 9 {
      return None
    }
    i = i + 1
  }
  if neg {
    Some(-acc)
  } else {
    Some(acc)
  }
}

///|
/// 数字输入框的账：范围、步长、当前值。
struct SpinState {
  mut theme : UiTheme
  mut value : Int32
  min : Int32
  max : Int32
  step : Int32
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 数字输入框（输入框 + 右侧上下两颗小箭头）。
pub struct UiSpinbox[B] {
  backend : B
  root : @moonui.Widget[B]
  input : UiTextInput[B]
  stepper : @moonui.Widget[B]
  state : SpinState
}

///|
/// 步进器的宽度：22 是"手指点得中"的下限，再窄两颗箭头就挤在一起。
fn ui_spin_stepper_width() -> Double {
  22.0
}

///|
/// 步进器与输入框之间的缝：2px。再宽就看着像两只不相干的控件，贴死又分不清
/// "框到哪儿结束"——2px 正好够一条视觉分界。
fn ui_spin_gap() -> Double {
  2.0
}

///|
/// 步进器的两半：上半是加、下半是减。返回 -1/0/1 与"指针在两半上"的判定。
fn ui_spin_half(h : Double, y : Double) -> Int32 {
  if y >= 0.0 && y < h / 2.0 {
    1
  } else if y >= h / 2.0 && y < h {
    -1
  } else {
    0
  }
}

///|
/// 画步进器：一颗朝上的三角 + 一颗朝下的三角，悬停哪半哪半亮。
fn ui_paint_stepper(
  st : SpinState,
  hover : Int32,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let t = st.theme
  let cx = w / 2.0
  let (up, down) = (h * 0.28, h * 0.72)
  let half = 4.0
  let up_color = if hover == 1 { t.text } else { t.text_muted }
  let down_color = if hover == -1 { t.text } else { t.text_muted }
  // 三角形用多边形填充（`fill_polygon` 首尾相连），比三条 `Line` 拼一个
  // 空心三角更像"箭头"——后者在小尺寸下中间会透出底色
  dl.fill_polygon(
    [
      (cx - half, up + half * 0.7),
      (cx + half, up + half * 0.7),
      (cx, up - half * 0.7),
    ],
    rgb=up_color,
  )
  dl.fill_polygon(
    [
      (cx - half, down - half * 0.7),
      (cx + half, down - half * 0.7),
      (cx, down + half * 0.7),
    ],
    rgb=down_color,
  )
}

///|
/// 造一个数字输入框。范围与步长建时定死（与原生 `Widget::spinbox` 同一条
/// 口径：范围是构造参数，事后没有改范围的口子）。
pub fn[B : @moonui.Backend] UiSpinbox::UiSpinbox(
  backend : B,
  value~ : Int32 = 0,
  min~ : Int32 = 0,
  max~ : Int32 = 100,
  step~ : Int32 = 1,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
  width~ : Double = 120.0,
) -> UiSpinbox[B] raise @moonui.UiError {
  let lo = if min > max { max } else { min }
  let hi = if min > max { min } else { max }
  let clamp = if value < lo { lo } else if value > hi { hi } else { value }
  let metrics = theme.metrics(size)
  let state = SpinState::{
    theme,
    value: clamp,
    min: lo,
    max: hi,
    step: if step == 0 {
      1
    } else if step < 0 {
      -step
    } else {
      step
    },
    handler: None,
  }
  let input = UiTextInput::UiTextInput(
    backend,
    text=clamp.to_string(),
    theme~,
    size~,
    width=width - ui_spin_stepper_width() - ui_spin_gap(),
  )
  // 打字：能解析成整数就跟着改值（超出范围先记着原文，由失焦/步进夹回来）
  input.on_input(fn(t) raise @moonui.UiError {
    match ui_parse_int(t) {
      Some(v) =>
        if v >= state.min && v <= state.max && v != state.value {
          state.value = v
          match state.handler {
            Some(f) => f(v)
            None => ()
          }
        }
      None => ()
    }
  })
  // 失焦时把原文重写成"当下的值"：打成 "-" 或 "1200" 这种半成品，离开时
  // 就只剩一个合法的数（不这么做，框里会留一段与值不符的文本）
  let _ = input
    .field()
    .on(
      fn(e) {
        match e {
          @moonui.Blur(_) => true
          _ => false
        }
      },
      fn(_) raise @moonui.UiError {
        let shown = state.value.to_string()
        if input.text() != shown {
          input.set_text(shown)
        }
      },
    )
  let hover : Array[Int32] = [-1]
  let stepper = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(ui_spin_stepper_width(), metrics.height),
    fn(dl, env) { ui_paint_stepper(state, hover[0], dl, env) },
    focusable=false,
  )
  // 步进器的指针账：挪进哪半、按哪半。按下即生效（原生的上下小箭头就是
  // 这个手感：按住不放会连续走，这里只做到"按一下走一步"）
  let _ = stepper.on(
    fn(e) {
      match e {
        @moonui.MouseMove(_, _) => true
        @moonui.MouseLeave(_) => true
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseMove(_, p) => {
          let y = p.y - stepper.frame().origin.y
          let half = ui_spin_half(metrics.height, y)
          if half != hover[0] {
            hover[0] = half
            stepper.repaint()
          }
        }
        @moonui.MouseLeave(_) =>
          if hover[0] != -1 {
            hover[0] = -1
            stepper.repaint()
          }
        @moonui.MouseDown(_, _, p, _) => {
          let y = p.y - stepper.frame().origin.y
          ui_spin_step(stepper, input, state, ui_spin_half(metrics.height, y))
        }
        _ => ()
      }
    },
  )
  // 滚轮：落在输入框或步进器上都走同一档步进。y 正向是向上滚（Core 把
  // 各平台的方向归一化成逻辑像素），对应"加一步"；负向减一步。
  fn ui_spin_scroll_dir(dy : Double) -> Int32 {
    if dy > 0.0 {
      1
    } else if dy < 0.0 {
      -1
    } else {
      0
    }
  }
  for target in [input.field(), stepper] {
    let _ = target.on(
      fn(e) {
        match e {
          @moonui.Scroll(_, _) => true
          _ => false
        }
      },
      fn(e) raise @moonui.UiError {
        match e {
          @moonui.Scroll(_, d) =>
            ui_spin_step(stepper, input, state, ui_spin_scroll_dir(d.y))
          _ => ()
        }
      },
    )
  }
  let root = @moonui.Widget::row(backend, ui_spin_gap(), [input.view(), stepper])
  { backend, root, input, stepper, state, }
}

///|
/// 走一步：夹到范围内、同步文本、回调（值没变就不回调）。
fn[B : @moonui.Backend] ui_spin_step(
  stepper : @moonui.Widget[B],
  input : UiTextInput[B],
  st : SpinState,
  dir : Int32,
) -> Unit raise @moonui.UiError {
  if dir == 0 {
    return
  }
  let next = st.value + st.step * dir
  let clamped = if next < st.min {
    st.min
  } else if next > st.max {
    st.max
  } else {
    next
  }
  let _ = stepper
  if clamped == st.value {
    return
  }
  st.value = clamped
  input.set_text(clamped.to_string())
  match st.handler {
    Some(f) => f(clamped)
    None => ()
  }
}

///|
pub fn[B] UiSpinbox::view(self : UiSpinbox[B]) -> @moonui.Widget[B] {
  self.root
}

///|
/// 里面那只文本输入框（要单独设占位、接回车这类事从这里下去）。
pub fn[B] UiSpinbox::input(self : UiSpinbox[B]) -> UiTextInput[B] {
  self.input
}

///|
/// 右侧步进器本身：要单独订阅事件或改样式时从这里拿。
pub fn[B] UiSpinbox::stepper(self : UiSpinbox[B]) -> @moonui.Widget[B] {
  self.stepper
}

///|
pub fn[B] UiSpinbox::value(self : UiSpinbox[B]) -> Int32 {
  self.state.value
}

///|
pub fn[B] UiSpinbox::on_change(
  self : UiSpinbox[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 程序设值：夹到范围、同步文本，不触发 `on_change`。
pub fn[B : @moonui.Backend] UiSpinbox::set_value(
  self : UiSpinbox[B],
  value : Int32,
) -> Unit raise @moonui.UiError {
  let v = if value < self.state.min {
    self.state.min
  } else if value > self.state.max {
    self.state.max
  } else {
    value
  }
  if v == self.state.value {
    return
  }
  self.state.value = v
  self.input.set_text(v.to_string())
}

///|
/// 换整套令牌：三层壳都要刷（外层边色、内层面色、原生框内的文字色），
/// 档位记在 state 里，调用方只交一份主题。
///
/// 原生编辑框内部那套系统配色不在这条通道里（`T352` 的已知边界，要接
/// `WM_CTLCOLOREDIT`）；这里换的是自绘的外两层与 Core 下发的前景色。
pub fn[B] UiTextInput::set_theme(
  self : UiTextInput[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.inner.set_style(
    Some(
      @moonui.style(
        background=Some(ui_color(theme.surface)),
        radius=Some(if theme.radius > 2.0 { theme.radius - 1.0 } else { 0.0 }),
        padding=Some(@moonui.EdgeInsets::symmetric(4.0, 10.0)),
        foreground=Some(ui_color(theme.text)),
      ),
    ),
  )
  ui_input_paint_ring(self.shell, self.state)
}

///|
/// 数字框换主题：输入框那三层照刷，步进器那两颗箭头跟着换色。
pub fn[B : @moonui.Backend] UiSpinbox::set_theme(
  self : UiSpinbox[B],
  theme : UiTheme,
) -> Unit raise @moonui.UiError {
  self.state.theme = theme
  self.input.set_theme(theme)
  self.stepper.repaint()
}
