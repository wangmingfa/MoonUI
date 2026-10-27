///|
/// Luna主控面板（脸面）：信息条 / 频谱可视化 + 大字时间状态 / 播放进度 /
/// 走带。这是「还原Luna」的主体。
///
/// 布局纪律（上一版翻车的地方，记在这）：**全部定高分段，不用 expand 撑满**。
/// `expand` 的语义是"吃父容器主轴剩余空间"，而 Column 量非 expand 子项时给的
/// 主轴上限是无界的（1e18 哨兵）——把 expand 或 Stack 放进去，滑块会被量成
/// 456×1e18，把下面整排控件推到屏幕外（界面上看就是「一片蓝，什么都没有」）。
/// 所以这里每一段都写死高度，段内也不再需要 `Stack` 以外的自适应。
///
/// 状态刷新在 app.refresh_bar（player 的 notify 广播触发），这里只建零件留把手。
pub(all) struct PlayBar[B] {
  root : @moonui.Widget[B]
  /// 信息条：歌名（左，撑满）
  title : @moonui.Widget[B]
  /// 信息条：歌手 - 专辑（右）
  artist : @moonui.Widget[B]
  /// 脸面：大号当前时间（01:30）
  time_big : @moonui.Widget[B]
  /// 脸面：总时长（/ 04:12）
  time_total : @moonui.Widget[B]
  /// 脸面：播放状态（状态: 播放/暂停/就绪）
  state_text : @moonui.Widget[B]
  prev : @moonui.Widget[B]
  toggle : @moonui.Widget[B]
  stop : @moonui.Widget[B]
  next : @moonui.Widget[B]
  progress : @moonui.Widget[B]
  /// 进度条的自绘层（点亮方块；拖动仍归 progress 那只原生滑块）
  prog_bar : CmBar[B]
  mode : @moonui.Widget[B]
  volume : @moonui.Widget[B]
  /// 音量条的自绘层（同上）
  vol_bar : CmBar[B]
  /// 频谱可视化窗（真实音频能量驱动）
  viz : Spectrum[B]
  /// PL / EQ / LRC 三个小开关（原版右下角那三个，控制三个伴窗）
  pl : @moonui.Widget[B]
  eq : @moonui.Widget[B]
  lrc : @moonui.Widget[B]
  /// 收藏（♡/♥）：原版在主控右上角那颗心，这里放信息条右端
  fav : @moonui.Widget[B]
}

///|
/// 频谱可视化（Luna脸面左侧那块）：16 段 × 7 颗小方块，段能量来自
/// **真实音频**（原生层在混音器输出上装 tap 做 FFT，见 adapter.h 频谱段），
/// 每拍由 app.refresh_spectrum 把 16 个千分位读数灌进来。
///
/// 为什么是"段 × 颗"而不是"一根可变高的柱子"：框架没有运行期改尺寸的通道
/// （`Widget::sized` 只在建树时生效），所以把每根柱子切成 7 颗定高小方块，
/// 靠**换底色**表达高低——高度 7 档，视觉上就是原版那种跳动条。
pub(all) struct Spectrum[B] {
  root : @moonui.Widget[B]
  /// segs[段][颗]，颗 0 在最下面
  segs : Array[Array[@moonui.Widget[B]]]
  /// 上一次点亮了几颗：只有变了才改样式（每拍 112 次 set_style 太浪费）
  last : Array[Int32]
}

///|
/// 段数与每段的颗数（段数 = 原生层 FFT 的对数分桶数，两边必须一致）。
pub fn cm_viz_bands() -> Int32 {
  16
}

///|
pub fn cm_viz_segs() -> Int32 {
  7
}

