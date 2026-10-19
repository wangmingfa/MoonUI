///|
/// 均衡器面板（Luna「EQ」窗的真身，第二期）。
///
/// 上一版那八根柱子是**画**出来的（高度写死，拖不动也不进音频链路），这一版
/// 每一段都是真滑块：拖动 → `AudioEngine::eq_apply` → 原生层 AVAudioUnitEQ 的
/// 对应段改增益（mac 半）。预设是一张 MoonBit 侧的表（见 `eq_presets`），
/// 选一项就把十段一次性推下去——C 侧不认识"流行/摇滚"这种名字。
///
/// 段数为 0（Windows 半没有 EQ）时不画滑块，只写一行说明：宁可空着，也不摆
/// 一排拖了没反应的假控件（这是上一版被点名的那条）。
pub(all) struct EqPanel[B] {
  root : @moonui.Widget[B]
  /// 每段一只滑块（千分位 0..1000，中点 500 = 0dB）
  sliders : Array[@moonui.Widget[B]]
  /// 每段右边的增益读数（+3.2dB 这种）
  gains : Array[@moonui.Widget[B]]
  preset : @moonui.Widget[B]
  enable : @moonui.Widget[B]
}

///|
/// 十段中心频率（与原生层 AVAudioUnitEQ 的那张表一致，adapter.h 均衡器段）。
pub fn cm_eq_freqs() -> Array[String] {
  ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
}

///|
/// 预设表：名字 + 十段增益（**千分位** 0..1000，500 = 0dB，一天 24 的换算
/// 见 `gain_mdb_of` / `permille_of`）。数值取常见十段图示均衡器的形状，
/// 不是从哪个产品抄的精确曲线。
pub fn eq_presets() -> Array[(String, Array[Int32])] {
  [
    ("平直", [500, 500, 500, 500, 500, 500, 500, 500, 500, 500]),
    ("流行", [560, 600, 620, 560, 480, 470, 480, 520, 520, 520]),
    ("摇滚", [620, 640, 580, 480, 420, 440, 520, 600, 620, 620]),
    ("古典", [480, 500, 520, 520, 520, 540, 540, 560, 560, 560]),
    ("爵士", [540, 560, 540, 500, 480, 500, 540, 580, 580, 560]),
    ("电子", [640, 660, 600, 500, 460, 460, 500, 560, 640, 660]),
    ("人声", [440, 460, 520, 560, 600, 580, 520, 480, 460, 460]),
    ("重低音", [700, 660, 600, 520, 480, 460, 460, 460, 460, 460]),
  ]
}

///|
/// 千分位 → milli-dB（±12000 = ±12dB）：滑块中点 500 是 0dB，两端 ±12dB。
pub fn gain_mdb_of(permille : Int32) -> Int32 {
  (permille - 500) * 24
}

///|
/// milli-dB → 千分位（`gain_mdb_of` 的逆）。
pub fn permille_of(gain_mdb : Int32) -> Int32 {
  gain_mdb / 24 + 500
}

///|
/// 增益读数：milli-dB → "+3.2" / "-6.0" / "0.0"。
pub fn gain_text(gain_mdb : Int32) -> String {
  let sign = if gain_mdb < 0 { "-" } else { "+" }
  let a = if gain_mdb < 0 { -gain_mdb } else { gain_mdb }
  let whole = a / 1000
  let tenth = a % 1000 / 100
  "\{sign}\{whole}.\{tenth}dB"
}

