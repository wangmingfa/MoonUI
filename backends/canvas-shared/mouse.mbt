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
  // 拆包走 `@native-abi`（`T144`）：`kind * 8 + button` 这一条编码只有一份拆法，
  // 负数 kb 的非负取模也在那一份里。本包此前自己算那两位，那正是判定表分叉的
  // 起点。`scripts/detlint.sh` 的 `kb-unrouted` 规则现在钉住这件事：**凡碰
  // `native_mouse_kind_button` 的文件必须同时引用 `@native-abi`**——所以下面那
  // 行不是可选的，删掉它判据就红。
  let k = @native-abi.split_kind_button(kb)
  self.translate_mouse(k.kind, k.button, ptr, px, py, dx~, dy~) catch {
    _ => ()
  }
}

///|
/// 参数化本体：测试直接注参（不靠真鼠标），C 读取壳在上面那层。pub 是
/// 测试口——黑盒测试在包外，看得见的只有公共面。
///
/// 修饰键如实缺席（`T102` 第二十三刀）：画布 ABI 的鼠标通道（`on_mouse` 的
/// 整数参数表）没有修饰键这一格，这里全部按 `Mods::none()` 报——宁可如实
/// 报"没有修饰键"，不猜一个。哪天真接（画布后端上的 DataGrid 多选）改的
/// 是这条参数表，不是这里的构造。
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
    // 指针形状（`T380`）：随命中换——可编辑给竖线、可点控件给手型、空白与
    // 离开窗口回箭头。形状没变就不碰系统（NSCursor 是进程级单例）。
    let shape = if kind == 5 { 0 } else { self.cursor_shape_of(hit) }
    if shape != self.cursor_shape {
      self.cursor_shape = shape
      @native-common.native_set_cursor(shape)
    }
    self.post(@moonui.MouseMove(@moonui.EventTarget::of(target), point))
    // 拖选（`T388`）：按住左键在可编辑记账上移动——锚点钉在按下处（`sel`），
    // 只带活动端 `caret` 跟着鼠标走。用记住的那只记账（不是当前命中）：拖出
    // 控件边界时命中会变窗口，但拖选还得继续、光标夹在首尾。窗下标对不上
    // （跨窗拖动）就不动。
    match self.drag {
      Some((dh, dwi)) =>
        if dwi == wi {
          self.caret_seek(wi, dh, point, anchor=false)
        }
      None => ()
    }
    // 拖住滑条：移动报完再落值（Change 跟在 Move 后，同一次拖动一条条报）
    if button == 0 && self.press_is_slider() {
      match hit {
        Some(h) =>
          match self.slider_seek(h, point) {
            Some(changed) =>
              if changed {
                self.post(@moonui.Change(@moonui.EventTarget::of(h)))
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
    self.post(
      @moonui.MouseDown(
        @moonui.EventTarget::of(target),
        @moonui.Left,
        point,
        @moonui.Mods::none(),
      ),
    )
    // 点在可聚焦记账上：取焦（`T369`，与原生"点击把 first responder 交给
    // 控件"同一条）。点其它地方（空白 / 非 focusable）：焦点让回窗口——
    // 原生点别处同样结束编辑，光标跟着消失（`T379` 真窗口反馈）。
    match hit {
      Some(h) =>
        if self.focusable_of(h) {
          self.move_focus(wi, Some(h))
        } else {
          self.move_focus(wi, None)
        }
      None => self.move_focus(wi, None)
    }
    // 点击定位光标（`T387` 文本编辑第二刀）：点进可编辑记账把光标放到点击的
    // 字符上——`move_focus` 进入时只落末尾（`T374` 没做的那半），这里按落点
    // 重定，点哪光标落哪。点空白/非可编辑不动。
    match hit {
      Some(h) => {
        self.caret_seek(wi, h, point)
        // 拖选（`T388`）：按下落在可编辑记账上就起拖——锚点已落在按下处，
        // 移动时只带活动端；左键抬起或焦点转移就清掉（`move_focus`）。
        let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
        match rec {
          Some(r) => if r.editable() && r.enabled { self.drag = Some((h, wi)) }
          None => ()
        }
      }
      None => ()
    }
    // 点在滑条上：按下事件报完就落值（原生 NSSlider 的 action 语义）
    match hit {
      Some(h) =>
        match self.slider_seek(h, point) {
          Some(changed) =>
            if changed {
              self.post(@moonui.Change(@moonui.EventTarget::of(h)))
            }
          None => ()
        }
      None => ()
    }
    return
  }
  if kind == 1 && button == 0 {
    self.post(
      @moonui.MouseUp(
        @moonui.EventTarget::of(target),
        @moonui.Left,
        point,
        @moonui.Mods::none(),
      ),
    )
    // Click 合成：按下与抬起命中同一只**记账控件**（窗口不算——点空白
    // 不是任何人的 Click，与原生空白处不产事件同一条语义）
    match self.press {
      Some((pressed, pressed_wi)) => {
        self.press = None
        // 左键抬起：拖选结束（`T388`）——选区停在抬起时的形状，不动。
        self.drag = None
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
                self.post(
                  @moonui.Click(@moonui.EventTarget::of(h), @moonui.Left),
                )
                // 自管状态（`T380`）：radio 的"选中哪一行"、checkbox 的"勾没勾"
                // 在原生控件里是控件自己改的，自绘控件没有原生对象，只能由这里
                // 按落点改账再补一条 Change——否则同一个 radio 每点一次都被
                // 应用自己的 on_click 猜着往后挪一位（真窗口反馈"乱换选中项"）。
                if self.click_state(h, point) {
                  self.post(@moonui.Change(@moonui.EventTarget::of(h)))
                }
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
    self.post(
      @moonui.MouseDown(
        @moonui.EventTarget::of(target),
        @moonui.Right,
        point,
        @moonui.Mods::none(),
      ),
    )
    return
  }
  if kind == 0 && button == 2 {
    // 中键按下（T98①）：与右键同一条路由，target 改写成命中控件
    self.post(
      @moonui.MouseDown(
        @moonui.EventTarget::of(target),
        @moonui.Middle,
        point,
        @moonui.Mods::none(),
      ),
    )
    return
  }
  if kind == 1 && button == 2 {
    // 中键抬起（T98①）
    self.post(
      @moonui.MouseUp(
        @moonui.EventTarget::of(target),
        @moonui.Middle,
        point,
        @moonui.Mods::none(),
      ),
    )
    return
  }
  if kind == 3 {
    // 双击（T98①）：第二次按下只产 kind 3（C 侧 clickCount>=2 不再产 kind 0，
    // adapter.h 词表，与 Windows 的 WM_LBUTTONDBLCLK 取代第二颗 DOWN 同一条）。
    // 事件不带点（Event::DoubleClick 只有 target），target 改写成命中控件。
    self.post(@moonui.DoubleClick(@moonui.EventTarget::of(target)))
    // 双击选词（`T387` 文本编辑第二刀）：命中可编辑记账时把光标落到点击处、
    // 再向左右扩出整个词（非空白串）。密码框不选词（掩码串没有词义）。
    match self.hit_test(wi, point) {
      Some(h) => {
        if self.focusable_of(h) {
          self.move_focus(wi, Some(h))
        }
        self.word_select(wi, h, point)
      }
      None => ()
    }
    return
  }
  if kind == 4 {
    // 滚轮（T98①）：dx/dy 是 C 已换算完的**逻辑像素**增量（adapter.h 口径，
    // MoonBit 不许再除一次），原样进 Event::Scroll 的 LogicalPoint。target
    // 改写成命中控件（空白落回窗口，Core 据此丢弃——视口在 Core 里还不是
    // 有原生对象的东西，落在控件间空隙的滚轮没有收件人，同一格欠账）。
    self.post(
      @moonui.Scroll(
        @moonui.EventTarget::of(target),
        @moonui.LogicalPoint(dx.to_double(), dy.to_double()),
      ),
    )
    return
  }
}

///|
/// 绘制序命中（后画的赢）：`order` 是 Core 推来的整份绘制序，L[0] 最上
/// （T29，`repaint` 也是从尾往头画）。所以从 0 往后走、**第一个**命中的就是
/// 最上面那层，命中即返回；早先写成"顺序扫一遍、覆盖 found"，最后留下的是
/// 最底层——根面板的矩形罩住全窗，真窗里点输入框/勾选框全被它截走，表现为
/// "点击没反应"且焦点不动（`T377` 真窗反馈）。
/// 只看可见记账；enabled 不筛——"禁用控件可点与否"是 Core 的事件路由账，
/// 不是绘制账（原生半的禁用也是 C 不吃事件）。
fn CanvasBackend::hit_test(
  self : CanvasBackend,
  wi : Int32,
  point : @moonui.LogicalPoint,
) -> @moonui.NativeHandle? {
  let order = self.windows[wi].order
  // 绘制序 L[0] 最上（T29）：第一个含住该点的可见记账就是用户看见的那一层
  // （`T377`）。反过来取最后一个，底下铺满整窗的容器会把子控件的点击全截走。
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
          return Some(h)
        }
      }
      None => ()
    }
  }
  None
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

///|
/// 点击落在自管状态的控件上（`T380`）：RadioButtons 按落点所在行选中，
/// Checkbox 翻转勾选。返回"该不该补一条 Change"。
///
/// 原生半这两件事由控件自己做；自绘控件没有原生对象，不在这里补，点一下
/// 什么都没发生——应用只能靠 `on_click` 自己猜（画册示例原先就是"点一次
/// 往后挪一位"的假实现）。
fn CanvasBackend::click_state(
  self : CanvasBackend,
  h : @moonui.NativeHandle,
  point : @moonui.LogicalPoint,
) -> Bool raise @moonui.UiError {
  let rec = self.rec_of(h)
  if !rec.enabled {
    return false
  }
  if rec.kind is @moonui.Checkbox {
    rec.checked = !rec.checked
    self.mark_dirty()
    return true
  }
  if rec.kind is @moonui.RadioButtons {
    let n = rec.options.length()
    if n == 0 {
      return false
    }
    let off = self.scroll_offset(h)
    let top = rec.bounds.origin.y + off.y
    let row_h = rec.bounds.size.height / n.to_double()
    if row_h <= 0.0 {
      return false
    }
    let row = ((point.y - top) / row_h).floor().to_int().clamp(min=0, max=n - 1)
    rec.selected = row
    self.mark_dirty()
    return true
  }
  false
}

///|
/// 点击定位光标（`T387` 文本编辑第二刀 + `T389` 跨行）：把可编辑记账的光标/选区
/// 锚点放到点击处对应的字符上。多行按点击 y 先挑可视行、再在行内按 x 定位
/// （`seek_index`）；密码框按掩码串量宽（用户看到的是 ●，下标与明文逐字符对应）。
/// 画布还没收过帧（`win.canvas` None）就没有 Painter 可量字，不动——刚开窗的
/// 第一次点击下一帧再点就精确定位了。
///
/// `anchor` = 落点要不要同时当锚点：点击定位（`T387`）是，`T388` 拖选
/// 移动时传 `false`——锚点钉在按下处、只带活动端 `caret` 跟着鼠标走。
fn CanvasBackend::caret_seek(
  self : CanvasBackend,
  wi : Int32,
  h : @moonui.NativeHandle,
  point : @moonui.LogicalPoint,
  anchor~ : Bool = true,
) -> Unit raise @moonui.UiError {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => {
      if !r.editable() || !r.enabled {
        return
      }
      let p = match self.painter_of(wi) {
        Some(pp) => pp
        None => return
      }
      let shown = if r.kind is @moonui.PasswordInput {
        @canvas-common.mask_secret(r.edit_text())
      } else {
        r.edit_text()
      }
      let off = self.scroll_offset(h)
      let rel = point.x - (r.bounds.origin.x + off.x + 8.0)
      let idx = self.seek_index(wi, r, p, shown, point, off, rel)
      r.caret = idx
      if anchor {
        r.sel = idx
      }
      self.mark_dirty()
      self.caret_poke()
      // 多行框：光标刚被搬到别处，内容跟着滚进视口（`T389`）
      self.scroll_follow(wi, h)
      // 点击定位/拖选都是选区账的**本层**动作，代理不管理选区——推回代理，
      // 否则拖选后直接打字会插在旧插入点（`T395`/`T393` 已知边界）。
      self.ime_sync_sel(wi)
    }
    None => ()
  }
}

