///|
/// 自绘后端的鼠标翻译（§52.5 分期③）：C 监听报上来的 target 永远是窗口
/// （自绘控件没有原生对象，hitTest 只能落回 contentView），这一层按记账
/// bounds 做命中测试、改写 target 再交 Core——原生后端靠 C 的 owner 反查
/// 认控件，自绘后端的"认控件"只能发生在记账这一侧。
///
/// 命中语义与 Core 的 `Widget::hit_test` 同一条：后遍历到的赢（绘制顺序
/// 里靠上的盖住靠下的）。左键的 Click 在这层合成：按下与抬起落在同一只
/// 记账控件上才算一次点击（原生后端的 Click 来自控件回调，自绘没有回调）。

///|
/// 装自绘的鼠标闭包。必须在 inner.create_window 之后调——原生后端的第一条
/// 窗口会装它自己的闭包，这里顶掉它（进程槽位一份，adapter.h 的契约是
/// "重复调用只换回调"）。被顶掉的还有左键那两个编码的"不翻译"——这正是
/// 要的：原生后端不消费它们，自绘后端全靠它们。
fn CanvasBackend::install_mouse(self : CanvasBackend) -> Unit {
  if self.mouse_installed {
    return
  }
  try {
    @native-common.native_on_mouse(fn() { self.on_mouse() })
    self.mouse_installed = true
  } catch {
    _ => () // 装不上就静默缺席（与 inner 的鼠标监听同形，不挡开窗）
  }
}

///|
/// C 回包：kind*8+button（adapter.h 鼠标段）→ Core 事件。这函数被 C 在
/// 监听回调里调进来，raise 跨 C 帧未定义（worker 同一条纪律）——正文全
/// 部 try 住，任何读账失败都整条丢（§12）。
fn CanvasBackend::on_mouse(self : CanvasBackend) -> Unit {
  let kb = @native-common.native_mouse_kind_button()
  let ptr = @native-common.native_mouse_target()
  let (px, py) = @native-common.native_mouse_pos()
  // 滚动增量（逻辑像素，kind 4 才有值，其余 (0,0)）：C 已换算完，原样透传
  let (dx, dy) = @native-common.native_mouse_delta()
  self.translate_mouse(kb / 8, kb % 8, ptr, px, py, dx~, dy~) catch {
    _ => ()
  }
}

///|
/// 参数化本体：测试直接注参（不靠真鼠标），C 读取壳在上面那层。pub 是
/// 测试口——黑盒测试在包外，看得见的只有公共面。
pub fn CanvasBackend::translate_mouse(
  self : CanvasBackend,
  kind : Int32,
  button : Int32,
  ptr : Int64,
  px : Int32,
  py : Int32,
  dx~ : Int32 = 0,
  dy~ : Int32 = 0,
) -> Unit raise @moonui.UiError {
  let mut wi : Int32 = -1
  for i = 0; i < self.windows.length(); i = i + 1 {
    if @native-common.NativeBackend::window_ptr(
        self.inner,
        self.windows[i].handle,
      ) ==
      ptr {
      wi = i
      break
    }
  }
  if wi < 0 {
    return
  }
  let window = self.windows[wi].handle
  // 物理 → 逻辑（§30）：C 报的是客户区左上原点、y 向下的物理像素
  let scale = @moonui.Backend::window_scale(self.inner, window)
  let point = scale.to_logical_point(@moonui.PhysicalPoint(px, py))
  // 命中：绘制序里最后一个含住该点的可见记账（与 Core 的 hit_test 同一条
  // "后画的盖住先画的"）。空白处命不中，target 落回窗口——Core 拿"目标
  // 是窗口"当 unhover 信号（悬停通道）。
  let hit = self.hit_test(wi, point)
  let target = match hit {
    Some(h) => h
    None => window
  }
  if kind == 2 || kind == 5 {
    // 移动/离开：target 照实报，Enter/Leave 由 Core 的 hover_track 合成。
    // 离开窗口是 kind 5（T98① 从 kind 3 挪来——kind 3 让给双击，adapter.h
    // 词表，Windows 的 WM_*BUTTONDBLCLK 一直报 kind 3）。悬停记账顺手更新
    // ——按钮三态的画账走这里（Core 的 hover 样式另有一条通道，两条不冲突：
    // 显式给过 bg 的控件吃 Core 的，没给的吃三态）。
    let fresh : @moonui.NativeHandle? = if hit is Some(_) {
      Some(target)
    } else {
      None
    }
    if fresh != self.hover {
      self.hover = fresh
      self.mark_dirty()
    }
    self.queue.push(@moonui.MouseMove(@moonui.EventTarget::of(target), point))
    // 拖住滑条：移动报完再落值（Change 跟在 Move 后，同一次拖动一条条报）
    if button == 0 && self.press_is_slider() {
      match hit {
        Some(h) =>
          match self.slider_seek(h, point) {
            Some(changed) =>
              if changed {
                self.queue.push(@moonui.Change(@moonui.EventTarget::of(h)))
              }
            None => ()
          }
        None => ()
      }
    }
    return
  }
  if kind == 0 && button == 0 {
    // 左键按下：记账备 Click 合成（抬起还在同一只控件上才算点），按下
    // 态的画账同时翻
    self.press = Some((target, wi))
    self.mark_dirty()
    self.queue.push(
      @moonui.MouseDown(@moonui.EventTarget::of(target), @moonui.Left, point),
    )
    // 点在滑条上：按下事件报完就落值（原生 NSSlider 的 action 语义）
    match hit {
      Some(h) =>
        match self.slider_seek(h, point) {
          Some(changed) =>
            if changed {
              self.queue.push(@moonui.Change(@moonui.EventTarget::of(h)))
            }
          None => ()
        }
      None => ()
    }
    return
  }
  if kind == 1 && button == 0 {
    self.queue.push(
      @moonui.MouseUp(@moonui.EventTarget::of(target), @moonui.Left, point),
    )
    // Click 合成：按下与抬起命中同一只**记账控件**（窗口不算——点空白
    // 不是任何人的 Click，与原生空白处不产事件同一条语义）
    match self.press {
      Some((pressed, pressed_wi)) => {
        self.press = None
        self.mark_dirty()
        if pressed_wi == wi {
          match self.hit_test(wi, point) {
            Some(h) => {
              // 滑条不产 Click（原生 NSSlider 没有 clicked action，语义是
              // Change——seek 那段已经报过了）
              let pressed_is_slider : Bool = {
                let rec : CwRec? = Some(self.rec_of(pressed)) catch {
                  _ => None
                }
                match rec {
                  Some(r) => r.kind is @moonui.Slider
                  None => false
                }
              }
              if h == pressed && h != window && !pressed_is_slider {
                self.queue.push(
                  @moonui.Click(@moonui.EventTarget::of(h), @moonui.Left),
                )
              }
            }
            None => ()
          }
        }
      }
      None => ()
    }
    return
  }
  if kind == 0 && button == 1 {
    // 右键按下：与原生后端同一条右键路由，target 改写成命中控件
    self.queue.push(
      @moonui.MouseDown(@moonui.EventTarget::of(target), @moonui.Right, point),
    )
    return
  }
  if kind == 0 && button == 2 {
    // 中键按下（T98①）：与右键同一条路由，target 改写成命中控件
    self.queue.push(
      @moonui.MouseDown(@moonui.EventTarget::of(target), @moonui.Middle, point),
    )
    return
  }
  if kind == 1 && button == 2 {
    // 中键抬起（T98①）
    self.queue.push(
      @moonui.MouseUp(@moonui.EventTarget::of(target), @moonui.Middle, point),
    )
    return
  }
  if kind == 3 {
    // 双击（T98①）：第二次按下只产 kind 3（C 侧 clickCount>=2 不再产 kind 0，
    // adapter.h 词表，与 Windows 的 WM_LBUTTONDBLCLK 取代第二颗 DOWN 同一条）。
    // 事件不带点（Event::DoubleClick 只有 target），target 改写成命中控件。
    self.queue.push(@moonui.DoubleClick(@moonui.EventTarget::of(target)))
    return
  }
  if kind == 4 {
    // 滚轮（T98①）：dx/dy 是 C 已换算完的**逻辑像素**增量（adapter.h 口径，
    // MoonBit 不许再除一次），原样进 Event::Scroll 的 LogicalPoint。target
    // 改写成命中控件（空白落回窗口，Core 据此丢弃——视口在 Core 里还不是
    // 有原生对象的东西，落在控件间空隙的滚轮没有收件人，同一格欠账）。
    self.queue.push(
      @moonui.Scroll(
        @moonui.EventTarget::of(target),
        @moonui.LogicalPoint(dx.to_double(), dy.to_double()),
      ),
    )
    return
  }
}

