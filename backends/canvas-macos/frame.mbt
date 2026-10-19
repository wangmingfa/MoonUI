///|
/// 帧循环：脏窗整帧重画（§52.4）。begin_frame 开物理位图 → 窗口底色 →
/// 按 paint order 逐条把配方翻上去 → end_frame → present 上屏。
/// 画布按窗缓存，第一次重画时才挂窗（窗口那时一定已经建好）。
fn CanvasBackend::repaint(
  self : CanvasBackend,
  wi : Int32,
) -> Unit raise @moonui.UiError {
  let win = self.windows[wi]
  let scale = @moonui.Backend::window_scale(self.inner, win.handle)
  let size = @moonui.Backend::window_size(self.inner, win.handle)
  let pw = (size.width * scale.x + 0.5).to_int()
  let ph = (size.height * scale.y + 0.5).to_int()
  let canvas = match win.canvas {
    Some(c) => c
    None => {
      let c = @native-common.canvas_create()
      @native-common.canvas_attach_window(
        c,
        @native-common.NativeBackend::window_ptr(self.inner, win.handle),
      )
      self.windows[wi].canvas = Some(c)
      c
    }
  }
  @native-common.canvas_begin_frame(canvas, pw, ph)
  let p = CanvasPainter::new(canvas, scale.x)
  // 窗口底：吃主题底的背景色（没有就白）。像素账从这里开始。
  let base_bg = match self.theme_base.background {
    Some(c) => pack_color(c)
    None => 0xF5F5F7
  }
  @canvas-common.paint_panel(p, 0.0, 0.0, size.width, size.height, base_bg)
  // 画布坐标原点在左上、y 向下，与 Core 的绝对矩形同一把尺——控件矩形
  // 不用平移，原样进配方。
  // 画序：Core 的 paint order 是「从顶层到底层」（L[0] 最上，T29 契约）。
  // 即时模式里后画的在上，所以从尾往头画——和原生后端 set_paint_order 的
  // 反向 raise 同一把方向（L[0] 最后画 = 最上）。正着画会把底层的画到最上，
  // 毛玻璃面板的半透底就盖住了自己的子项（logo/搜索/按钮被洗白）。
  for i = win.order.length() - 1; i >= 0; i = i - 1 {
    let h = win.order[i]
    // paint order 里可能有已销毁的句柄（close_tree 之后 Core 不重推），
    // 坏账跳过，不拖垮整帧
    let dead : Bool = try {
      let rec = self.rec_of(h)
      if rec.visible {
        self.paint_rec(p, h, rec)
      }
      false
    } catch {
      _ => true
    }
    ignore(dead)
  }
  @native-common.canvas_end_frame(canvas)
  @native-common.canvas_present(canvas)
  self.windows[wi].dirty = false
}

///|
/// 单条记账 → 配方。先算滚动偏移（文档区 → 窗口绝对坐标）与滚动视口裁剪
/// 矩形，再调 paint_rec_body 画配方。
fn CanvasBackend::paint_rec(
  self : CanvasBackend,
  p : CanvasPainter,
  h : @moonui.NativeHandle,
  rec : CwRec,
) -> Unit raise @moonui.UiError {
  // 滚动文档区 → 窗口绝对坐标（T98② 滚动偏移）：Core 把 Scroll 文档区子树按
  // 文档坐标推给后端，画布按窗口绝对坐标画，得沿 scroll_parent 链把每层 Scroll
  // 的视口原点加回去。非滚动内容（链上无 Scroll）偏移是 (0,0)，原样画。
  let off = self.scroll_offset(h)
  let r = @moonui.LogicalRect(
    @moonui.LogicalPoint(
      rec.bounds.origin.x + off.x,
      rec.bounds.origin.y + off.y,
    ),
    rec.bounds.size,
  )
  // 滚动视口裁剪（T98②）：文档区子树锁回最近 Scroll 的视口——滚出视口的行
  // 不画。save/clip/restore 必须配对：配方 raise 时 restore 也得跑（GState
  // 栈不配平会把裁剪漏到同帧后面的控件上，repaint 的循环不 break 会继续画）。
  // errdefer 只在出错时跑 restore，成功路径走显式 restore——两条路各一次。
  match self.scroll_clip_rect(h) {
    Some(c) => {
      p.save()
      p.clip_rect(c.origin.x, c.origin.y, c.size.width, c.size.height)
      errdefer p.restore()
      self.paint_rec_body(p, h, rec, r)
      p.restore()
    }
    None => self.paint_rec_body(p, h, rec, r)
  }
}