///|
/// 字符下标按点击 x 定位：找第一个前缀宽 `>= rel` 的字符（点在字符 i 内或
/// 左缘就归 i），全部窄于 rel 就落末尾。输入框几十字符，线性量宽足够。
fn char_at_x(
  p : @native-common.CanvasPainter,
  text : String,
  rel : Double,
  size : Double,
) -> Int32 raise @moonui.UiError {
  if rel <= 0.0 {
    return 0
  }
  let n = text.length()
  for i = 0; i < n; i = i + 1 {
    let pre = text[0:i + 1].to_owned()
    let (mw, _) = p.measure_text(pre, size, false)
    if mw >= rel {
      return i
    }
  }
  n
}

///|
/// 双击选词（`T387` 文本编辑第二刀）：先 `caret_seek` 落到点击处，再向左右
/// 扩出整段非空白串。密码框不选词（掩码串没有词义），直接返回。
fn CanvasBackend::word_select(
  self : CanvasBackend,
  wi : Int32,
  h : @moonui.NativeHandle,
  point : @moonui.LogicalPoint,
) -> Unit raise @moonui.UiError {
  let rec : CwRec? = Some(self.rec_of(h)) catch { _ => None }
  match rec {
    Some(r) => {
      if !r.editable() || !r.enabled {
        return
      }
      if r.kind is @moonui.PasswordInput {
        return
      }
      self.caret_seek(wi, h, point)
      let rec2 : CwRec? = Some(self.rec_of(h)) catch { _ => None }
      match rec2 {
        Some(r2) => {
          let s = r2.edit_text()
          let n = s.length()
          let mut lo = r2.caret.clamp(min=0, max=n)
          let mut hi = lo
          while lo > 0 && is_word_char(s, lo - 1) {
            lo = lo - 1
          }
          while hi < n && is_word_char(s, hi) {
            hi = hi + 1
          }
          r2.sel = lo
          r2.caret = hi
          self.mark_dirty()
          self.caret_poke()
          // 双击选词也是本层选区动作，推回代理（`T395`/`T393` 已知边界）。
          self.ime_sync_sel(wi)
        }
        None => ()
      }
    }
    None => ()
  }
}