///|
/// 建均衡器面板。count = 引擎的段数（0 = 本平台没有 EQ）；bands 是当下的十段
/// 增益（千分位）。回调都收在参数里，状态在 app 那侧。
pub fn[B : @moonui.Backend] EqPanel::new(
  b : B,
  count : Int32,
  bands : Array[Int32],
  enabled : Bool,
  on_band : (Int32, Int32) -> Unit,
  on_preset : (Int32) -> Unit,
  on_enable : (Bool) -> Unit,
) -> EqPanel[B] raise @moonui.UiError {
  let enable = @moonui.Widget::checkbox(b, "启用均衡器", enabled).foreground(
    cm_text_light(),
  )
  let _ = enable.with_on_change(fn() {
    on_enable(enable.checked() catch { _ => false })
  })
  let preset = @moonui.Widget::combobox(b, eq_presets().map(fn(p) { p.0 }))
  let _ = preset.with_on_change(fn() {
    on_preset(preset.selected() catch { _ => 0 })
  })
  // 标题不在这里：伴窗统一由顶条写（`CmStrip`），窗口里再写一遍就重了。
  let head = @moonui.Widget::row(b, 8.0, [
    @moonui.Widget::spacer(b).with_expand(true),
    enable,
    @moonui.Widget::sized(b, Some(90.0), Some(22.0), preset),
  ])
  // 没有 EQ 的平台：不画滑块，只留一行说明
  if count <= 0 {
    let note = @moonui.Widget::label(
        b, "本平台没有均衡器（音频链路未接入 EQ）",
      )
      .foreground(cm_text_light())
      .font_size(11.0)
    let body = @moonui.Widget::column(b, 10.0, [head, note])
    let padded = @moonui.Widget::padding(
      b,
      @moonui.EdgeInsets::symmetric(12.0, 16.0),
      body,
    )
    let root = @moonui.Widget::panel(b, padded)
    let _ = root.set_style(
      Some(@moonui.style(background=Some(cm_titlebar_bg()))),
    )
    return { root, sliders: [], gains: [], preset, enable, }
  }
  let freqs = cm_eq_freqs()
  let sliders : Array[@moonui.Widget[B]] = []
  let gains : Array[@moonui.Widget[B]] = []
  let cols : Array[@moonui.Widget[B]] = []
  for i = 0; i < count; i = i + 1 {
    let name = if i < freqs.length() { freqs[i] } else { "\{i + 1}" }
    let freq_lbl = @moonui.Widget::label(b, "\{name}Hz")
      .foreground(cm_lyric_dim())
      .font_size(9.0)
    let v = if i < bands.length() { bands[i] } else { 500 }
    let slider = @moonui.Widget::slider(b, 0, 1000)
    // 滑槽色与把手色（只对竖排生效）：槽比 well 的 `cm_inset` 亮一档、把手
    // 用浅色——失焦时系统那套会淡到只剩一个白圆点，这两样由宿主自绘。
    let _ = slider.background(cm_face_bottom())
    let _ = slider.foreground(cm_text_light())
    let _ = slider.set_value(v)
    let gain_lbl = @moonui.Widget::label(b, gain_text(gain_mdb_of(v)))
      .foreground(cm_text_light())
      .font_size(8.0)
    let _ = slider.with_on_change(fn() raise @moonui.UiError {
      let got = slider.value() catch { _ => 500 }
      let _ = gain_lbl.set_text(gain_text(gain_mdb_of(got)))
      on_band(i, got)
    })
    sliders.push(slider)
    gains.push(gain_lbl)
    // 一段 = 上面读数 / 中间竖推子（吃掉剩余高度） / 下面频率。推子定宽 26，
    // 高度交给布局——`MoonuiNativeSliderHost` 一看到"高 > 宽"就把里面那颗
    // NSSlider 按竖排重建（NSSlider 的朝向在 init 时定死，改 frame 改不回来）。
    // 竖排时宿主还会在滑块底下垫一条自绘滑槽：系统轨道失焦就淡没了，槽不能
    // 跟着焦点走（见 adapter_native.m 的 `MoonuiNativeSliderHost`）。
    let seg = @moonui.Widget::column(b, 4.0, [
      @moonui.Widget::sized(b, None, Some(11.0), gain_lbl),
      @moonui.Widget::sized(b, Some(26.0), None, slider).with_expand(true),
      @moonui.Widget::sized(b, None, Some(11.0), freq_lbl),
    ])
    cols.push(@moonui.Widget::sized(b, Some(34.0), None, seg))
  }
  let faders = @moonui.Widget::row(b, 0.0, cols)
  // 推子区做成凹陷的深底（Winamp 的 EQ 就是一块深色槽），外圈 1px 暗线 + 内衬
  // `inset`，两侧留一点余量让十段匀开。
  let well_inner = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(6.0, 6.0),
    faders,
  )
  let well = @moonui.Widget::panel(b, well_inner)
  let _ = well.set_style(Some(@moonui.style(background=Some(cm_inset()))))
  let well_frame = @moonui.Widget::panel(
    b,
    @moonui.Widget::padding(b, @moonui.EdgeInsets::all(1.0), well),
  )
  let _ = well_frame.set_style(
    Some(@moonui.style(background=Some(cm_bevel_lo()))),
  )
  let body = @moonui.Widget::column(b, 6.0, [
    head,
    @moonui.Widget::sized(b, None, None, well_frame).with_expand(true),
  ])
  let padded = @moonui.Widget::padding(
    b,
    @moonui.EdgeInsets::symmetric(8.0, 10.0),
    body,
  )
  let root = @moonui.Widget::panel(b, padded)
  let _ = root.set_style(Some(@moonui.style(background=Some(cm_page_bg()))))
  { root, sliders, gains, preset, enable, }
}

///|
/// 预设落地后把十段滑块与读数一起刷回去（不重建树）。
pub fn[B : @moonui.Backend] EqPanel::set_bands(
  self : EqPanel[B],
  bands : Array[Int32],
) -> Unit raise @moonui.UiError {
  for i = 0; i < self.sliders.length(); i = i + 1 {
    let v = if i < bands.length() { bands[i] } else { 500 }
    let _ = self.sliders[i].set_value(v)
    let _ = self.gains[i].set_text(gain_text(gain_mdb_of(v)))
  }
}