///|
pub fn[B : @moonui.Backend] Spectrum::new(
  b : B,
  w : Double,
  h : Double,
) -> Spectrum[B] raise @moonui.UiError {
  let bands = cm_viz_bands()
  let segs_n = cm_viz_segs()
  let seg_h = h / segs_n.to_double()
  let seg_w = (w - bands.to_double()) / bands.to_double() // 留 1px 缝
  let segs : Array[Array[@moonui.Widget[B]]] = []
  let last : Array[Int32] = []
  let band_cols : Array[@moonui.Widget[B]] = []
  for bi = 0; bi < bands; bi = bi + 1 {
    let col : Array[@moonui.Widget[B]] = []
    let stack : Array[@moonui.Widget[B]] = []
    // 从上往下排（颗 0 在最下面：先 push 的是上面的）
    for si = segs_n - 1; si >= 0; si = si - 1 {
      let cell = @moonui.Widget::panel(b, @moonui.Widget::spacer(b))
      let _ = cell.set_style(Some(@moonui.style(background=Some(cm_inset()))))
      col.push(cell)
      stack.push(@moonui.Widget::sized(b, Some(seg_w), Some(seg_h), cell))
    }
    // col[0] 是最上面那颗，翻过来让 segs[段][0] = 最下面
    let bottom_up : Array[@moonui.Widget[B]] = []
    for i = col.length() - 1; i >= 0; i = i - 1 {
      bottom_up.push(col[i])
    }
    segs.push(bottom_up)
    last.push(0)
    band_cols.push(
      @moonui.Widget::sized(
        b,
        Some(seg_w),
        Some(h),
        @moonui.Widget::column(b, 0.0, stack),
      ),
    )
  }
  let row = @moonui.Widget::row(b, 1.0, band_cols)
  let inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(4.0, 4.0),
    row,
  )
  // 凹陷框：外面 1px 暗边 + 里面深底，读起来像嵌进面板里的一块玻璃（原版那种
  // "可视窗"）。`Style` 没有描边，所以暗边用一层 Padding 露出底色来当。
  let glass = @moonui.Widget::panel(b, inner)
  let _ = glass.set_style(
    Some(@moonui.style(background=Some(cm_inset()), radius=Some(2.0))),
  )
  let framed = @moonui.Widget::padding(b, @moonui.EdgeInsets::all(1.0), glass)
  let root = @moonui.Widget::panel(b, framed)
  let _ = root.set_style(
    Some(@moonui.style(background=Some(cm_bevel_lo()), radius=Some(3.0))),
  )
  { root, segs, last, }
}

///|
/// 按 16 段能量（0..1000）点亮：千分位越高亮得越多。只改变化了的段。
pub fn[B] Spectrum::update(
  self : Spectrum[B],
  levels : Array[Int32],
) -> Unit raise @moonui.UiError {
  let segs_n = cm_viz_segs()
  for bi = 0; bi < self.segs.length(); bi = bi + 1 {
    let lv = if bi < levels.length() { levels[bi] } else { 0 }
    let mut lit = lv * segs_n / 1000
    if lit < 0 {
      lit = 0
    }
    if lit > segs_n {
      lit = segs_n
    }
    if self.last[bi] == lit {
      continue
    }
    self.last[bi] = lit
    for si = 0; si < self.segs[bi].length(); si = si + 1 {
      let on = si < lit
      let _ = self.segs[bi][si].set_style(
        Some(
          @moonui.style(background=Some(if on { cm_bar() } else { cm_inset() })),
        ),
      )
    }
  }
}

///|
/// 一段「带倒角的皮肤条」：高 h，上下各 1px 亮/暗线，中间是内容。
///
/// Luna那套皮肤（Winamp 系）的立体感几乎全靠这两条 1px 线——上缘一条亮
/// 线、下缘一条暗线，读起来像一条有厚度的金属条。`Style` 没有描边字段，所以
/// 亮线/暗线就用两条 1px 的 Panel 叠出来（零新增 ABI）。
fn[B : @moonui.Backend] cm_band(
  b : B,
  h : Double,
  content : @moonui.Widget[B],
) -> @moonui.Widget[B] raise @moonui.UiError {
  let hi = @moonui.Widget::sized(
    b,
    None,
    Some(1.0),
    @moonui.Widget::panel(b, @moonui.Widget::spacer(b)).background(
      cm_bevel_hi(),
    ),
  )
  let mid = @moonui.Widget::sized(b, None, Some(h - 2.0), content)
  let lo = @moonui.Widget::sized(
    b,
    None,
    Some(1.0),
    @moonui.Widget::panel(b, @moonui.Widget::spacer(b)).background(
      cm_bevel_lo(),
    ),
  )
  let col = @moonui.Widget::column(b, 0.0, [hi, mid, lo])
  @moonui.Widget::sized(b, None, Some(h), col)
}