///|
/// 单条记账 → 配方（裁剪无关的纯绘制）。paint_rec 在它外面包滚动视口裁剪。
/// 四种 kind 有真配方；其余画占位圆角面（分期②的第一刀，配方的覆盖面随
/// 分期③扩）。
fn CanvasBackend::paint_rec_body(
  self : CanvasBackend,
  p : CanvasPainter,
  h : @moonui.NativeHandle,
  rec : CwRec,
  r : @moonui.LogicalRect,
) -> Unit raise @moonui.UiError {
  match rec.kind {
    Panel =>
      // 毛玻璃（T98②）：设了 backdrop_blur 就走毛玻璃配方——先把这块区域
      // 后面已画的内容原地模糊，再叠半透底（background 的 alpha）。顺序
      // 在配方里钉死（先模糊后叠底），这里只挑配方。
      match rec.backdrop_blur {
        Some(blur) =>
          @canvas-common.paint_frosted_panel(
            p,
            r.origin.x,
            r.origin.y,
            r.size.width,
            r.size.height,
            self.bg_of(rec, 0xE9E9EC),
            self.bg_alpha_of(rec),
            blur~,
            radius=self.radius_of(rec),
          )
        None =>
          match rec.bg_gradient {
            Some(g) => {
              let stops : Array[(Double, Int32)] = []
              for s in g.stops {
                stops.push((s.0, pack_color(s.1)))
              }
              let horizontal = match g.dir {
                @moonui.GradientDir::Horizontal => true
                _ => false
              }
              @canvas-common.paint_gradient_panel(
                p,
                r.origin.x,
                r.origin.y,
                r.size.width,
                r.size.height,
                stops,
                horizontal~,
              )
            }
            None =>
              @canvas-common.paint_panel(
                p,
                r.origin.x,
                r.origin.y,
                r.size.width,
                r.size.height,
                self.bg_of(rec, 0xE9E9EC),
                radius=self.radius_of(rec),
              )
          }
      }
    Label =>
      @canvas-common.paint_label(
        p,
        rec.text,
        r.origin.x,
        r.origin.y,
        r.size.width,
        r.size.height,
        self.fg_of(rec, 0x333333),
        size=self.font_size_of(rec),
        bold=rec.bold,
      )
    Button => {
      // 图标钮配方顶上：底色圆角面 + 居中字形（icon 优先，没图标用文本）
      let fg = self.fg_of(rec, 0x333333)
      let face = @canvas-common.ButtonFace::{
        normal_bg: self.bg_of(rec, 0xE8E8EB),
        hover_bg: 0xDCDCE0,
        pressed_bg: 0xCCCCCC,
        fg,
        radius: self.radius_of(rec),
      }
      // 三态：按下 > 悬停 > 常态（画账在这层，Core 的 hover 样式是另一条通道）
      let state = match self.press {
        Some((pressed, _)) =>
          if pressed == h {
            @canvas-common.Pressed
          } else {
            @canvas-common.Normal
          }
        None =>
          match self.hover {
            Some(hh) =>
              if hh == h {
                @canvas-common.Hover
              } else {
                @canvas-common.Normal
              }
            None => @canvas-common.Normal
          }
      }
      @canvas-common.paint_icon_button(
        p,
        if rec.icon != "" {
          rec.icon
        } else {
          rec.text
        },
        r.origin.x,
        r.origin.y,
        r.size.width,
        r.size.height,
        face,
        state,
        glyph_size=self.font_size_of(rec),
      )
    }
    Slider => {
      // 值域 → 千分位（配方的 0..1000 口径）
      let span = rec.max - rec.min
      let permille = if span <= 0 {
        0
      } else {
        ((rec.value - rec.min) * 1000 / span).clamp(min=0, max=1000)
      }
      @canvas-common.paint_slider(
        p,
        r.origin.x,
        r.origin.y,
        r.size.width,
        r.size.height,
        permille,
        track=0xDDDDDD,
        // 强调蓝（YesPlayMusic --color-primary），与原生壳的系统蓝滑条同档
        accent=0x335EEA,
        thumb=0xFFFFFF,
      )
    }
    MenuRow =>
      @canvas-common.paint_menu_row(
        p,
        rec.text,
        r.origin.x,
        r.origin.y,
        r.size.width,
        r.size.height,
        selected=rec.checked,
        fg=self.fg_of(rec, 0x333333),
        selected_fg=self.fg_of(rec, 0x335EEA),
        size=self.font_size_of(rec),
        bold=rec.bold,
      )
    TextInput =>
      // 占位符色默认弱灰（网易云搜索框那一档），显式给过 fg 就吃显式的
      @canvas-common.paint_text_input(
        p,
        rec.text,
        r.origin.x,
        r.origin.y,
        r.size.width,
        r.size.height,
        fg=self.fg_of(rec, 0x999999),
      )
    Separator =>
      @canvas-common.paint_separator(
        p,
        r.origin.x,
        r.origin.y,
        r.size.width,
        r.size.height,
        rgb=0xE0E0E0,
      )
    VSeparator =>
      // 竖线：分隔线的镜像（宽件里画纵向 1px）
      p.line(
        r.origin.x + (r.size.width - 1.0) / 2.0,
        r.origin.y,
        r.origin.x + (r.size.width - 1.0) / 2.0,
        r.origin.y + r.size.height,
        1.0,
        0xE0E0E0,
      )
    Image =>
      // 有源贴图（cloudmusic 封面走 set_image_bytes 的字节通道），没源
      // 画占位面。路径通道不记账——读文件归应用/平台，MoonBit 侧零解码。
      if rec.image.length() > 0 {
        p.draw_image(
          rec.image,
          r.origin.x,
          r.origin.y,
          r.size.width,
          r.size.height,
        )
      } else {
        @canvas-common.paint_panel(
          p,
          r.origin.x,
          r.origin.y,
          r.size.width,
          r.size.height,
          self.bg_of(rec, 0xEFEFF1),
          radius=self.radius_of(rec),
        )
      }
    // 其余 kind 还是占位面
    _ =>
      @canvas-common.paint_panel(
        p,
        r.origin.x,
        r.origin.y,
        r.size.width,
        r.size.height,
        self.bg_of(rec, 0xEFEFF1),
        radius=self.radius_of(rec),
      )
  }
}

