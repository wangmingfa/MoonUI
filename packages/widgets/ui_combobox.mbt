///|
/// `UiComboBox`——自绘下拉选择（`T359`）。
///
/// 与 `Widget::combobox`（系统原生封装：Win `CBS_DROPDOWNLIST` / mac
/// `NSComboBox` / GTK `GtkDropDown`）的分工：原生那只的下拉由 OS 弹、配色与
/// 命中都不在框架手里；自绘这只要的是"下拉列表也走同一套 `UiTheme` 令牌"——
/// 列表底色、选中高亮、文字色都得能跟着主题换。前置是 Core 的浮层抽象
/// （`T359` / `popup.mbt`）：一只 owned 无边框窗装一棵自绘选项树，点外部 /
/// Esc 关窗由 `App` 的浮层栈统一管。
///
/// 触发器与列表都是自绘面（`Widget::custom` + `DrawList`）。点触发器 →
/// `App::open_popup` 建浮层 → 浮层内容是一块自绘列表 → 点选项写回选中下标、
/// 关浮层、回调 `on_change`。列表的"点外部关闭"由 Core 守卫做：点回触发器
/// 那一下 target 在浮层树外，Core 在 MouseDown 关浮层（不吞事件）。因此触发器
/// 必须自己认出"关我的就是我这次点击"（`Popup::close_cause` 与自己的 target
/// 比对），把随后的 MouseUp 吃掉——不吞就会立刻重开，看起来"点不掉"。
///
/// 构造时要交 `app` 与 `owner`（触发器所在的那只窗口）：浮层必须登记进 App
/// 的栈，owner 决定 owned 关系。这是自绘下拉与其余纯叶子控件的区别——它需要
/// 应用层的两个对象，不能只拿 `backend` 就建出来。

///|
/// 下拉的可变账：触发器与列表两面共用。账里不存 `Popup` 本身——浮层的所有权
/// 在 `App` 的栈里，控件只记一个"开着"的布尔，由浮层的关闭回调复位。
struct ComboState {
  mut theme : UiTheme
  mut metrics : UiMetrics
  options : Array[String]
  mut selected : Int32
  mut opened : Bool
  /// 列表悬停的下标，-1 = 无。
  mut hover : Int32
  /// 触发器按下锚。
  mut press : Bool
  /// 这一次抬起不要开浮层。只有一种来源：浮层开着时用户点了触发器，Core 在
  /// MouseDown 就把浮层关了、MouseUp 又落到触发器上——不吞掉这次抬起就会立刻
  /// 重开，用户看到的是"点不掉"。由关闭回调按 `Popup::close_cause` 置位，
  /// 被那次抬起消费；`MouseLeave` 也清（按下后拖走不回来）。
  mut suppress_open : Bool
  it : UiInteract
  mut handler : ((Int32) -> Unit raise @moonui.UiError)?
}

///|
/// 自绘下拉。`UiComboBox(app, owner, options)` 之后用 `view()` 拿触发器挂进布局。
pub struct UiComboBox[B] {
  app : @moonui.App[B]
  owner : @moonui.Window[B]
  backend : B
  trigger : @moonui.Widget[B]
  state : ComboState
}

///|
/// 触发器尺寸：最宽那项 + 下拉箭头 + 两侧内缩，高度取档高。
fn[B : @moonui.Backend] ui_combo_size(
  backend : B,
  options : Array[String],
  metrics : UiMetrics,
) -> @moonui.LogicalSize {
  let pad = metrics.pad_x * 2.0 + 18.0 // 18 = 箭头宽 + 与文字的间隔
  let mut mw = 60.0
  for o in options {
    let (w, _) = ui_measure(backend, o, metrics.font, false)
    if w + pad > mw {
      mw = w + pad
    }
  }
  @moonui.LogicalSize(mw, metrics.height)
}