///|
/// 绘制序命中（后画的赢）。只看可见记账；enabled 不筛——"禁用控件可点
/// 与否"是 Core 的事件路由账，不是绘制账（原生半的禁用也是 C 不吃事件）。
fn CanvasBackend::hit_test(
  self : CanvasBackend,
  wi : Int32,
  point : @moonui.LogicalPoint,
) -> @moonui.NativeHandle? {
  let order = self.windows[wi].order
  let mut found : @moonui.NativeHandle? = None
  for i = 0; i < order.length(); i = i + 1 {
    let h = order[i]
    let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
    match rec {
      Some(r) => {
        // 滚动文档区 → 窗口绝对坐标（T98② 滚动偏移）：与 paint_rec 同一条平移，
        // 否则点滚动内容会按文档坐标命中（点偏到侧栏/空白）。
        let off = self.scroll_offset(h)
        let abs = @moonui.LogicalRect(
          @moonui.LogicalPoint(
            r.bounds.origin.x + off.x,
            r.bounds.origin.y + off.y,
          ),
          r.bounds.size,
        )
        if r.visible && abs.contains(point) {
          found = Some(h)
        }
      }
      None => ()
    }
  }
  found
}

///|
/// 按住的那只是不是滑条（拖拽语义的判定）。
fn CanvasBackend::press_is_slider(self : CanvasBackend) -> Bool {
  match self.press {
    Some((h, _)) => {
      let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
      match rec {
        Some(r) => r.kind is @moonui.Slider
        None => false
      }
    }
    None => false
  }
}

///|
/// 滑条落点 → 值：x 轴比例换回值域，改了就记账标脏并报"值变了"。
/// 非滑条句柄返回 None（不产 Change）。
fn CanvasBackend::slider_seek(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  point : @moonui.LogicalPoint,
) -> Bool? raise @moonui.UiError {
  let rec = self.rec_of(h)
  if !(rec.kind is @moonui.Slider) {
    return None
  }
  let r = rec.bounds
  if r.size.width <= 0.0 {
    return None
  }
  let frac = ((point.x - r.origin.x) / r.size.width).clamp(min=0.0, max=1.0)
  let span = rec.max - rec.min
  let v = rec.min +
    (frac * span.to_double()).floor().to_int().clamp(min=0, max=span)
  let changed = v != rec.value
  rec.value = v
  if changed {
    self.mark_dirty()
  }
  Some(changed)
}