///|
/// 记账字段的"显式 vs 底"账：显式给过就用显式的，没给就吃主题底的同字段，
/// 底也没有才落默认值——与原生后端 §32 的分野同一条思想，只是自绘后端
/// 没有"保原生外观"的包袱，默认值是配方的一等账。
fn CanvasBackend::bg_of(
  self : CanvasBackend,
  rec : CwRec,
  default : Int32,
) -> Int32 {
  match rec.bg {
    Some(v) => v
    None =>
      match self.theme_base.background {
        Some(c) => pack_color(c)
        None => default
      }
  }
}

///|
/// 底色 alpha（0..255）：显式给过就用显式的，没给就吃主题底的同字段，
/// 底也没有才落 255（不透明）。与 bg_of 同一套"显式 vs 底"账，只是 alpha
/// 这条通道（T98② 毛玻璃起）。
fn CanvasBackend::bg_alpha_of(self : CanvasBackend, rec : CwRec) -> Int32 {
  match rec.bg_alpha {
    Some(v) => v
    None =>
      match self.theme_base.background {
        Some(c) => c.a
        None => 255
      }
  }
}

///|
fn CanvasBackend::fg_of(
  self : CanvasBackend,
  rec : CwRec,
  default : Int32,
) -> Int32 {
  match rec.fg {
    Some(v) => v
    None =>
      match self.theme_base.foreground {
        Some(c) => pack_color(c)
        None => default
      }
  }
}

///|
fn CanvasBackend::radius_of(self : CanvasBackend, rec : CwRec) -> Double {
  match rec.radius {
    Some(v) => v
    None =>
      match self.theme_base.radius {
        Some(v) => v
        None => 0.0
      }
  }
}

///|
fn CanvasBackend::font_size_of(self : CanvasBackend, rec : CwRec) -> Double {
  match rec.font_size {
    Some(v) => v
    None =>
      match self.theme_base.font_size {
        Some(v) => v
        None => 14.0
      }
  }
}

///|
/// Color → 0xRRGGBB（与皮肤通道/画布 ABI 同一口径，alpha 第一刀不吃）。
fn pack_color(c : @moonui.Color) -> Int32 {
  (c.r << 16) | (c.g << 8) | c.b
}

///|
/// 帧循环收口：把所有脏窗重画一遍。配方失败（量字/开帧）raise——poll_event
/// 没有 raise 位，所以收在前面的 `App::step` 也会看到同一条错误（§33）。
fn CanvasBackend::flush_dirty(
  self : CanvasBackend,
) -> Unit raise @moonui.UiError {
  for i = 0; i < self.windows.length(); i = i + 1 {
    if self.windows[i].dirty {
      self.repaint(i)
    }
  }
}