///|
/// 画触发器：圆角面 + 选中项文字 + 右侧向下的小三角 + 焦点环。
fn ui_paint_combo_trigger(
  st : ComboState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let it = st.it
  let th = st.theme
  let fill = if it.pressed {
    th.surface_active
  } else if it.hovered {
    th.surface_hover
  } else {
    th.surface
  }
  let border = if it.focused { th.accent } else { th.border }
  ui_paint_fill(dl, 0.0, 0.0, w, h, st.metrics.radius, fill)
  ui_paint_stroke(
    dl,
    0.5,
    0.5,
    w - 1.0,
    h - 1.0,
    st.metrics.radius,
    0.5,
    1.0,
    border,
  )
  let label = if st.selected >= 0 && st.selected < st.options.length() {
    st.options[st.selected]
  } else {
    ""
  }
  dl.text(
    label,
    st.metrics.pad_x,
    (h - st.metrics.font) / 2.0,
    size=st.metrics.font,
    rgb=th.text,
  )
  let ax = w - 14.0
  let ay = h / 2.0 - 2.0
  dl.fill_polygon(
    [(ax, ay), (ax + 8.0, ay), (ax + 4.0, ay + 5.0)],
    rgb=th.text_muted,
  )
  if it.focused {
    ui_paint_focus_ring(dl, 0.0, 0.0, w, h, st.metrics.radius, th.focus_ring)
  }
}

///|
/// 命中行：局部 y 落在第几行，越界回 -1。
fn ui_combo_hit(st : ComboState, local_y : Double) -> Int32 {
  let n = st.options.length()
  if n == 0 || local_y < 0.0 {
    return -1
  }
  let rh = st.metrics.height
  let i = (local_y / rh).to_int()
  if i >= n {
    -1
  } else {
    i
  }
}

///|
/// 画列表：圆角底 + 每行文字，选中/悬停各一层淡底。
fn ui_paint_combo_list(
  st : ComboState,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let w = env.width()
  let h = env.height()
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let th = st.theme
  ui_paint_fill(dl, 0.0, 0.0, w, h, st.metrics.radius, th.surface)
  ui_paint_stroke(
    dl,
    0.5,
    0.5,
    w - 1.0,
    h - 1.0,
    st.metrics.radius,
    0.5,
    1.0,
    th.border,
  )
  let rh = st.metrics.height
  for i = 0; i < st.options.length(); i = i + 1 {
    let y = rh * i.to_double()
    let picked = i == st.selected
    let hovered = i == st.hover
    if picked || hovered {
      let bg = if picked {
        ui_mix(th.accent, th.surface, 0.82)
      } else {
        th.surface_hover
      }
      dl.fill_rect(1.0, y, w - 2.0, rh, rgb=bg)
    }
    dl.text(
      st.options[i],
      st.metrics.pad_x,
      y + (rh - st.metrics.font) / 2.0,
      size=st.metrics.font,
      bold=picked,
      rgb=if picked { th.accent } else { th.text },
    )
  }
}

///|
/// 造一个自绘下拉。`options` 不能为空（空列表没有可选值，直接报错——与
/// `UiTabs` 同一条纪律）。`owner` 必须是 `app` 里登记过的活窗。
pub fn[B : @moonui.Backend] UiComboBox::UiComboBox(
  app : @moonui.App[B],
  owner : @moonui.Window[B],
  options : Array[String],
  selected~ : Int32 = 0,
  theme~ : UiTheme = UiTheme::light(),
  size~ : UiSize = UiMedium,
) -> UiComboBox[B] raise @moonui.UiError {
  if options.length() == 0 {
    raise @moonui.OperationFailed("下拉的选项不能为空")
  }
  let backend = app.backend()
  let metrics = theme.metrics(size)
  let dim = ui_combo_size(backend, options, metrics)
  let init = if selected < 0 {
    0
  } else if selected >= options.length() {
    options.length() - 1
  } else {
    selected
  }
  let state : ComboState = {
    theme,
    metrics,
    options,
    selected: init,
    opened: false,
    hover: -1,
    press: false,
    suppress_open: false,
    it: UiInteract::new(),
    handler: None,
  }
  let trigger = @moonui.Widget::custom(
    backend,
    dim,
    fn(dl, env) { ui_paint_combo_trigger(state, dl, env) },
    focusable=true,
  )
  ui_combo_watch(app, owner, backend, trigger, state)
  { app, owner, backend, trigger, state, }
}