///|
/// 下标处的字符是不是"词字符"（非空白）。词 = 连续非空白串（空格/制表/
/// 换行是分隔符）。
fn is_word_char(s : String, i : Int32) -> Bool {
  match s.get_char(i) {
    Some(c) => !(c == ' ' || c == '\t' || c == '\n' || c == '\r')
    None => false
  }
}

///|
/// 悬停命中该给什么指针（`T380`，adapter.h 鼠标段的 0/1/2 表）：可编辑四类
/// 给竖线，可点控件给手型，其余（含空白）箭头。测试直接调，真窗由
/// `translate_mouse` 在命中变化时落到系统指针上。
pub fn CanvasBackend::cursor_shape_of(
  self : CanvasBackend,
  h : @moonui.NativeHandle?,
) -> Int32 {
  let rec : CwRec? = match h {
    Some(h) => Some(self.rec_of(h)) catch { _ => None }
    None => None
  }
  match rec {
    Some(r) =>
      if r.editable() {
        1
      } else {
        match r.kind {
          @moonui.Button
          | @moonui.Checkbox
          | @moonui.RadioButtons
          | @moonui.ComboBox
          | @moonui.DatePicker
          | @moonui.Slider
          | @moonui.MenuRow => 2
          _ => 0
        }
      }
    None => 0
  }
}
