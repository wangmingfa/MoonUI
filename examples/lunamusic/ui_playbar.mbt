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
  /// 音量百分比读数（`T146`）：悬在音量条上才出现，离开就收起
  vol_pct : @moonui.Widget[B]
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
/// 频谱可视化（Luna脸面左侧那块）：16 根**连续可变高度**的竖条，段能量来自
/// **真实音频**（原生层在混音器输出上装 tap 做 FFT，见 adapter.h 频谱段），
/// 由 app.refresh_spectrum 每帧把 16 个千分位读数灌进来。
///
/// `T155` 之前是"16 段 × 7 颗定高小方块、靠换底色表达高低"——那不是频谱，
/// 是把频谱量化成 7 档的色条：柱子只能一格一格跳，冲上去和落下来都是台阶。
/// 根子在旧路子里**画的高度只能由布局尺寸决定**（`Widget::sized` 只在建树时
/// 生效），而框架没有运行期改尺寸的通道。现在换成 `Widget::custom`（`T101`）：
/// 整块可视窗就是**一只自绘面**，每帧重画一遍 `DrawList`，柱高是连续的浮点数，
/// 想画多高就画多高。
///
/// 平滑靠"显示值追目标值"的指数逼近（`bars` 是显示值，引擎读数换算的
/// `target` 是目标）：**上升快、回落慢**——起音 40ms 量级，落音 260ms 量级，
/// 这是频谱条看着"有弹性"而不是"跟着数字抽搐"的关键。系数按**实测帧间隔**
/// 算（`dt/(dt+tau)`，与 `1-exp(-dt/tau)` 同形且不需要指数函数），所以帧率
/// 抖了、测试里 dt 给大了，动画的时间尺度都不变。
pub(all) struct Spectrum[B] {
  root : @moonui.Widget[B]
  /// 自绘可视窗（唯一会重画的那块）
  face : @moonui.Widget[B]
  /// 每段当前**显示**的高度（0..1）；`paint_spectrum` 只读它
  bars : Array[Double]
}

///|
/// 段数（= 原生层 FFT 的对数分桶数，两边必须一致；改一处就得改另一处）。
pub fn cm_viz_bands() -> Int32 {
  16
}

///|
/// 显示值逼近目标值的时间常数（毫秒）：起音短、落音长。
const CM_VIZ_ATTACK_MS : Double = 40.0

///|
const CM_VIZ_RELEASE_MS : Double = 260.0

///|
/// 相邻两段的水平缝隙（逻辑像素）
const CM_VIZ_GAP : Double = 1.0

///|
/// 渐变底端比柱色提亮多少（`cm_lighten` 的 k）
const CM_VIZ_HI_MIX : Double = 0.35

///|
/// 自绘配方要的那几样（绘制回调只能捕获值，不能读皮肤——皮肤换了整树重建）。
///
/// `bar` 是柱色（渐变顶端那档），`bar_hi` 是它提亮 `hi_mix` 之后的一档（渐变
/// 底端）。两档都由同一条 `cm_lighten` 算出来，绘制的换算与这里的定义才对得上。
priv struct SpectrumLook {
  bar : Int32
  bar_hi : Int32
  hi_mix : Double
  gap : Double
}