///|
/// 开浮层：建 popup（走 Backend::create_popup_window 的 owned 通道），装一棵
/// 自绘选项树，摆到触发器下沿。列表的点击回调写回选中并关浮层。
fn[B : @moonui.Backend] ui_combo_open(
  app : @moonui.App[B],
  owner : @moonui.Window[B],
  backend : B,
  trigger : @moonui.Widget[B],
  st : ComboState,
) -> Unit raise @moonui.UiError {
  let n = st.options.length()
  let row_h = st.metrics.height
  let list_h = row_h * n.to_double()
  let list_w = trigger.frame().size.width
  // 先把焦点落到触发器：`open_popup` 会把它快照成归还目标，关窗时 Core 自动
  // 派回 `Focus`。这步也让"点开就聚焦"在皮肤账上成立（原生那边点击本来就会
  // 让这块面成为 first responder，Core 只是把账对齐）。
  app.set_focus(Some(trigger.target()))
  let popup = app.open_popup(owner, @moonui.LogicalSize(list_w, list_h))
  st.opened = true
  // Core 关掉浮层（Esc / 点外部 / 控件自己关）时同步两份账：本控件的
  // `opened` 复位（不复位就再也开不出来），并识别"是不是我自己那一击关的"。
  // 焦点归还不用在这里做——`close_popup` 最后一步按 `return_focus` 自动派回。
  popup.on_close(fn() raise @moonui.UiError {
    st.opened = false
    // 关它的是触发器自己那一下点击 → 吃掉随后落到触发器上的抬起，才是真
    // toggle；否则 Core 在 MouseDown 关、MouseUp 又开，看起来"关不掉"。
    let by_trigger = match popup.close_cause() {
      Some(t) => t == trigger.target()
      None => false
    }
    if by_trigger {
      st.suppress_open = true
    }
    trigger.repaint()
  })
  // 摆位交给 `Popup::anchor_below`：它摆一次并**记下触发器**，之后 owner
  // 被拖动 / 改尺寸 / 换屏改 DPI 时 Core 按触发器的当下 frame 重摆
  // （`T359` ②）。原先在这里手算 `owner.position() + trigger.frame()` 只摆
  // 一次，窗户一挪下拉就留在原地。
  popup.anchor_below(trigger)
  let list = @moonui.Widget::custom(
    backend,
    @moonui.LogicalSize(list_w, list_h),
    fn(dl, env) { ui_paint_combo_list(st, dl, env) },
    focusable=false,
  )
  ui_combo_watch_list(app, popup, list, st)
  popup.window().set_content(list)
  popup.window().show()
  trigger.repaint()
}

///|
/// 触发器：悬停/按下/焦点三态交给套件统一的那条订阅（`ui_watch_state`，与
/// `UiTabs` 同构）；本控件只加自己的账——按下锚、抬起开浮层、键盘开。
fn[B : @moonui.Backend] ui_combo_watch(
  app : @moonui.App[B],
  owner : @moonui.Window[B],
  backend : B,
  w : @moonui.Widget[B],
  st : ComboState,
) -> Unit raise @moonui.UiError {
  ui_watch_state(w, st.it, app=Some(app))
  let _ = w.on(
    fn(e) {
      match e {
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        @moonui.MouseLeave(_) => true
        @moonui.KeyDown(_, kp) =>
          kp.key == "Down" || kp.key == "Enter" || kp.key == " "
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseLeave(_) => {
          // 按下后拖出去不回来：锚与"别开"都清掉，否则下次点击会被吞。
          st.press = false
          st.suppress_open = false
        }
        @moonui.MouseDown(_, _, _, _) => st.press = true
        @moonui.MouseUp(_, _, _, _) =>
          if st.press {
            st.press = false
            if st.suppress_open {
              st.suppress_open = false
            } else if !st.opened {
              ui_combo_open(app, owner, backend, w, st)
            }
          }
        @moonui.KeyDown(_, kp) =>
          if !st.opened &&
            (kp.key == "Down" || kp.key == "Enter" || kp.key == " ") {
            ui_combo_open(app, owner, backend, w, st)
          }
        _ => ()
      }
    },
  )
}