///|
/// 自绘进度条/音量条：**画面是自己画的方块，拖动仍归原生 Slider**。
///
/// 为什么要这么绕：mac 的 NSSlider 改不了轨道与钮的颜色（AppKit 不开这个口），
/// 一颗 30px 的白圆压在 22px 的带上，整条走带的观感就全毁了。做法是把原生滑块
/// 按到 alpha 0.01（`Widget::opacity` → NSView.alphaValue），只留它的**拖动**
/// 能力——Stack 里它排在最后（最上层），命中测试落在它身上，点击与拖动照旧是
/// 原生语义；画面交给下面那排方块。
///
/// 为什么是"方块"而不是一条可伸缩的填充：框架没有运行期改尺寸的通道
/// （`sized` 只在建树时生效），所以用 n 颗定宽方块换底色表达进度——与频谱同一
/// 套手法。
pub(all) struct CmBar[B] {
  root : @moonui.Widget[B]
  blocks : Array[@moonui.Widget[B]]
  on : @moonui.Color
  off : @moonui.Color
  /// 上一次点亮了几颗：只改变化的那几颗
  mut last : Int32
}

///|
/// 建一条：n 颗方块横排，每颗 `w/n` 宽、h 高，`pad_top` 把整排压到带的中间；
/// `slider` 是那只被"蒙住"的原生滑块。
pub fn[B : @moonui.Backend] CmBar::new(
  b : B,
  slider : @moonui.Widget[B],
  n : Int32,
  w : Double,
  h : Double,
  pad_top : Double,
  on : @moonui.Color,
  off : @moonui.Color,
) -> CmBar[B] raise @moonui.UiError {
  let bw = w / n.to_double()
  let blocks : Array[@moonui.Widget[B]] = []
  for _i = 0; _i < n; _i = _i + 1 {
    let cell = @moonui.Widget::panel(b, @moonui.Widget::spacer(b))
    let _ = cell.set_style(Some(@moonui.style(background=Some(off))))
    blocks.push(@moonui.Widget::sized(b, Some(bw), Some(h), cell))
  }
  let row = @moonui.Widget::row(b, 0.0, blocks)
  let placed = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::{ top: pad_top, end: 0.0, bottom: 0.0, start: 0.0, },
    row,
  )
  let root = @moonui.Widget::stack(b, [placed, slider.opacity(0.01)])
  { root, blocks, on, off, last: -1, }
}

///|
/// 按千分位点亮：0..1000 → 0..n 颗。
pub fn[B] CmBar::set_permille(
  self : CmBar[B],
  v : Int32,
) -> Unit raise @moonui.UiError {
  let n = self.blocks.length()
  let mut lit = v * n / 1000
  if lit < 0 {
    lit = 0
  }
  if lit > n {
    lit = n
  }
  if self.last == lit {
    return
  }
  self.last = lit
  for i = 0; i < n; i = i + 1 {
    let _ = self.blocks[i].set_style(
      Some(
        @moonui.style(background=Some(if i < lit { self.on } else { self.off })),
      ),
    )
  }
}

///|
/// 扁平皮肤：显式给底色+字色+字号（原生 Button 在显式给过背景时摘掉系统 bezel、
/// 改画平面底，与Luna的圆角小钮同形；圆角不一定吃，给了不碍事）。
fn[B] cm_btn_skin(
  btn : @moonui.Widget[B],
  bg : @moonui.Color,
  fg : @moonui.Color,
  size : Double,
) -> Unit raise @moonui.UiError {
  let _ = btn.set_style(
    Some(
      @moonui.style(
        background=Some(bg),
        foreground=Some(fg),
        font_size=Some(size),
        radius=Some(2.0),
      ),
    ),
  )
}

