///|
/// Backend 契约的自绘实现：窗口/系统服务整批转发给内嵌的原生后端，控件
/// 批走记账（backend.mbt / frame.mbt）。转发用 `@moonui.Backend::` 显式
/// 调（不靠方法提升），后端可换这一语义在类型上就成立。
pub impl @moonui.Backend for CanvasBackend with fn init(self) -> Unit raise @moonui.UiError {
  @moonui.Backend::init(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn terminate(self) {
  // 画布先于窗口销毁（挂窗账：present 贴的是 layer，不持有窗口，但
  // begin_frame 后的位图还在，先收干净）
  for w in self.windows {
    match w.canvas {
      Some(c) => @native-common.canvas_destroy(c) catch { _ => () }
      None => ()
    }
  }
  self.windows = []
  self.recs = []
  self.free = []
  self.queue = []
  self.press = None
  self.mouse_installed = false // C 闭包随 inner 的 terminate 松开
  @moonui.Backend::terminate(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn poll_event(self) -> @moonui.Event? {
  // 先收脏帧再泵：Core 的 step 每圈都来问，脏帧最多迟到一圈
  self.flush_dirty() catch {
    _ => ()
  }
  // 自绘鼠标队列优先（改写过 target 的事件先走，顺序才不乱）
  if self.queue.length() > 0 {
    return Some(self.queue.remove(0))
  }
  @moonui.Backend::poll_event(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn request_redraw(self, h) -> Unit raise @moonui.UiError {
  match self.win_idx(h) {
    Some(i) => self.windows[i].dirty = true
    None => () // 控件句柄：整帧重画的口径里全窗已经标了
  }
}

///|
pub impl @moonui.Backend for CanvasBackend with fn create_window(
  self,
  title,
  size,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let h = @moonui.Backend::create_window(self.inner, title, size)
  self.windows.push(CwWin::{ handle: h, order: [], canvas: None, dirty: true, })
  // inner 的 create_window 首窗惰性装它自己的鼠标闭包，这里顶成自绘的
  // 翻译闭包（命中测试在记账侧，见 mouse.mbt）
  self.install_mouse()
  h
}

///|
pub impl @moonui.Backend for CanvasBackend with fn destroy_window(self, h) -> Unit raise @moonui.UiError {
  let kept : Array[CwWin] = []
  for w in self.windows {
    if w.handle != h {
      kept.push(w)
    } else {
      match w.canvas {
        Some(c) => @native-common.canvas_destroy(c) catch { _ => () }
        None => ()
      }
    }
  }
  self.windows = kept
  @moonui.Backend::destroy_window(self.inner, h)
}

///|
/// —— 窗口属性与系统服务：整批转发 ——
pub impl @moonui.Backend for CanvasBackend with fn set_window_title(
  self,
  h,
  title,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_title(self.inner, h, title)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_size(
  self,
  h,
  size,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_size(self.inner, h, size)
  match self.win_idx(h) {
    Some(i) => self.windows[i].dirty = true
    None => ()
  }
}

///|
pub impl @moonui.Backend for CanvasBackend with fn show_window(self, h) -> Unit raise @moonui.UiError {
  @moonui.Backend::show_window(self.inner, h)
  match self.win_idx(h) {
    Some(i) => self.windows[i].dirty = true
    None => ()
  }
}

///|
pub impl @moonui.Backend for CanvasBackend with fn hide_window(self, h) -> Unit raise @moonui.UiError {
  @moonui.Backend::hide_window(self.inner, h)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn window_scale(self, h) -> @moonui.Scale raise @moonui.UiError {
  @moonui.Backend::window_scale(self.inner, h)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn screen_size(self) -> @moonui.LogicalSize raise @moonui.UiError {
  @moonui.Backend::screen_size(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn window_work_area(self, h) -> @moonui.LogicalRect raise @moonui.UiError {
  @moonui.Backend::window_work_area(self.inner, h)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn system_theme(self) -> @moonui.Theme raise @moonui.UiError {
  @moonui.Backend::system_theme(self.inner)
}

///|
/// 血统跟着内层原生后端走：画布后端也是 mac 上的进程，红绿灯一样存在。
pub impl @moonui.Backend for CanvasBackend with fn host_platform(self) -> @moonui.HostPlatform {
  @moonui.Backend::host_platform(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn get_prefers_reduced_motion(
  self,
) -> Bool raise @moonui.UiError {
  @moonui.Backend::get_prefers_reduced_motion(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn get_prefers_high_contrast(
  self,
) -> Bool raise @moonui.UiError {
  @moonui.Backend::get_prefers_high_contrast(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn window_size(self, h) -> @moonui.LogicalSize raise @moonui.UiError {
  @moonui.Backend::window_size(self.inner, h)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_position(
  self,
  h,
  p,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_position(self.inner, h, p)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn window_position(self, h) -> @moonui.LogicalPoint raise @moonui.UiError {
  @moonui.Backend::window_position(self.inner, h)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_resizable(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_resizable(self.inner, h, v)
}

///|
/// 窗口最小尺寸原样交给原生窗口（canvas 后端自己不画窗口边框，钳位是系统的事）。
pub impl @moonui.Backend for CanvasBackend with fn set_window_min_size(
  self,
  h,
  size,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_min_size(self.inner, h, size)
}

///|
/// 实时重排开关原样交给原生窗口（拖拽钳位与回声都是系统窗口的事，canvas 只
/// 自绘内容）。
pub impl @moonui.Backend for CanvasBackend with fn set_window_live_redraw(
  self,
  h,
  on,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_live_redraw(self.inner, h, on)
}

///|
/// 实时直达通道转交内层（Resize 由内层的原生窗口产生，分流也在那条
/// `push_resize` 里）。
pub impl @moonui.Backend for CanvasBackend with fn set_live_dispatch(self, f) -> Unit {
  @moonui.Backend::set_live_dispatch(self.inner, f)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_fullscreen(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_fullscreen(self.inner, h, v)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_titlebar_style(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_titlebar_style(self.inner, h, v)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_traffic_light_position(
  self,
  h,
  p,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_traffic_light_position(self.inner, h, p)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_minimized(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_minimized(self.inner, h, v)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_window_maximized(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_window_maximized(self.inner, h, v)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn window_state(self, h) -> @moonui.WindowState raise @moonui.UiError {
  @moonui.Backend::window_state(self.inner, h)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn clipboard_text(self) -> String? raise @moonui.UiError {
  @moonui.Backend::clipboard_text(self.inner)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_clipboard_text(
  self,
  text,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_clipboard_text(self.inner, text)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn show_message(
  self,
  title,
  text,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::show_message(self.inner, title, text)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn confirm(self, title, text) -> Bool raise @moonui.UiError {
  @moonui.Backend::confirm(self.inner, title, text)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn open_file(self, title) -> String? raise @moonui.UiError {
  @moonui.Backend::open_file(self.inner, title)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn save_file(self, title, name) -> String? raise @moonui.UiError {
  @moonui.Backend::save_file(self.inner, title, name)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn select_folder(self, title) -> String? raise @moonui.UiError {
  @moonui.Backend::select_folder(self.inner, title)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_menu_bar(self, menu) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_menu_bar(self.inner, menu)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_menu_item_checked(
  self,
  id,
  checked,
) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_menu_item_checked(self.inner, id, checked)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_app_icon(self, name) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_app_icon(self.inner, name)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn show_context_menu(self, menu) -> Unit raise @moonui.UiError {
  @moonui.Backend::show_context_menu(self.inner, menu)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_tray_icon(self, name) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_tray_icon(self.inner, name)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_tray_menu(self, menu) -> Unit raise @moonui.UiError {
  @moonui.Backend::set_tray_menu(self.inner, menu)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn notify(self, title, body) -> Unit raise @moonui.UiError {
  @moonui.Backend::notify(self.inner, title, body)
}

///|
/// —— 控件批：记账 ——
pub impl @moonui.Backend for CanvasBackend with fn create_widget(
  self,
  kind,
  text,
) -> @moonui.NativeHandle raise @moonui.UiError {
  self.mark_dirty()
  self.alloc(kind, text)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn create_ranged_widget(
  self,
  kind,
  min,
  max,
) -> @moonui.NativeHandle raise @moonui.UiError {
  let h = self.alloc(kind, "")
  let rec = self.rec_of(h)
  rec.min = min
  rec.max = max
  self.mark_dirty()
  h
}

///|
pub impl @moonui.Backend for CanvasBackend with fn destroy_widget(self, h) -> Unit raise @moonui.UiError {
  let idx = self.idx_of(h)
  self.recs[idx] = None
  self.free.push(idx)
  let _ = self.table.unregister(h)
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_text(
  self,
  h,
  text,
) -> Unit raise @moonui.UiError {
  self.rec_of(h).text = text
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_text(self, h) -> String raise @moonui.UiError {
  self.rec_of(h).text
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_checked(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.rec_of(h).checked = v
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_checked(self, h) -> Bool raise @moonui.UiError {
  self.rec_of(h).checked
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_insets(
  _self,
  _h,
  _insets,
) -> Unit raise @moonui.UiError {
  // 自绘控件没有原生的内容边距账；Core 的 padding 在布局侧已算进 bounds
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_value(self, h, v) -> Unit raise @moonui.UiError {
  self.rec_of(h).value = v
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_value(self, h) -> Int32 raise @moonui.UiError {
  self.rec_of(h).value
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_range(
  self,
  h,
  min,
  max,
) -> Unit raise @moonui.UiError {
  let rec = self.rec_of(h)
  rec.min = min
  rec.max = max
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn append_widget_option(
  _self,
  _h,
  _option,
) -> Unit raise @moonui.UiError {
  // 下拉/组合框的选项列表是分期③的账（现在画的是占位面）
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_selected(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.rec_of(h).selected = v
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_selected(self, h) -> Int32 raise @moonui.UiError {
  self.rec_of(h).selected
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_datetime(
  _self,
  _h,
  _v,
) -> Unit raise @moonui.UiError {
  // 日期控件是占位面，值不进账
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_datetime(_self, _h) -> String raise @moonui.UiError {
  ""
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_visible(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.rec_of(h).visible = v
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_visible(self, h) -> Bool raise @moonui.UiError {
  self.rec_of(h).visible
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_enabled(
  self,
  h,
  v,
) -> Unit raise @moonui.UiError {
  self.rec_of(h).enabled = v
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_enabled(self, h) -> Bool raise @moonui.UiError {
  self.rec_of(h).enabled
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_opacity(
  _self,
  _h,
  _v,
) -> Unit raise @moonui.UiError {
  // 透明度通道等画布 ABI 支持 alpha 混合的配方（第一刀不吃）
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_style(
  self,
  h,
  style,
) -> Unit raise @moonui.UiError {
  let rec = self.rec_of(h)
  match style.background {
    Some(c) => {
      rec.bg = Some(pack_color(c))
      // alpha 单独记（pack_color 丢 alpha 的旧账，T98② 毛玻璃起补上）
      rec.bg_alpha = Some(c.a)
    }
    None => ()
  }
  // 渐变底（§15）：整体覆盖（None 也要清掉旧渐变，重排时样式整份重推）
  rec.bg_gradient = style.background_gradient
  match style.foreground {
    Some(c) => rec.fg = Some(pack_color(c))
    None => ()
  }
  match style.radius {
    Some(v) => rec.radius = Some(v)
    None => ()
  }
  match style.backdrop_blur {
    Some(v) => rec.backdrop_blur = Some(v)
    None => ()
  }
  match style.font_size {
    Some(v) => rec.font_size = Some(v)
    None => ()
  }
  match style.font_weight {
    Some(w) => rec.bold = w == @moonui.FontWeight::Bold
    None => ()
  }
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_icon(
  self,
  h,
  name,
) -> Unit raise @moonui.UiError {
  self.rec_of(h).icon = name
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_theme_base(self, style) -> Unit raise @moonui.UiError {
  self.theme_base = style
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_accessibility(
  _self,
  _h,
  _a,
) -> Unit raise @moonui.UiError {
  // 自绘控件的无障碍账在分期③（画布层要先有语义树）
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_bounds(
  self,
  h,
  rect,
) -> Unit raise @moonui.UiError {
  self.rec_of(h).bounds = rect
  self.mark_dirty()
}

///|
pub impl @moonui.Backend for CanvasBackend with fn widget_bounds(self, h) -> @moonui.LogicalRect raise @moonui.UiError {
  self.rec_of(h).bounds
}

///|
/// 度量走画布的字形账（量出来的就是画出来的）；尺寸字段的显式账优先。
pub impl @moonui.Backend for CanvasBackend with fn widget_intrinsic_size(
  self,
  h,
) -> @moonui.LogicalSize raise @moonui.UiError {
  let rec = self.rec_of(h)
  let (w, th) = @native-common.canvas_measure_text(
    if rec.text != "" {
      rec.text
    } else {
      "Ag"
    },
    self.font_size_of(rec),
    bold=rec.bold,
  )
  @moonui.LogicalSize(w, th)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn attach_widget(
  _self,
  _win,
  _child,
) -> Unit raise @moonui.UiError {
  // 自绘没有挂接动作：paint order 才是层级账，attach 只是窗口记账路过
}

///|
pub impl @moonui.Backend for CanvasBackend with fn attach_widget_to(
  self,
  container,
  child,
) -> Unit raise @moonui.UiError {
  // 记 child 的最近认领祖先（container 的记账索引）。Core 把 Scroll 文档区子树
  // 按**文档坐标**推给后端（减去最近 Scroll 的视口原点），原生后端对（NSScrollView
  // 的 documentView 原点=视口左上），画布按**窗口绝对坐标**画——重画/命中时沿这条
  // 链把每层 Scroll 的视口原点加回去（scroll_offset）。Panel 也认领子树但不贡献
  // 原点，链穿过它才能到外层 Scroll。先序挂接保证链上每个节点的 scroll_parent
  // 在子节点之前已就位；换树时旧树整棵销毁、新树记账全新，不跨树留旧链。
  let cidx = self.idx_of(container)
  self.rec_of(child).scroll_parent = Some(cidx)
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_scroll_content(
  _self,
  _h,
  _axis,
  _size,
) -> Unit raise @moonui.UiError {
  // 滚动视口的裁剪/偏移在下一刀接（先把不滚动的画对）
}

///|
pub impl @moonui.Backend for CanvasBackend with fn detach_widget(_self, _child) -> Unit raise @moonui.UiError {
  // 同 attach：层级只认 paint order
}

///|
pub impl @moonui.Backend for CanvasBackend with fn raise_widget(_self, _child) -> Unit raise @moonui.UiError {
  // 层级由 Core 每次整份推（set_paint_order），单项提层没有账
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_paint_order(
  self,
  win,
  order,
) -> Unit raise @moonui.UiError {
  match self.win_idx(win) {
    Some(i) => {
      self.windows[i].order = order
      self.windows[i].dirty = true
    }
    None => ()
  }
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_focus_chain(
  _self,
  _win,
  _chain,
) -> Unit raise @moonui.UiError {
  // 焦点路由在自绘半的命中测试那一刀之前没有意义（收不到控件级事件）
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_image_path(
  _self,
  _h,
  _path,
) -> Unit raise @moonui.UiError {
  // draw_image 的配方在分期③（现在 Image 画占位面）
}

///|
pub impl @moonui.Backend for CanvasBackend with fn set_widget_image_bytes(
  self,
  h,
  bytes,
) -> Unit raise @moonui.UiError {
  // 原样记账（解码归画布那头的平台层，moonui_canvas_draw_image）
  self.rec_of(h).image = bytes
  self.mark_dirty()
}

///|
/// 显式把 Backend 方法挂成 CanvasBackend 的普通方法（新语法要求，避免隐式提升的弃用告警）。
pub extend CanvasBackend with @moonui.Backend::{
  append_widget_option,
  attach_widget,
  attach_widget_to,
  clipboard_text,
  confirm,
  create_ranged_widget,
  create_widget,
  create_window,
  destroy_widget,
  destroy_window,
  detach_widget,
  get_prefers_high_contrast,
  get_prefers_reduced_motion,
  hide_window,
  init,
  notify,
  open_file,
  poll_event,
  raise_widget,
  request_redraw,
  save_file,
  screen_size,
  select_folder,
  set_app_icon,
  set_clipboard_text,
  set_focus_chain,
  set_live_dispatch,
  set_menu_bar,
  set_menu_item_checked,
  set_paint_order,
  set_scroll_content,
  set_theme_base,
  set_window_live_redraw,
  set_window_min_size,
  set_tray_icon,
  set_tray_menu,
  set_widget_accessibility,
  set_widget_bounds,
  set_widget_checked,
  set_widget_datetime,
  set_widget_enabled,
  set_widget_icon,
  set_widget_image_bytes,
  set_widget_image_path,
  set_widget_insets,
  set_widget_opacity,
  set_widget_range,
  set_widget_selected,
  set_widget_style,
  set_widget_text,
  set_widget_value,
  set_widget_visible,
  set_window_fullscreen,
  set_window_maximized,
  set_window_minimized,
  set_window_position,
  set_window_resizable,
  set_window_size,
  set_window_title,
  set_window_titlebar_style,
  set_window_traffic_light_position,
  show_context_menu,
  show_message,
  show_window,
  system_theme,
  host_platform,
  terminate,
  widget_bounds,
  widget_checked,
  widget_datetime,
  widget_enabled,
  widget_intrinsic_size,
  widget_selected,
  widget_text,
  widget_value,
  widget_visible,
  window_position,
  window_scale,
  window_size,
  window_state,
  window_work_area,
}