///|
/// 列表：MouseMove 翻悬停行、MouseUp 提交。选中后关浮层、回调。
fn[B : @moonui.Backend] ui_combo_watch_list(
  app : @moonui.App[B],
  popup : @moonui.Popup[B],
  list : @moonui.Widget[B],
  st : ComboState,
) -> Unit raise @moonui.UiError {
  let _ = list.on(
    fn(e) {
      match e {
        @moonui.MouseMove(_, _) => true
        @moonui.MouseDown(_, @moonui.Left, _, _) => true
        @moonui.MouseUp(_, @moonui.Left, _, _) => true
        _ => false
      }
    },
    fn(e) raise @moonui.UiError {
      match e {
        @moonui.MouseMove(_, p) => {
          let i = ui_combo_hit(st, p.y - list.frame().origin.y)
          if i != st.hover {
            st.hover = i
            list.repaint()
          }
        }
        @moonui.MouseUp(_, _, p, _) => {
          let i = ui_combo_hit(st, p.y - list.frame().origin.y)
          if i >= 0 {
            st.selected = i
            match st.handler {
              Some(f) => f(i)
              None => ()
            }
            // `opened` 的复位交给浮层的关闭回调（与 Esc / 点外部同一条路）。
            app.close_popup(popup)
          }
        }
        _ => ()
      }
    },
  )
}

///|
/// 触发器控件（挂进布局的就是它）。
pub fn[B] UiComboBox::view(self : UiComboBox[B]) -> @moonui.Widget[B] {
  self.trigger
}

///|
/// 当前选中的下标。
pub fn[B] UiComboBox::selected(self : UiComboBox[B]) -> Int32 {
  self.state.selected
}

///|
/// 选中变化回调。
pub fn[B] UiComboBox::on_change(
  self : UiComboBox[B],
  f : (Int32) -> Unit raise @moonui.UiError,
) -> Unit {
  self.state.handler = Some(f)
}

///|
/// 浮层是否开着。
pub fn[B] UiComboBox::is_open(self : UiComboBox[B]) -> Bool {
  self.state.opened
}

///|
/// 程序设值：夹到合法下标，重画，不触发 `on_change`。
pub fn[B : @moonui.Backend] UiComboBox::set_selected(
  self : UiComboBox[B],
  index : Int32,
) -> Unit raise @moonui.UiError {
  let n = self.state.options.length()
  let i = if index < 0 { 0 } else if index >= n { n - 1 } else { index }
  if self.state.selected != i {
    self.state.selected = i
    self.trigger.repaint()
  }
}

///|
/// 换主题：令牌折进账、按下标重算触发器尺寸（字宽随字号变）。
pub fn[B : @moonui.Backend] UiComboBox::set_theme(
  self : UiComboBox[B],
  theme : UiTheme,
  size~ : UiSize = UiMedium,
) -> Unit raise @moonui.UiError {
  let metrics = theme.metrics(size)
  self.state.theme = theme
  self.state.metrics = metrics
  let dim = ui_combo_size(self.backend, self.state.options, metrics)
  self.trigger.set_custom_size(dim)
  self.trigger.repaint()
}