///|
/// 建主控面板。走带/进度/音量的接线全转发给 player 侧回调；PL/EQ/LRC 三个小
/// 开关转发给 app（显示/隐藏对应伴窗）。
pub fn[B : @moonui.Backend] PlayBar::new(
  b : B,
  on_prev : () -> Unit,
  on_toggle : () -> Unit,
  on_stop : () -> Unit,
  on_next : () -> Unit,
  on_seek : (Int32) -> Unit,
  on_mode : () -> Unit,
  on_volume : (Int32) -> Unit,
  on_toggle_pl : () -> Unit,
  on_toggle_eq : () -> Unit,
  on_toggle_lrc : () -> Unit,
  on_fav : () -> Unit,
) -> PlayBar[B] raise @moonui.UiError {
  // ——① 信息条：歌名（左撑满）+ 歌手 - 专辑（右）——
  let title = @moonui.Widget::label(b, "未播放")
    .foreground(cm_face_text())
    .font_size(12.0)
    .font_weight(Bold)
  let artist = @moonui.Widget::label(b, "")
    .foreground(cm_face_text())
    .font_size(10.0)
  // 收藏 ♡：定宽小钮（宽度照例走 Sized，不用只写样式的 .width()）
  let fav = @moonui.Widget::button(b, "♡")
  cm_btn_skin(fav, cm_face_light(), cm_face_text(), 11.0)
  let fav_box = @moonui.Widget::sized(b, Some(24.0), Some(16.0), fav)
  let info_row = @moonui.Widget::row(b, 8.0, [
    title.with_expand(true),
    artist,
    fav_box,
  ])
  let info_panel = @moonui.Widget::panel(
    b,
    @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(2.0, 8.0),
      info_row,
    ),
  )
  let _ = info_panel.set_style(
    Some(@moonui.style(background=Some(cm_face_light()))),
  )
  let info_band = cm_band(b, cm_info_h(), info_panel)

  // ——② 脸面：渐变底 + （左）频谱窗（右）大字时间/立体声/状态——
  let viz = Spectrum::new(b, 88.0, cm_face_h() - 20.0)
  let time_big = @moonui.Widget::label(b, "00:00")
    .foreground(cm_text_light())
    .font_size(26.0)
    .font_weight(Bold)
  let time_total = @moonui.Widget::label(b, "/ --:--")
    .foreground(cm_text_light())
    .font_size(10.0)
  let time_row = @moonui.Widget::row(b, 6.0, [
    time_big,
    time_total,
    @moonui.Widget::spacer(b).with_expand(true),
  ])
  let stereo = @moonui.Widget::label(b, "立体声")
    .foreground(cm_text_light())
    .font_size(9.0)
  let music_win = @moonui.Widget::label(b, "♪ 音乐窗")
    .foreground(cm_text_light())
    .font_size(9.0)
  let stereo_row = @moonui.Widget::row(b, 6.0, [
    stereo,
    @moonui.Widget::spacer(b).with_expand(true),
    music_win,
  ])
  let state_text = @moonui.Widget::label(b, "状态: 就绪")
    .foreground(cm_text_light())
    .font_size(9.0)
  let status_col = @moonui.Widget::column(b, 1.0, [
    time_row, stereo_row, state_text,
  ]).with_expand(true)
  let face_row = @moonui.Widget::row(b, 10.0, [viz.root, status_col])
  let face_body = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(6.0, 8.0),
    face_row,
  )
  // 光泽：定长条带铺一层垂直渐变当背板，内容用 Stack 浮在上面。
  // Stack 只在这一处出现，且外面用 sized 锁死高度——没有无界上限，条带与
  // 内容都不会被量成 1e18。
  let face_bg = @moonui.Widget::gradient_panel(
    b,
    @moonui.Gradient::vertical(cm_face_top(), cm_face_bottom()),
    total=cm_face_h(),
    bands=34,
  )
  let face = @moonui.Widget::stack(b, [face_bg, face_body])
  let face_band = @moonui.Widget::sized(b, None, Some(cm_face_h()), face)

  // ——③ 播放进度（原生滑块给固有高度，外面只包一层定高带）——
  let progress = @moonui.Widget::slider(b, 0, 1000)
  // Windows 半的滑块必须自己画（`T132`）：mac 半靠下面 `CmBar` 把原生滑块蒙成
  // opacity 0.01、画面交给那排方块，Windows 的子窗口做不了分层（系统拒绝
  // WS_EX_LAYERED），蒙版是 no-op——系统轨道条（COLOR_BTNFACE 底 + 主题蓝钮）
  // 整块盖住方块，界面上就是一块灰白补丁。底色给"这条带自身的色"、前景给
  // CmBar 的 on 色，自绘出来与周围读成一体。
  // 写在 `CmBar::new` **之前**：蒙版是在那里面叠上去的（`layer_local` 只叠给出
  // 的字段、保留已有覆盖），顺序反过来 `set_style` 会整份替换、把蒙版抹掉。
  let _ = progress.set_style(
    Some(
      @moonui.style(
        background=Some(cm_face_bottom()),
        foreground=Some(cm_accent()),
      ),
    ),
  )
  // 384 = 380 - 两侧 6px 内边距；46 颗方块每颗约 8px
  let prog_bar = CmBar::new(
    b,
    progress,
    46,
    368.0,
    7.0,
    6.5,
    cm_accent(),
    cm_bevel_lo(),
  )
  let prog_row = @moonui.Widget::row(b, 0.0, [prog_bar.root.with_expand(true)])
  let prog_inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(0.0, 6.0),
    prog_row,
  )
  let prog_panel = @moonui.Widget::panel(b, prog_inner)
  // 进度带用脸面底色收尾：它读起来是"脸面的最后一条"，而不是与走带连成
  // 一块 58px 的整蓝板（上一版两段同色，走带完全糊在背景里）。
  let _ = prog_panel.set_style(
    Some(@moonui.style(background=Some(cm_face_bottom()))),
  )
  let prog_band = cm_band(b, cm_prog_h(), prog_panel)

  // ——④ 走带：上一首 / 播放·暂停 / 停止 / 下一首 + 音量 + PL·EQ·LRC + 模式——
  let prev = @moonui.Widget::button(b, "⏮")
  let toggle = @moonui.Widget::button(b, "▶")
  let stop = @moonui.Widget::button(b, "⏹")
  let next = @moonui.Widget::button(b, "⏭")
  cm_btn_skin(prev, cm_btn_bg(), cm_text_light(), 12.0)
  cm_btn_skin(toggle, cm_accent(), cm_text_light(), 14.0)
  cm_btn_skin(stop, cm_btn_bg(), cm_text_light(), 12.0)
  cm_btn_skin(next, cm_btn_bg(), cm_text_light(), 12.0)
  let volume = @moonui.Widget::slider(b, 0, 1000)
  let _ = volume.set_value(1000)
  // 同上（`T132`）：音量条所在那条带的底色是 `cm_transport_bg()`。同样写在
  // `CmBar::new` 之前，让蒙版叠在这两格颜色上。
  let _ = volume.set_style(
    Some(
      @moonui.style(
        background=Some(cm_transport_bg()),
        foreground=Some(cm_accent()),
      ),
    ),
  )
  let vol_bar = CmBar::new(
    b,
    volume,
    16,
    64.0,
    8.0,
    5.0,
    cm_accent(),
    cm_bevel_lo(),
  )
  let pl = @moonui.Widget::button(b, "PL")
  let eq = @moonui.Widget::button(b, "EQ")
  let lrc = @moonui.Widget::button(b, "LRC")
  cm_btn_skin(pl, cm_btn_bg(), cm_text_light(), 9.0)
  cm_btn_skin(eq, cm_btn_bg(), cm_text_light(), 9.0)
  cm_btn_skin(lrc, cm_btn_bg(), cm_text_light(), 9.0)
  // 模式钮是纯图标钮（原版那颗循环/随机箭头）：文字与图标同占一个原生钮时
  // 会**叠在一起**（图标画在文字上），所以文字留空，标签由 refresh_bar 只换图标。
  let mode = @moonui.Widget::button(b, "")
  cm_btn_skin(mode, cm_btn_bg(), cm_text_light(), 9.0)
  // 宽度一律走 Sized 通道：`Widget::width()` 只写样式（§15 的样式不进布局账），
  // 用它定宽会让按钮保持固有宽，整排溢出窗口右缘（上一版 PL/EQ/LRC 被挤到 457px）。
  // 高度也定死：原生钮的固有高在 15~17 之间飘（字体/字号不同高不一样），不定高
  // 这一排就高低不齐，读起来不像一条走带。
  let fix = fn(
    w : Double,
    h : Double,
    wt : @moonui.Widget[B],
  ) -> @moonui.Widget[B] raise @moonui.UiError {
    @moonui.Widget::sized(b, Some(w), Some(h), wt)
  }
  let transport = @moonui.Widget::row(b, 3.0, [
    fix(24.0, 18.0, prev),
    fix(30.0, 18.0, toggle),
    fix(24.0, 18.0, stop),
    fix(24.0, 18.0, next),
    @moonui.Widget::spacer(b).with_expand(true),
    fix(64.0, 18.0, vol_bar.root),
    @moonui.Widget::spacer(b).with_expand(true),
    fix(24.0, 14.0, pl),
    fix(24.0, 14.0, eq),
    fix(28.0, 14.0, lrc),
    fix(24.0, 14.0, mode),
  ])
  let transport_inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(3.0, 8.0),
    transport,
  )
  let transport_panel = @moonui.Widget::panel(b, transport_inner)
  let _ = transport_panel.set_style(
    Some(@moonui.style(background=Some(cm_transport_bg()))),
  )
  let transport_band = cm_band(b, cm_transport_h(), transport_panel)

  // ——竖拼：五段定高之和 = 窗口内容高（cm_main_h）——
  let root = @moonui.Widget::column(b, 0.0, [
    info_band, face_band, prog_band, transport_band,
  ])
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_page_bg()))))

  // 图标（mac 走 SF Symbols；取不到就保持文字兜底）
  let _ = prev.set_icon("backward.fill")
  let _ = toggle.set_icon("play.fill")
  let _ = stop.set_icon("stop.fill")
  let _ = next.set_icon("forward.fill")
  // 接线：闭包只做转发，状态迁移全在 player
  let _ = prev.with_on_click(fn() { on_prev() })
  let _ = toggle.with_on_click(fn() { on_toggle() })
  let _ = stop.with_on_click(fn() { on_stop() })
  let _ = next.with_on_click(fn() { on_next() })
  let _ = mode.with_on_click(fn() { on_mode() })
  let _ = pl.with_on_click(fn() { on_toggle_pl() })
  let _ = eq.with_on_click(fn() { on_toggle_eq() })
  let _ = lrc.with_on_click(fn() { on_toggle_lrc() })
  let _ = fav.with_on_click(fn() { on_fav() })
  let _ = progress.with_on_change(fn() -> Unit raise @moonui.UiError {
    on_seek(progress.value())
  })
  let _ = volume.with_on_change(fn() -> Unit raise @moonui.UiError {
    on_volume(volume.value())
  })
  {
    root,
    title,
    artist,
    viz,
    time_big,
    time_total,
    state_text,
    prev,
    toggle,
    stop,
    next,
    progress,
    prog_bar,
    mode,
    volume,
    vol_bar,
    pl,
    eq,
    lrc,
    fav,
  }
}