///|
pub fn[B : @moonui.Backend] Spectrum::new(
  b : B,
  w : Double,
  h : Double,
) -> Spectrum[B] raise @moonui.UiError {
  let bands = cm_viz_bands()
  let bars : Array[Double] = []
  for _i = 0; _i < bands; _i = _i + 1 {
    bars.push(0.0)
  }
  let look = SpectrumLook::{
    bar: cm_bar_rgb(),
    bar_hi: cm_lighten(cm_bar_rgb(), CM_VIZ_HI_MIX),
    hi_mix: CM_VIZ_HI_MIX,
    gap: CM_VIZ_GAP,
  }
  let face = @moonui.Widget::custom(b, @moonui.LogicalSize(w, h), fn(dl, env) {
    paint_spectrum(bars, look, dl, env)
  })
  // 凹陷框：外面 1px 暗边 + 里面深底，读起来像嵌进面板里的一块玻璃（原版那种
  // "可视窗"）。`Style` 没有描边，所以暗边用一层 Padding 露出底色来当。
  let glass = @moonui.Widget::panel(
    b,
    @moonui.Widget::padding(b, @moonui.EdgeInsets::symmetric(4.0, 4.0), face),
  )
  let _ = glass.set_style(
    Some(@moonui.style(background=Some(cm_inset()), radius=Some(2.0))),
  )
  let framed = @moonui.Widget::padding(b, @moonui.EdgeInsets::all(1.0), glass)
  let root = @moonui.Widget::panel(b, framed)
  let _ = root.set_style(
    Some(@moonui.style(background=Some(cm_bevel_lo()), radius=Some(3.0))),
  )
  { root, face, bars, }
}

///|
/// 推进一帧：把 16 段能量（0..1000）换算成目标高度，显示值按 `dt_ms` 的实测
/// 帧间隔逼近。返回**还要不要下一帧**——调用方据此决定要不要续这一拍（都落定
/// 了就别再白唤醒主循环）。
///
/// 目标高度直接就是千分位（引擎那侧已经把 -60..0dB 映射成 0..1 了），不再做
/// 一次开方/对数：频谱的"感知线性"在 FFT 那一侧就做完了，这层再加一次只会
/// 让低段全贴底。
pub fn[B : @moonui.Backend] Spectrum::update(
  self : Spectrum[B],
  levels : Array[Int32],
  dt_ms : Int32,
) -> Bool raise @moonui.UiError {
  let dt = if dt_ms > 0 { dt_ms.to_double() } else { 1.0 }
  let mut moving = false
  let mut changed = false
  for bi = 0; bi < self.bars.length(); bi = bi + 1 {
    let lv = if bi < levels.length() { levels[bi] } else { 0 }
    let target = (lv.to_double() / 1000.0).clamp(min=0.0, max=1.0)
    let from = self.bars[bi]
    let tau = if target > from { CM_VIZ_ATTACK_MS } else { CM_VIZ_RELEASE_MS }
    let k = dt / (dt + tau)
    let next = if (target - from).abs() < 0.002 {
      // 贴到位就**落定**：不落定的话每一帧都在逼近、永远差一点点，这条链
      // 就再也停不下来（0.999 与 1.0 在屏幕上没有区别，账上却差着一帧）。
      target
    } else {
      from + (target - from) * k
    }
    if next != from {
      changed = true
    }
    self.bars[bi] = next
    if next != target {
      moving = true
    }
  }
  // 重画的判据是"这一帧的值变了"，**不是**"还要继续动"：落定那一帧值也要
  // 落画布上（否则最后画出去的是差 0.002 的那一份，柱子永远差一小截）。
  if changed {
    self.face.repaint()
  }
  moving
}

///|
/// 当前显示值（判据读口，也便于调试时肉眼对账）。
pub fn[B] Spectrum::bars(self : Spectrum[B]) -> Array[Double] {
  self.bars
}

///|
/// 一帧频谱的绘制配方：每段一根从底边长上来的竖条，渐变**按整块面**锚定
/// （底亮顶暗），柱子长到哪儿就吃到渐变的那一段——所以高柱的顶偏暗、矮柱的
/// 顶偏亮，整块看着像从基线往上发光。
///
/// 为什么渐变不按每根柱子自己的矩形铺满：那样每根柱子的顶端都落在渐变起点，
/// 一柱一亮点，看着像一排"带亮边的方块"——正是要摆脱的那种格子感。
///
/// 不为此开 `save`/`clip_rect`：把整块面的两档色按柱高换算成本地两档，
/// 一次 `fill_linear` 就是同一个结果，省掉每帧 16 组状态栈进出（那在
/// 自绘后端上是真的 CG 状态栈操作）。
///
/// 柱高是**连续**的浮点数（`env.height() * v`），没有档位；矮到半像素以下
/// 才不画——那是屏幕放不出来的高度，不是"一格"。
fn paint_spectrum(
  bars : Array[Double],
  look : SpectrumLook,
  dl : @moonui.DrawList,
  env : @moonui.PaintEnv,
) -> Unit {
  let n = bars.length()
  let w = env.width()
  let h = env.height()
  if n == 0 || w <= 0.0 || h <= 0.0 {
    return
  }
  let slot = w / n.to_double()
  let bw = slot - look.gap
  if bw <= 0.0 {
    return
  }
  for i, raw in bars {
    let v = raw.clamp(min=0.0, max=1.0)
    let bh = h * v
    if bh < 0.5 {
      continue
    }
    let x = slot * i.to_double()
    // 面的整高渐变：顶 = 原色、底 = 高光。柱子在 [1-v, 1] 这一段上，换算成
    // 这根柱子自己的两档就是 lighten(原色, 0.35×(1-v)) → 高光。
    let top = cm_lighten(look.bar, look.hi_mix * (1.0 - v))
    dl.fill_linear(x, h - bh, bw, bh, stops=[(0.0, top), (1.0, look.bar_hi)])
  }
}

///|
/// 往白色方向提一档（`k` = 0 原色、1 全白），给柱子上缘那道高光用。
fn cm_lighten(v : Int32, k : Double) -> Int32 {
  (cm_chan_up((v >> 16) & 255, k) << 16) |
  (cm_chan_up((v >> 8) & 255, k) << 8) |
  cm_chan_up(v & 255, k)
}

///|
fn cm_chan_up(c : Int32, k : Double) -> Int32 {
  let v = c.to_double() + (255.0 - c.to_double()) * k
  if v > 255.0 {
    255
  } else if v < 0.0 {
    0
  } else {
    v.to_int()
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
  let hi = @moonui.Widget::sized(b, None, Some(1.0), cm_bevel(b, cm_bevel_hi()))
  let mid = @moonui.Widget::sized(b, None, Some(h - 2.0), content)
  let lo = @moonui.Widget::sized(b, None, Some(1.0), cm_bevel(b, cm_bevel_lo()))
  let col = @moonui.Widget::column(b, 0.0, [hi, mid, lo])
  @moonui.Widget::sized(b, None, Some(h), col)
}

///|
/// 一条 1px 的亮线 / 暗线（`cm_band` 的上下缘）。
///
/// 里面必须揣一个**撑得满交叉轴**的子项：`sized(..., None, Some(1.0), …)` 的
/// 宽度取的是子项固有宽，而 `Panel` 里放 `Spacer` 的固有宽是 0，`layout_line`
/// 又只在 `flex` / `fill_cross` 时才把子项铺满交叉轴——于是这两条线一直量成
/// 0 宽、一条也没画出来（`T134`：相邻条带之间那 1~3px 未落笔的像素正是这两行；
/// 沉浸式窗的客户区又不擦背景，DWM 就把窗口后面的内容透了出来）。所以揣一个
/// `expand` 的 `Spacer` 进 `Row`：`measure` 拿到 `c.max`，线就跟着条带满宽。
fn[B : @moonui.Backend] cm_bevel(
  b : B,
  c : @moonui.Color,
) -> @moonui.Widget[B] raise @moonui.UiError {
  @moonui.Widget::panel(
    b,
    @moonui.Widget::row(b, 0.0, [@moonui.Widget::spacer(b).with_expand(true)]),
  ).background(c)
}

///|
/// 进度条/音量条：原生 Slider 管**拖动**，画面则分两层给。
///
/// 两个原生后端都由 C 自己画整条带（`T147②`）：macOS 半
/// `MoonuiNativeSliderHost drawRect:` 的横排自绘分支、Windows 半
/// `moonui_native_slider_paint`，两边同一条规则——整块矩形先铺条带底色，
/// 再画一根"整高三分之一、夹在 3..10、两端圆头"的圆角槽，槽里画已走过那段
/// （同样圆头），最上面压一颗 12pt 圆点。拖动期间的每一帧都是这层在画，所以
/// 圆点跟着指针连续走，不是一格一格跳（`T147③`）。
///
/// 下面这排方块与那颗圆 Panel 是**同一张画的 Core 版**，给没有 C 自绘通道的
/// 后端（`CanvasBackend` 的 `Slider` 配方、MockBackend 的判据）留的：两个原生
/// 后端上它们整块压在 C 的底色下面，看不见也接不到鼠标。
///
/// 顺带一处必须知道的后果：`set_permille` 每拍仍会给那 n 颗方块各推一次
/// `set_style`（原生后端上它们被盖住，纯属白推）。这条留着的理由是 canvas
/// 那支还要它；等 canvas 也改成整条自绘，这一层才能整个拆掉。
///
/// 为什么是"方块"而不是一条可伸缩的填充：框架没有运行期改尺寸的通道
/// （`sized` 只在建树时生效），所以用 n 颗定宽方块换底色表达进度——与频谱同一
/// 套手法。
///
/// 圆点（`T146`）：方块行只分 n 档，读不出"这条能拖"，所以再压一颗比方块行
/// 高的圆，位置按千分位连续走。圆点排在**滑块下面**（Stack 数组顺序 = 绘制
/// 顺序，靠后的在上），于是它一点鼠标都接不到——命中永远落在最上面那只原生
/// 滑块上，拖动语义一点不变。
pub(all) struct CmBar[B] {
  root : @moonui.Widget[B]
  blocks : Array[@moonui.Widget[B]]
  /// 拖动圆点：定宽的 Panel 圆，位置靠 `margin` 推（`set_style` 会标脏重排）
  knob : @moonui.Widget[B]
  /// 几何账：`bar_w` 是方块行宽（= Stack 的宽），`block_h`/`pad_top` 定方块行
  /// 在带里的落点，`knob_d` 是圆点直径。圆点的叠放位置由前三个算出来。
  bar_w : Double
  block_h : Double
  pad_top : Double
  knob_d : Double
  on : @moonui.Color
  off : @moonui.Color
  /// 上一次点亮了几颗：只改变化的那几颗
  mut last : Int32
  /// 上一次圆点落在哪个千分位：方块按 n 档跳，圆点逐格走
  mut last_pm : Int32
}

///|
/// 建一条：n 颗方块横排，每颗 `w/n` 宽、h 高，`pad_top` 把整排压到带的中间；
/// `slider` 是叠在方块与圆点**上面**、独占命中与拖动的那只原生滑块；
/// `knob_d`/`knob` 是拖动圆点的直径与颜色。
pub fn[B : @moonui.Backend] CmBar::new(
  b : B,
  slider : @moonui.Widget[B],
  n : Int32,
  w : Double,
  h : Double,
  pad_top : Double,
  knob_d : Double,
  knob : @moonui.Color,
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
  // 拖动圆点：定宽的圆 Panel。位置靠**外边距**推——`Stack` 的子项共用原点，
  // 而 margin 是真正进布局的一圈（`set_style` 标脏 → 下一轮 step 重排），这是
  // 框架里唯一能在运行期挪动一个小方块的办法（`sized` 只在建树时生效）。
  let knob_cell = @moonui.Widget::panel(b, @moonui.Widget::spacer(b))
  let _ = knob_cell.set_style(
    Some(@moonui.style(background=Some(knob), radius=Some(knob_d / 2.0))),
  )
  let knob_w = @moonui.Widget::sized(b, Some(knob_d), Some(knob_d), knob_cell)
  let knob_top = pad_top + (h - knob_d) / 2.0
  let _ = knob_w.set_style(
    Some(
      @moonui.style(
        margin=Some(@moonui.EdgeInsets::{
          top: knob_top,
          end: 0.0,
          bottom: 0.0,
          start: (w - knob_d) / 2.0,
        }),
      ),
    ),
  )
  // 滑块必须与方块行**同宽**：`Stack` 只按各子项自己的尺寸摆放（不拉伸），
  // 原生滑块量到的是固有宽（约 193），方块行是 w（368）——右侧那截方块就从
  // 滑块底下露出来，成了一条没人管、也点不动的暗条（`T136`）。包一层定宽
  // 把它拉到方块行同宽：Windows 半滑块自绘整条槽，mac 半整条都可点可拖。
  // 高度不锁——滑块固有高比 `h + pad_top` 高，槽在带里的居中位置由它自己算。
  //
  // 蒙版撤掉（`T147②`）：原先这里叠 `opacity(0.01)`，让原生滑块"只剩拖动"、
  // 画面交给下面那排方块。现在整条带的画面由 C 画（macOS 半
  // `MoonuiNativeSliderHost drawRect:`、Windows 半 `moonui_native_slider_paint`），
  // 蒙在**宿主自己**身上就把它刚画的槽与圆点一起淡没了——所以这层必须去掉。
  //
  // 这层原本只在 mac 原生上真生效：Windows 的子窗口做不了分层（系统拒绝
  // `WS_EX_LAYERED`，`T89①`）、canvas 后端的 `set_widget_opacity` 是空实现
  // （`backends/canvas-macos/impl.mbt`）。所以撤掉它不改那两个后端的样子。
  let cover = @moonui.Widget::sized(b, Some(w), None, slider)
  // 顺序 = 绘制顺序，靠后的在上：圆点排在滑块**下面**，于是一点鼠标都接不到
  // （命中恒落在滑块上，拖动语义不动），只负责"这条能拖"的那一眼。
  let root = @moonui.Widget::stack(b, [placed, knob_w, cover])
  {
    root,
    blocks,
    knob: knob_w,
    bar_w: w,
    block_h: h,
    pad_top,
    knob_d,
    on,
    off,
    last: -1,
    last_pm: -1,
  }
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
  let mut pm = v
  if pm < 0 {
    pm = 0
  }
  if pm > 1000 {
    pm = 1000
  }
  // 圆点单独一笔账：方块按 n 档跳，圆点按千分位连续走。两笔各自"没变就不动"，
  // 所以走带每 500ms 的一次推送里最多只动真的变了的那一处。
  if self.last_pm != pm {
    self.last_pm = pm
    self.move_knob(pm)
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
/// 圆点落到千分位 `pm` 上（0..1000 已夹紧）：圆心压在"走了多少"的端点上，
/// 两端各让出半个直径，免得圆点探出条外。
fn[B] CmBar::move_knob(
  self : CmBar[B],
  pm : Int32,
) -> Unit raise @moonui.UiError {
  let travel = self.bar_w - self.knob_d
  let mut x = pm.to_double() * self.bar_w / 1000.0 - self.knob_d / 2.0
  if x < 0.0 {
    x = 0.0
  }
  if x > travel {
    x = travel
  }
  let _ = self.knob.set_style(
    Some(
      @moonui.style(
        margin=Some(@moonui.EdgeInsets::{
          top: self.pad_top + (self.block_h - self.knob_d) / 2.0,
          end: 0.0,
          bottom: 0.0,
          start: x,
        }),
      ),
    ),
  )
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
  // 底色/前景这两格是**C 自绘代的皮肤通道**（`T132`、`T147②`）：`background`
  // 是这条带自身的底色（C 先拿它铺满整块，再把槽压暗一档），`foreground` 是
  // "已走过那段"的颜色（= `CmBar` 的 on 色），自绘出来与周围读成一体。
  // 两个原生后端都吃这两格：Windows 半 `moonui_native_slider_paint`、macOS 半
  // `MoonuiNativeSliderHost drawRect:`。没给底色的滑块整条交回系统——画册、
  // EQ 的横排退化外观一点不变。
  let _ = progress.set_style(
    Some(
      @moonui.style(
        background=Some(cm_face_bottom()),
        foreground=Some(cm_accent()),
      ),
    ),
  )
  // 384 = 380 - 两侧 6px 内边距；46 颗方块每颗约 8px
  //
  // 圆点直径 12（`T146`）：方块行只有 7 高，圆必须**明显高出这条**才读得出"能拖"。
  // 12 落在 22 的进度带里：带内 20 高，方块行占 6.5..13.5，圆点 4.0..16.0，上下
  // 都还有余量，不会探出带外。
  let prog_bar = CmBar::new(
    b,
    progress,
    46,
    368.0,
    7.0,
    6.5,
    12.0,
    cm_text_light(),
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
  // 同上（`T132`、`T147②`）：音量条所在那条带的底色是 `cm_transport_bg()`。
  // 两格色必须在 `CmBar::new` 之前写——C 的自绘判据要求两格都在，缺一格就
  // 整条交回系统（`moonui_native_widget_set_style` / `drawRect:` 的注）。
  let _ = volume.set_style(
    Some(
      @moonui.style(
        background=Some(cm_transport_bg()),
        foreground=Some(cm_accent()),
      ),
    ),
  )
  // 音量条同理（`T146`）：方块行 8 高，圆点 12，比行明显高一截。
  let vol_bar = CmBar::new(
    b,
    volume,
    16,
    64.0,
    8.0,
    5.0,
    12.0,
    cm_text_light(),
    cm_accent(),
    cm_bevel_lo(),
  )
  // 音量百分比（`T146`）：平时收起，鼠标进音量条才出现。定宽 30 是给"100%"留位
  // （9pt 字号下 `100%` 约 24 宽），不然读数一变成三位数就把后面那排按钮往右挤。
  let vol_pct = @moonui.Widget::label(b, "100%")
    .foreground(cm_text_light())
    .font_size(9.0)
  // 收起的读数**仍然占位**（布局不跳过不可见子项）——这是想要的：切换时后面那排
  // 按钮一动不动，只有这 30 宽里多/少一段字。
  let _ = vol_pct.set_visible(false)
  // 悬停开关只挂在这颗原生滑块上：`App::hover_track` 在 `MouseMove` 的目标换人时
  // 补发 `MouseEnter`/`MouseLeave`，而音量条整块矩形都归滑块自己接命中
  // （`hit_owner` 沿 superview 找到宿主），所以"指针进/出这条"就是"滑块的
  // 悬停目标换人"，不用另立一块热区。
  //
  // mac 上这条链要窗口开了 `acceptsMouseMovedEvents` 才有输入——`T146` 在
  // `moonui_native_window_new` 里补上（此前从未设过，纯光标移动在 mac 上一条
  // `MouseMove` 都不产，见 adapter.h 鼠标段注）。
  let _ = volume.on_any(fn(ev) raise @moonui.UiError {
    match ev {
      @moonui.MouseEnter(_) => vol_pct.set_visible(true)
      @moonui.MouseLeave(_) => vol_pct.set_visible(false)
      _ => ()
    }
  })
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
    // 百分比读数紧贴音量条右侧：定宽 30 占位恒定，切换可见性不会把后面那排
    // 按钮推来推去（布局不跳过不可见子项）。
    //
    // `T147①`：外面必须包一层 `Center`。Row 的交叉轴是**左上对齐**（`layout_line`
    // 把子项落在 `frame.origin` 上，不居中），所以 14 高的标签贴着 18 高的音量条
    // 顶端，读数比圆点矮半行——真窗上就是"80% 悬在半空"。居中之后这一格仍是
    // 30×18，占位账一分没变。
    fix(30.0, 18.0, @moonui.Widget::center(b, vol_pct)),
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
    vol_pct,
    pl,
    eq,
    lrc,
    fav,
  }
}
