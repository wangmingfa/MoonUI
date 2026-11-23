///|
/// 自绘控件套件的第一批判据（`T350`）：令牌、按钮、勾选框、开关、单选组。
///
/// 口径与 `widgets_test.mbt` 一致：全部跑在 `MockBackend` 上，断言的是"这一帧
/// 收到了什么命令、按什么参数"（像不像归后端，画了什么归这里）。交互一律用
/// `Widget::fire` 直接投事件——不用开事件循环，也就不会随泵的节拍漂。
///
/// mock 的文本度量是定死的（每字符 8 × 字号/12、粗体 ×1.25），所以下面那些
/// 尺寸期望值可以写死；换字体系统不会让这些判据变红。

///|
/// 取一条命令里的填充矩形（没有就失败）。
fn ui_test_fill(
  dl : @moonui.DrawList,
) -> (Double, Double, Double, Double, Double, Int32) {
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) => return (x, y, w, h, r, rgb)
      _ => ()
    }
  }
  abort("清单里没有填充矩形")
}

///|
/// 清单里第一条文本命令（没有就失败）。
fn ui_test_text(dl : @moonui.DrawList) -> (String, Double, Double, Int32) {
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(t, x, y, _, _, rgb) => return (t, x, y, rgb)
      _ => ()
    }
  }
  abort("清单里没有文本")
}

///|
/// 清单一共几条命令、其中填充几条、描边几条、线段几条——"画了几笔"这类判据
/// 只数个数，不逐条比参数。
fn ui_test_count(dl : @moonui.DrawList) -> (Int32, Int32, Int32, Int32) {
  let mut all = 0
  let mut fills = 0
  let mut strokes = 0
  let mut lines = 0
  for cmd in dl.commands() {
    all = all + 1
    match cmd {
      @moonui.FillRect(_, _, _, _, _, _, _) => fills = fills + 1
      @moonui.StrokeRect(_, _, _, _, _, _, _) => strokes = strokes + 1
      @moonui.Line(_, _, _, _, _, _) => lines = lines + 1
      _ => ()
    }
  }
  (all, fills, strokes, lines)
}

///|
test "UiTheme：深浅两族的悬停方向相反，混色在端点上精确" {
  let l = @widgets.UiTheme::light()
  let d = @widgets.UiTheme::dark()
  // 两族的底色本来就该站在亮度轴的两端
  assert_true(@widgets.ui_luminance(l.bg) > 0.9)
  assert_true(@widgets.ui_luminance(d.bg) < 0.15)
  // 浅色悬停"暗一格"、深色悬停"亮一格"——这是两族唯一不能共用的方向
  assert_true(
    @widgets.ui_luminance(l.surface_hover) < @widgets.ui_luminance(l.surface),
  )
  assert_true(
    @widgets.ui_luminance(d.surface_hover) > @widgets.ui_luminance(d.surface),
  )
  // 混色的端点必须精确（端点都不准，令牌里的过渡档就全歪一格）
  assert_eq(@widgets.ui_mix(0x000000, 0xFFFFFF, 0.0), 0x000000)
  assert_eq(@widgets.ui_mix(0x000000, 0xFFFFFF, 1.0), 0xFFFFFF)
  assert_eq(@widgets.ui_mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
  assert_eq(@widgets.ui_mix(0x101010, 0x202020, 0.5), 0x181818)
  // 越界夹住，不产生"比两端更极端"的颜色
  assert_eq(@widgets.ui_mix(0x101010, 0x202020, -3.0), 0x101010)
  assert_eq(@widgets.ui_mix(0x101010, 0x202020, 7.0), 0x202020)
  // 主按钮的字色跟着主色的亮度走：深蓝配白字
  let light_btn = @widgets.UiTheme::from_palette(@moonui.Theme::light_palette())
  assert_eq(light_btn.accent, 0x265CD0)
  assert_eq(light_btn.on_accent, 0xFFFFFF)
  assert_eq(light_btn.bg, 0xF8F8FA)
  // 反过来：浅黄主色配深字（否则白字糊在黄底上）
  let yellow = @widgets.UiTheme::from_palette(@moonui.Palette::{
    background: @moonui.Color::rgb(255, 255, 255),
    surface: @moonui.Color::rgb(255, 255, 255),
    text: @moonui.Color::rgb(20, 20, 20),
    accent: @moonui.Color::rgb(255, 224, 102),
    border: @moonui.Color::rgb(210, 210, 210),
  })
  assert_true(@widgets.ui_luminance(yellow.on_accent) < 0.2)
  // 三档尺寸：高度与内缩逐档递进，字号只有大小两档
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiSmall).height, 28.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiMedium).height, 32.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiLarge).height, 40.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiMedium).font, 13.0)
  assert_eq(@widgets.UiTheme::light().metrics(@widgets.UiLarge).font, 15.0)
}

///|
test "UiButton：按文案量宽，主按钮是主色底 + 白字" {
  let b = mock()
  let btn = @widgets.UiButton(b, "保存")
  let w = btn.widget()
  // mock 度量：2 字 × 8 × (13/12) × 1.25(粗) = 21.6667；加两侧 14 内缩是
  // 49.6667，仍小于"两倍高"的最小宽 64，所以宽取 64
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(64.0, 32.0))
  assert_eq(w.kind(), @moonui.WidgetKind::Custom)
  let dl = place(b, w)
  let (fx, fy, fw, fh, fr, frgb) = ui_test_fill(dl)
  assert_eq((fx, fy, fw, fh), (0.0, 0.0, 64.0, 32.0))
  assert_eq(fr, 8.0)
  assert_eq(frgb, 0x2B6CF0) // 浅色令牌的 accent
  let (text, _, _ty, rgb) = ui_test_text(dl)
  assert_eq(text, "保存")
  assert_eq(rgb, 0xFFFFFF) // on_accent
  // 主按钮没有描边：一条填充 + 一行字，就这两笔
  let (all, fills, strokes, _) = ui_test_count(dl)
  assert_eq((all, fills, strokes), (2, 1, 0))
}

///|
test "UiButton：悬停/按下各换一档底，禁用不再回调" {
  let b = mock()
  let btn = @widgets.UiButton(b, "保存")
  let w = btn.widget()
  let mut hits = 0
  btn.on_click(fn() { hits = hits + 1 })
  let dl0 = place(b, w)
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  // 悬停：底换成 accent_hover
  let _ = w.fire(@moonui.MouseEnter(target))
  let (_, _, _, _, _, hover_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(hover_rgb, 0x1E5FD9)
  // 按下：底换成 accent_active
  let _ = w.fire(
    @moonui.MouseDown(
      target,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(1.0, 1.0),
      @moonui.Mods::none(),
    ),
  )
  let (_, _, _, _, _, down_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(down_rgb, 0x1750BE)
  // 抬起 + 点击：回调一次；指针还停在上面，所以底色是悬停那一档
  let _ = w.fire(
    @moonui.MouseUp(
      target,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(1.0, 1.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_eq(hits, 1)
  let (_, _, _, _, _, still_hover) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(still_hover, 0x1E5FD9)
  // 指针离开：底色回到静息的 accent
  let _ = w.fire(@moonui.MouseLeave(target))
  let (_, _, _, _, _, rest_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(rest_rgb, 0x2B6CF0)
  // 空格也算一次（自绘面没有系统按钮的键盘翻译，这条是自己接的）
  let _ = w.fire(
    @moonui.KeyDown(target, @moonui.KeyPress::{
      key: " ",
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    }),
  )
  assert_eq(hits, 2)
  // 禁用：底色退到淡主色，点击与空格都不再进去
  btn.set_enabled(false)
  let (_, _, _, _, _, disabled_rgb) = ui_test_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(disabled_rgb, @widgets.ui_mix(0x2B6CF0, 0xFFFFFF, 0.72))
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  let _ = w.fire(
    @moonui.KeyDown(target, @moonui.KeyPress::{
      key: " ",
      ctrl: false,
      alt: false,
      shift: false,
      meta: false,
    }),
  )
  assert_eq(hits, 2)
  let _ = dl0
}

///|
test "UiButton：改文案按新字宽重算尺寸，幽灵档没有底" {
  let b = mock()
  let btn = @widgets.UiButton(b, "好", kind=@widgets.UiGhost)
  let w = btn.widget()
  // 1 字与最小宽：还是 64（"好"撑不满两倍高）
  assert_eq(w.intrinsic_size().width, 64.0)
  // 7 个字：7 × 8 × (13/12) × 1.25 = 75.83；加两侧内缩 103.83，超过最小宽
  btn.set_label("保存并关闭窗口")
  assert_true(w.intrinsic_size().width > 100.0)
  let _ = w.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(400.0, 60.0),
    ),
  )
  let dl = b.drawn(w.handle().unwrap()).unwrap()
  // 幽灵档静息：没有填充、没有描边，只有一行字
  let (all, fills, strokes, _) = ui_test_count(dl)
  assert_eq((all, fills, strokes), (1, 0, 0))
}

///|
test "UiCheckbox：勾选画勾、未选只描边，点击翻面并回调" {
  let b = mock()
  let cb = @widgets.UiCheckbox(b, "记住我", checked=true)
  let w = cb.widget()
  // 方框 18 + 间距 8 + 三字 26 = 52，高取档高 32
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(52.0, 32.0))
  let events : Array[Bool] = []
  cb.on_change(fn(v) { events.push(v) })
  let dl = place(b, w)
  // 选中：方框底 + 两段勾 + 一行字 = 4 笔，没有描边
  let (all, fills, strokes, lines) = ui_test_count(dl)
  assert_eq((all, fills, strokes, lines), (4, 1, 0, 2))
  let (fx, fy, fw, fh, _, frgb) = ui_test_fill(dl)
  assert_eq((fx, fy, fw, fh), (0.0, 7.0, 18.0, 18.0))
  assert_eq(frgb, 0x2B6CF0)
  // 点击→取消勾选：方框换成面色 + 描一圈边，勾消失
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_false(cb.checked())
  assert_eq(events, [false])
  let dl2 = b.drawn(w.handle().unwrap()).unwrap()
  let (all2, fills2, strokes2, lines2) = ui_test_count(dl2)
  assert_eq((all2, fills2, strokes2, lines2), (3, 1, 1, 0))
  // 程序设值不回声
  cb.set_checked(true)
  assert_eq(events, [false])
  assert_true(cb.checked())
}

///|
test "UiCheckbox：禁用后点击不翻面" {
  let b = mock()
  let cb = @widgets.UiCheckbox(b, "同意", enabled=false)
  let w = cb.widget()
  let _ = place(b, w)
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_false(cb.checked())
}

///|
test "UiToggle：钮贴左/贴右，点一下翻面" {
  let b = mock()
  let tg = @widgets.UiToggle(b, "同步")
  let w = tg.widget()
  // 轨道高 22、宽 38.5；文案两字 17.33 + 间距 8 → 总宽 63.83，高取 32
  assert_eq(w.intrinsic_size().height, 32.0)
  assert_true(near(w.intrinsic_size().width, 38.5 + 8.0 + 17.333333))
  let dl = place(b, w)
  // 静息：轨道 + 钮影 + 钮 + 一行字
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (4, 3))
  // 钮在左：圆心 x = 半径 9 + 2 = 11，填充矩形的左边界是 11 - 9 = 2
  let (kx, _, kw, _, _, _) = ui_test_last_fill(dl)
  assert_true(near(kx + kw / 2.0, 11.0))
  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.Click(target, @moonui.MouseButton::Left))
  assert_true(tg.checked())
  // 钮在右：圆心 x = 38.5 − 9 − 2 = 27.5
  let dl2 = b.drawn(w.handle().unwrap()).unwrap()
  let (kx2, _, kw2, _, _, _) = ui_test_last_fill(dl2)
  assert_true(near(kx2 + kw2 / 2.0, 27.5))
}

///|
/// 清单里最后一条填充矩形（开关的钮是最后画的那个圆）。
fn ui_test_last_fill(
  dl : @moonui.DrawList,
) -> (Double, Double, Double, Double, Double, Int32) {
  let mut out : (Double, Double, Double, Double, Double, Int32)? = None
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) =>
        out = Some((x, y, w, h, r, rgb))
      _ => ()
    }
  }
  match out {
    Some(v) => v
    None => abort("清单里没有填充矩形")
  }
}

///|
test "UiRadioGroup：点行换选中，旧行的点消失；程序设值不回声" {
  let b = mock()
  let g = @widgets.UiRadioGroup(b, ["小", "中", "大"], selected=0)
  let root = g.view()
  let _ = root.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(200.0, 200.0),
    ),
  )
  assert_eq(g.selected(), 0)
  assert_eq(g.selected_text(), "小")
  let changes : Array[Int32] = []
  g.on_change(fn(i) { changes.push(i) })
  let rows = root.children()
  assert_eq(rows.length(), 3)
  // 第 0 行：环 + 实心点 + 文案 = 3 笔
  let h0 = rows[0].handle().unwrap()
  let (all0, fills0, strokes0, _) = ui_test_count(b.drawn(h0).unwrap())
  assert_eq((all0, fills0, strokes0), (3, 1, 0))
  // 第 1 行：只有环 + 文案
  let h1 = rows[1].handle().unwrap()
  let (all1, fills1, _, _) = ui_test_count(b.drawn(h1).unwrap())
  assert_eq((all1, fills1), (2, 0))
  // 点第 1 行：换选中、回调一次、两行都重画
  let _ = rows[1].fire(
    @moonui.Click(@moonui.EventTarget::of(h1), @moonui.MouseButton::Left),
  )
  assert_eq(g.selected(), 1)
  assert_eq(changes, [1])
  let (all0b, fills0b, _, _) = ui_test_count(b.drawn(h0).unwrap())
  assert_eq((all0b, fills0b), (2, 0)) // 旧行的点没了
  let (_, fills1b, _, _) = ui_test_count(b.drawn(h1).unwrap())
  assert_eq(fills1b, 1) // 新行的点出来了
  // 再点同一行：值没变，不回调
  let _ = rows[1].fire(
    @moonui.Click(@moonui.EventTarget::of(h1), @moonui.MouseButton::Left),
  )
  assert_eq(changes, [1])
  // 程序设值：不回调
  g.set_selected(2)
  assert_eq(g.selected(), 2)
  assert_eq(g.selected_text(), "大")
  assert_eq(changes, [1])
}

///|
/// 造一条按下-松开的鼠标序列（同一个点），返回点击的次数由调用方断言。
///
/// 分段控件与页签条都按"按下与松手在同一格才算"的规矩，所以判定必须是
/// **一对**事件；只投 `Click` 的话正好绕过它们唯一的那条判定链。
fn ui_test_press_release(
  w : @moonui.Widget[@moonui.MockBackend],
  x : Double,
  y : Double,
) -> Unit raise @moonui.UiError {
  let t = @moonui.EventTarget::of(w.handle().unwrap())
  let p = @moonui.LogicalPoint(x, y)
  let _ = w.fire(
    @moonui.MouseDown(t, @moonui.MouseButton::Left, p, @moonui.Mods::none()),
  )
  let _ = w.fire(
    @moonui.MouseUp(t, @moonui.MouseButton::Left, p, @moonui.Mods::none()),
  )
}

///|
test "UiSegmented：三格等宽、选中块落在第二格，按下松手同格才换选" {
  let b = mock()
  let seg = @widgets.UiSegmented(b, ["日", "周", "月"])
  let w = seg.widget()
  // 每格最小 56（单字撑不满），两侧各 3：总宽 3×56 + 6 = 174，高 32
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(174.0, 32.0))
  assert_eq(seg.selected(), 0)
  let changes : Array[Int32] = []
  seg.on_change(fn(i) { changes.push(i) })
  let dl = place(b, w)
  // 槽（1）+ 选中块（1）+ 三格文案（3）= 5 笔；其中填充 2 笔
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (5, 2))
  // 第一格的选中块：x = 留白 3，y = 3，宽 56，高 32 − 6
  let (fx, fy, fw, fh, _, _) = ui_test_last_fill_first_thumb(dl)
  assert_eq((fx, fy, fw, fh), (3.0, 3.0, 56.0, 26.0))
  // 点第二格中间（3 + 56 + 28 = 87）→ 换选并回调
  ui_test_press_release(w, 87.0, 16.0)
  assert_eq(seg.selected(), 1)
  assert_eq(changes, [1])
  let (tx, _, _, _, _, _) = ui_test_last_fill_first_thumb(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(tx, 59.0) // 3 + 56
  // 同格再点：不回调
  ui_test_press_release(w, 87.0, 16.0)
  assert_eq(changes, [1])
  // 按下第一格、松手在第三格：不算换选（这是"按下即时生效"会误触的那条）
  let t = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(
    @moonui.MouseDown(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(30.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = w.fire(
    @moonui.MouseUp(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(145.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  assert_eq(seg.selected(), 1)
  assert_eq(changes, [1])
  // 程序设值不回声，越界夹住
  seg.set_selected(9)
  assert_eq(seg.selected(), 2)
  assert_eq(changes, [1])
}

///|
/// 第二条填充矩形（分段控件的选中块；第一条是凹槽底）。
fn ui_test_last_fill_first_thumb(
  dl : @moonui.DrawList,
) -> (Double, Double, Double, Double, Double, Int32) {
  let mut seen = 0
  let mut out : (Double, Double, Double, Double, Double, Int32)? = None
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) => {
        seen = seen + 1
        if seen == 2 {
          out = Some((x, y, w, h, r, rgb))
        }
      }
      _ => ()
    }
  }
  match out {
    Some(v) => v
    None => abort("清单里没有第二条填充")
  }
}

///|
test "UiTabs：底线 + 选中项下面的主色条，换成第二页时条跟着挪" {
  let b = mock()
  let tabs = @widgets.UiTabs(b, ["概览", "明细"])
  let w = tabs.view()
  // 两字 17.33 + 两侧 14 = 45.33 一拍；总宽 90.67
  assert_true(near(w.intrinsic_size().width, 90.666666))
  assert_eq(w.intrinsic_size().height, 32.0)
  let changes : Array[Int32] = []
  tabs.on_change(fn(i) { changes.push(i) })
  let dl = place(b, w)
  // 底线（1）+ 两块文案（2）+ 指示条（1）= 4 笔；只有指示条那 1 笔是填充
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (4, 1))
  let (ix, iy, iw, ih, _, irgb) = ui_test_fill(dl)
  // 指示条：两端各内缩 10，宽 45.33 − 20 = 25.33，落在底线那 2px 上
  assert_eq((ix, iy, ih), (10.0, 30.0, 2.0))
  assert_true(near(iw, 25.333333))
  assert_eq(irgb, 0x2B6CF0)
  // 点第二页
  ui_test_press_release(w, 68.0, 16.0)
  assert_eq(tabs.selected(), 1)
  assert_eq(changes, [1])
  let (ix2, _, _, _, _, _) = ui_test_fill(b.drawn(w.handle().unwrap()).unwrap())
  assert_true(near(ix2, 45.333333 + 10.0))
}

///|
test "UiProgress：轨道整条、进度随值，越界与 NaN 都夹住" {
  let b = mock()
  let bar = @widgets.UiProgress(b, value=0.5, width=200.0, thickness=8.0)
  let w = bar.widget()
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(200.0, 8.0))
  let dl = place(b, w)
  let (all, fills, _, _) = ui_test_count(dl)
  assert_eq((all, fills), (2, 2))
  // 第二条是进度：宽 = 200 × 0.5
  let (px, py, pw, ph, pr, prgb) = ui_test_last_fill(dl)
  assert_eq((px, py, pw, ph, pr), (0.0, 0.0, 100.0, 8.0, 4.0))
  assert_eq(prgb, 0x2B6CF0)
  // 0 只画轨道
  bar.set_value(0.0)
  let (all0, fills0, _, _) = ui_test_count(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq((all0, fills0), (1, 1))
  // 极小的值也要看得见（至少 2px）
  bar.set_value(0.0005)
  let (_, _, pw2, _, _, _) = ui_test_last_fill(
    b.drawn(w.handle().unwrap()).unwrap(),
  )
  assert_eq(pw2, 2.0)
  // 越界与 NaN
  bar.set_value(1.8)
  assert_eq(bar.value(), 1.0)
  bar.set_value(0.0 / 0.0)
  assert_eq(bar.value(), 0.0)
}

///|
test "UiTag：淡底 + 同色字，换文案重算宽度、换语义色换两格颜色" {
  let b = mock()
  let tag = @widgets.UiTag(b, "新")
  let w = tag.widget()
  // UiSmall：字号 12 → 单字 8 宽，加两侧 16 = 24；高 = 12 + 10 = 22
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(24.0, 22.0))
  let dl = place(b, w)
  let (fx, fy, fw, fh, fr, frgb) = ui_test_fill(dl)
  assert_eq((fx, fy, fw, fh, fr), (0.0, 0.0, 24.0, 22.0, 11.0))
  // 浅色令牌的 accent 淡底：往白里混 0.88
  assert_eq(frgb, @widgets.ui_mix(0x2B6CF0, 0xFFFFFF, 0.88))
  let (text, _, _, trgb) = ui_test_text(dl)
  assert_eq(text, "新")
  assert_eq(trgb, 0x2B6CF0)
  // 换文案：三字 → 24 + 16 = 40
  tag.set_text("已完成")
  assert_eq(w.intrinsic_size().width, 40.0)
  // 换语义色：底与字各换一格
  tag.set_tone(@widgets.UiTone::UiDanger)
  let dl2 = b.drawn(w.handle().unwrap()).unwrap()
  let (_, _, _, _, _, frgb2) = ui_test_fill(dl2)
  assert_eq(frgb2, @widgets.ui_mix(0xE5484D, 0xFFFFFF, 0.88))
  let (_, _, _, trgb2) = ui_test_text(dl2)
  assert_eq(trgb2, 0xE5484D)
}

///|
test "UiTextInput：三层壳（Sized→Panel→Panel→编辑框），边框四档只换一格颜色" {
  let b = mock()
  let input = @widgets.UiTextInput(b, placeholder="请输入")
  let root = input.view()
  assert_eq(root.kind(), @moonui.WidgetKind::Sized)
  let shell = root.children()[0]
  assert_eq(shell.kind(), @moonui.WidgetKind::Panel)
  let inner = shell.children()[0]
  assert_eq(inner.kind(), @moonui.WidgetKind::Panel)
  let field = inner.children()[0]
  assert_eq(field.kind(), @moonui.WidgetKind::TextInput)
  // 静息：外层涂 border
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xDBDFE6)),
  )
  // 悬停：border_strong
  let ft = @moonui.EventTarget::of(field.handle().unwrap())
  let _ = field.fire(@moonui.MouseEnter(ft))
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xC2C8D2)),
  )
  // 焦点：accent（焦点压过悬停）
  let _ = field.fire(@moonui.Focus(ft))
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0x2B6CF0)),
  )
  // 失焦：落回悬停那一档
  let _ = field.fire(@moonui.Blur(ft))
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xC2C8D2)),
  )
  // 禁用：退到 surface_active，且编辑框本身也被禁用
  input.set_enabled(false)
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0xE7EAEF)),
  )
  assert_false(field.enabled())
}

///|
test "UiTextInput：文本读写走原生编辑框，内容变化回传全文" {
  let b = mock()
  let input = @widgets.UiTextInput(b, text="a")
  assert_eq(input.text(), "a")
  input.set_text("abc")
  assert_eq(input.text(), "abc")
  let seen : Array[String] = []
  input.on_input(fn(t) { seen.push(t) })
  let ft = @moonui.EventTarget::of(input.field().handle().unwrap())
  let _ = input.field().fire(@moonui.Input(ft, "abcd"))
  assert_eq(seen, ["abcd"])
  // 密码档：同一只控件，编辑框换种类
  let pw = @widgets.UiTextInput::password(b, text="hunter2")
  assert_eq(pw.field().kind(), @moonui.WidgetKind::PasswordInput)
  assert_eq(pw.text(), "hunter2")
}

///|
test "UiSpinbox：步进夹在范围内、打字能改值、失焦把半成品洗回值" {
  let b = mock()
  let spin = @widgets.UiSpinbox(b, value=9, min=0, max=10, step=1, width=140.0)
  let root = spin.view()
  assert_eq(spin.value(), 9)
  assert_eq(spin.input().text(), "9")
  let _ = root.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(300.0, 60.0),
    ),
  )
  let stepper = root.children()[1]
  let sf = stepper.frame()
  assert_eq(sf.size.width, 22.0)
  let changes : Array[Int32] = []
  spin.on_change(fn(v) { changes.push(v) })
  // 点上半 → +1
  let st = @moonui.EventTarget::of(stepper.handle().unwrap())
  let top = @moonui.LogicalPoint(sf.origin.x + 10.0, sf.origin.y + 8.0)
  let _ = stepper.fire(
    @moonui.MouseDown(st, @moonui.MouseButton::Left, top, @moonui.Mods::none()),
  )
  assert_eq(spin.value(), 10)
  assert_eq(changes, [10])
  // 到顶再点：值不变、不回调
  let _ = stepper.fire(
    @moonui.MouseDown(st, @moonui.MouseButton::Left, top, @moonui.Mods::none()),
  )
  assert_eq(changes, [10])
  // 点下半 → −1
  let bottom = @moonui.LogicalPoint(sf.origin.x + 10.0, sf.origin.y + 24.0)
  let _ = stepper.fire(
    @moonui.MouseDown(
      st,
      @moonui.MouseButton::Left,
      bottom,
      @moonui.Mods::none(),
    ),
  )
  assert_eq(spin.value(), 9)
  assert_eq(changes, [10, 9])
  // 打字：合法的跟着改值
  let ft = @moonui.EventTarget::of(spin.input().field().handle().unwrap())
  let _ = spin.input().field().fire(@moonui.Input(ft, "7"))
  assert_eq(spin.value(), 7)
  assert_eq(changes, [10, 9, 7])
  // 打字：越界与非法一律不动值
  let _ = spin.input().field().fire(@moonui.Input(ft, "99"))
  assert_eq(spin.value(), 7)
  let _ = spin.input().field().fire(@moonui.Input(ft, "abc"))
  assert_eq(spin.value(), 7)
  let _ = spin.input().field().fire(@moonui.Input(ft, "-"))
  assert_eq(spin.value(), 7)
  // 失焦：把框里的半成品洗回当下的值
  let _ = spin.input().field().fire(@moonui.Blur(ft))
  assert_eq(spin.input().text(), "7")
  // 程序设值：夹住、不回调
  spin.set_value(42)
  assert_eq(spin.value(), 10)
  assert_eq(changes, [10, 9, 7])
}

///|
/// `T353`：次级档的 1px 边改成"两层填充"之后，四档的可见圆角才真正同源。
///
/// 老做法是 `StrokeRect`（路径 + 画笔）：描边路径本身内缩 0.5、半径减 0.5，
/// 再经"逻辑→物理 int"与千分比两次取整，四角的可见弧比同半径的实心块长出
/// 约 2px——截图上一排按钮里"取消"的角明显比"保存/删除"圆。这条判据钉的是
/// "一笔描边都没有，两层填充的几何严丝合缝"，而不是某个像素读数。
test "UiButton：次级档的边是两层填充，圆角与实心档同一套算术" {
  let b = mock()
  let btn = @widgets.UiButton(
    b,
    "取消",
    kind=@widgets.UiButtonKind::UiSecondary,
  )
  let dl = place(b, btn.widget())
  let fills : Array[(Double, Double, Double, Double, Double, Int32)] = []
  let mut strokes = 0
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(x, y, w, h, r, rgb, _) =>
        fills.push((x, y, w, h, r, rgb))
      @moonui.StrokeRect(_, _, _, _, _, _, _) => strokes = strokes + 1
      _ => ()
    }
  }
  assert_eq(fills.length(), 2)
  assert_eq(strokes, 0)
  // 外层整块涂边色（半径 = 档半径 8），内层内缩 1px 涂面色（半径 = 7）
  assert_eq(fills[0], (0.0, 0.0, 64.0, 32.0, 8.0, 0xDBDFE6))
  assert_eq(fills[1], (1.0, 1.0, 62.0, 30.0, 7.0, 0xFFFFFF))
  // 主按钮照旧是一层：这条改动只碰"有边的那一档"
  let primary = @widgets.UiButton(b, "保存")
  let dl2 = place(b, primary.widget())
  let (_, fills2, strokes2, _) = ui_test_count(dl2)
  assert_eq((fills2, strokes2), (1, 0))
}

///|
/// `T353`：自绘外壳里那层原生编辑框必须摘掉自带的边框，否则"圆角边里套
/// 一圈系统方边"（截图里的双层框）。
///
/// 这条在 mock 上只能断言"语义到了后端"（mock 没有原生边框可摘），真机上
/// 摘没摘干净归真窗截图那条账；另一半是**口子只对编辑框开**——给标签摘边
/// 要明确报错，而不是静默通过变成"谁都能改原生外观"。
test "UiTextInput：编辑框摘掉原生自带边框，这条口子只对编辑框开" {
  let b = mock()
  let input = @widgets.UiTextInput(b, placeholder="项目名")
  let field = input.field()
  assert_eq(field.kind(), @moonui.WidgetKind::TextInput)
  assert_true(b.widget(field.handle().unwrap()).frameless)
  // 密码档同一条通道
  let pw = @widgets.UiTextInput::password(b, text="x")
  assert_true(b.widget(pw.field().handle().unwrap()).frameless)
  // 其它种类：报错，不静默
  let label = @moonui.Widget::label(b, "x")
  let err : String? = try {
    label.set_frameless(true)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(err, Some("不支持的操作：该控件没有自带边框可摘"))
  b.terminate()
}

///|
/// `T358` 第二档 A：框内的字色/底色要作为**显式样式**下发到原生编辑框，且换主题
/// 时跟着换。Windows 那头 WM_CTLCOLOREDIT 取用的就是这只 field 的 fg/bg prop；
/// 这里在 mock 上钉住"令牌到了 Core 的控件样式表"，缺了它真窗那条无从谈起。
/// 顺带守住摘边（T353）没被这次 set_style 覆盖掉。
test "UiTextInput：框内 fg/bg 随主题下发到原生编辑框，换主题跟着换（T358）" {
  let b = mock()
  let input = @widgets.UiTextInput(b, placeholder="项目名")
  let field = input.field()
  assert_eq(field.kind(), @moonui.WidgetKind::TextInput)
  // 浅色：surface / text 两格显式下发
  let light = field.style()
  assert_eq(light.unwrap().background, Some(@widgets.ui_color(0xFF_FFFF)))
  assert_eq(light.unwrap().foreground, Some(@widgets.ui_color(0x16_181D)))
  assert_true(b.widget(field.handle().unwrap()).frameless)
  // 深色：两格都换掉——尤其底色，浅色下与系统白一致可以蒙混，深色下下发不到位
  // 就是"深底上留一块白框"，这条专门钉住它
  input.set_theme(@widgets.UiTheme::dark())
  let dark = field.style()
  assert_eq(dark.unwrap().background, Some(@widgets.ui_color(0x22_242A)))
  assert_eq(dark.unwrap().foreground, Some(@widgets.ui_color(0xEC_EDF1)))
  // 外两层也跟着换（换主题那条老账不回归）
  let shell = input.view().children()[0]
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(0x38_3B44)),
  )
  // 密码框同一条通道
  let pw = @widgets.UiTextInput::password(b, text="x")
  assert_eq(
    pw.field().style().unwrap().background,
    Some(@widgets.ui_color(0xFF_FFFF)),
  )
  b.terminate()
}

///|
/// 反复取同一只自绘面的绘制清单：`place` 会把控件挂进一只新 Row，同一只控件
/// 挂两次 Core 会报"已被其他容器持有"；这里直接给自定义面一次布局机会。
fn ui_test_redraw(
  b : @moonui.MockBackend,
  w : @moonui.Widget[@moonui.MockBackend],
) -> @moonui.DrawList raise @moonui.UiError {
  let _ = w.do_layout(
    @moonui.LogicalRect(
      @moonui.LogicalPoint(0.0, 0.0),
      @moonui.LogicalSize(400.0, 300.0),
    ),
  )
  let h = match w.handle() {
    Some(h) => h
    None => abort("控件没有原生句柄")
  }
  match b.drawn(h) {
    Some(dl) => dl
    None => abort("自定义绘制面一次都没画过")
  }
}

///|
/// `T357`：整树换主题不能靠重造控件——十只控件都得有 `set_theme`，而且换完
/// 当帧画出来的颜色真的来自新令牌。漏一只，画册切到深色时它就会顶着浅色。
fn ui_test_has_fill(dl : @moonui.DrawList, rgb : Int32) -> Bool {
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(_, _, _, _, _, c, _) => if c == rgb { return true }
      _ => ()
    }
  }
  false
}

///|
test "自绘套件：十只控件都能就地换整套令牌（T357）" {
  let b = mock()
  let l = @widgets.UiTheme::light()
  let d = @widgets.UiTheme::dark()

  // 主色块：按钮、勾选框、开关、单选圆点
  let btn = @widgets.UiButton(b, "保存", theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, btn.widget()), l.accent))
  btn.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, btn.widget()), d.accent))

  let chk = @widgets.UiCheckbox(b, "启用", checked=true, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, chk.widget()), l.accent))
  chk.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, chk.widget()), d.accent))

  let tgl = @widgets.UiToggle(b, "自动", checked=true, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tgl.widget()), l.accent))
  tgl.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tgl.widget()), d.accent))

  let rad = @widgets.UiRadioGroup(b, ["甲", "乙"], selected=0, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, rad.rows[0]), l.accent))
  rad.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, rad.rows[0]), d.accent))

  // 条带：分段铺槽色，页签的选中指示条走主色
  let seg = @widgets.UiSegmented(b, ["低", "高"], theme=l)
  assert_true(
    ui_test_has_fill(ui_test_redraw(b, seg.widget()), l.surface_sunken),
  )
  seg.set_theme(d)
  assert_true(
    ui_test_has_fill(ui_test_redraw(b, seg.widget()), d.surface_sunken),
  )

  let tab = @widgets.UiTabs(b, ["甲", "乙"], theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tab.view()), l.accent))
  tab.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, tab.view()), d.accent))

  // 进度与角标：一个换轨道色，一个换淡底
  let bar = @widgets.UiProgress(b, value=0.5, theme=l)
  assert_true(ui_test_has_fill(ui_test_redraw(b, bar.widget()), l.track))
  bar.set_theme(d)
  assert_true(ui_test_has_fill(ui_test_redraw(b, bar.widget()), d.track))

  let tag = @widgets.UiTag(b, "新", theme=l)
  assert_true(
    ui_test_has_fill(
      ui_test_redraw(b, tag.widget()),
      l.tone_surface(@widgets.UiTone::UiAccent),
    ),
  )
  tag.set_theme(d)
  assert_true(
    ui_test_has_fill(
      ui_test_redraw(b, tag.widget()),
      d.tone_surface(@widgets.UiTone::UiAccent),
    ),
  )

  // 输入两层壳：外层边色、内层面色都要换
  let input = @widgets.UiTextInput(b, theme=l)
  let shell = input.view().children()[0]
  let inner = shell.children()[0]
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(l.border)),
  )
  assert_eq(
    inner.style().unwrap().background,
    Some(@widgets.ui_color(l.surface)),
  )
  input.set_theme(d)
  assert_eq(
    shell.style().unwrap().background,
    Some(@widgets.ui_color(d.border)),
  )
  assert_eq(
    inner.style().unwrap().background,
    Some(@widgets.ui_color(d.surface)),
  )

  let spin = @widgets.UiSpinbox(b, value=1, theme=l)
  let spin_shell = spin.view().children()[0].children()[0]
  assert_eq(
    spin_shell.style().unwrap().background,
    Some(@widgets.ui_color(l.border)),
  )
  spin.set_theme(d)
  assert_eq(
    spin_shell.style().unwrap().background,
    Some(@widgets.ui_color(d.border)),
  )
}

///|
/// 换主题时按文案量出来的固有尺寸必须一起重算：字号从 13 变 15（大档），
/// 文案宽度跟着变；只换色不换尺寸会得到"深色的字挤在浅色的框里"。
test "set_theme 同步重算按文案量的尺寸（T357）" {
  let b = mock()
  let l = @widgets.UiTheme::light()
  let d = @widgets.UiTheme::dark()
  let rad = @widgets.UiRadioGroup(b, ["甲", "乙"], selected=0, theme=l)
  let h0 = ui_test_fill(ui_test_redraw(b, rad.rows[0])).3
  rad.set_theme(d, size=@widgets.UiLarge)
  let h1 = ui_test_fill(ui_test_redraw(b, rad.rows[0])).3
  // 大档字号 15 vs 13：圆环直径随字号变大（不是只把颜色换成深色）
  assert_true(h1 > h0)
  // 换回中档浅色：尺寸与颜色都回到起点，没有累积漂移
  rad.set_theme(l, size=@widgets.UiMedium)
  assert_eq(ui_test_fill(ui_test_redraw(b, rad.rows[0])).3, h0)
  assert_true(ui_test_has_fill(ui_test_redraw(b, rad.rows[0]), l.accent))
}

///|
/// `T357`：不定档不是"画一段假进度"，而是控件自己有一条帧链。相位函数是纯的
/// （逐拍可断言），链在关档后自己收（不留空转定时器），亮条在槽里来回走。
test "UiProgress 不定档：相位来回、帧链推进、关掉自动收链（T357）" {
  // 纯相位：0 → 1 → 0，端点精确（PingPong 取模的边界最容易写错一拍）
  assert_eq(@widgets.ui_progress_phase(0), 0.0)
  assert_eq(@widgets.ui_progress_phase(450), 0.5)
  assert_eq(@widgets.ui_progress_phase(900), 1.0)
  assert_eq(@widgets.ui_progress_phase(1800), 0.0)
  assert_true(@widgets.ui_progress_phase(225) > 0.24)
  assert_true(@widgets.ui_progress_phase(225) < 0.26)
  assert_true(@widgets.ui_progress_phase(1350) > 0.49)
  assert_true(@widgets.ui_progress_phase(1350) < 0.51)

  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let now : Array[Int32] = [0]
  app.set_anim_clock(fn() { now[0] })
  let bar = @widgets.UiProgress(
    b,
    value=0.4,
    width=200.0,
    indeterminate=true,
    app=Some(app),
  )
  assert_true(bar.indeterminate())
  let dl0 = ui_test_redraw(b, bar.widget())
  // 轨道 + 一段短亮条（不是确定性进度的 40% 长条）
  assert_eq(ui_test_count(dl0).1, 2)
  let x0 = ui_test_last_fill(dl0).0
  // 第一拍立即点火，相位从 16ms 那一档起步
  assert_true(app.step())
  assert_true(bar.phase() > 0.0)
  assert_true(bar.phase() < 0.1)
  // 推进到接近折返点：亮条走到最右端附近
  let mut n = 0
  while n < 55 {
    now[0] = now[0] + 16
    let _ = app.step()
    n = n + 1
  }
  assert_true(bar.phase() > 0.9)
  let dl1 = ui_test_redraw(b, bar.widget())
  // 亮条的位置真的变了（两份清单里第二笔填充的 x 不同）
  assert_true(ui_test_last_fill(dl1).0 != x0)
  // 关档：相位归零、下一拍链自己收掉，绝不空转
  bar.set_indeterminate(false)
  assert_false(bar.indeterminate())
  assert_eq(bar.phase(), 0.0)
  now[0] = now[0] + 16
  let _ = app.step()
  assert_false(bar.ticking())
  // 确定性那一档照旧：值 0.4 → 80px 的那一截
  let dl2 = ui_test_redraw(b, bar.widget())
  assert_eq(ui_test_last_fill(dl2).2, ui_test_fill(dl2).2 * 0.4)
  @moonui.Backend::terminate(b)
}

///|
/// 颜色是否严格落在两端之间（端点不算）：动画中间帧的抓手。逐通道比较，
/// 不用亮度——两个深蓝的亮度差可能被取整抹平。
fn ui_test_between_color(c : Int32, a : Int32, z : Int32) -> Bool {
  let mut strict = false
  for shift in [16, 8, 0] {
    let v = (c >> shift) & 255
    let lo = if a < z { (a >> shift) & 255 } else { (z >> shift) & 255 }
    let hi = if a < z { (z >> shift) & 255 } else { (a >> shift) & 255 }
    if v < lo || v > hi {
      return false
    }
    if v > lo && v < hi {
      strict = true
    }
  }
  strict
}

///|
/// `T357`：hover/press 不再硬切——Core 的帧链推 0..1 强度，绘制端按强度混色。
/// 端点与旧版逐位相同（前面那 79 条判据就是回归网），中间帧必须真的落在两端
/// 之间；反向要能从当下值续跑，不是先跳回静息再重播。
test "UiButton：三态过渡走帧链，中间帧是混色、反向从当下续跑（T357）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let now : Array[Int32] = [0]
  app.set_anim_clock(fn() { now[0] })
  let l = @widgets.UiTheme::light()
  let btn = @widgets.UiButton(b, "保存", theme=l, app=Some(app))
  let w = btn.widget()
  let c0 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_eq(c0, l.accent)

  let target = @moonui.EventTarget::of(w.handle().unwrap())
  let _ = w.fire(@moonui.MouseEnter(target))
  let _ = app.step()
  let c1 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_true(ui_test_between_color(c1, l.accent, l.accent_hover))
  // 十拍到 160ms：落在精确的 hover 端点
  let mut n = 0
  while n < 9 {
    now[0] = now[0] + 16
    let _ = app.step()
    n = n + 1
  }
  let c2 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_eq(c2, l.accent_hover)

  // 反向：第一帧应落在 hover→静息之间，而不是直接跳回静息
  let _ = w.fire(@moonui.MouseLeave(target))
  let _ = app.step()
  let c3 = ui_test_fill(ui_test_redraw(b, w)).5
  assert_true(ui_test_between_color(c3, l.accent, l.accent_hover))
  assert_true(c3 != c0)
  n = 0
  while n < 9 {
    now[0] = now[0] + 16
    let _ = app.step()
    n = n + 1
  }
  assert_eq(ui_test_fill(ui_test_redraw(b, w)).5, l.accent)

  // 关掉 App 的调用方仍是硬切：mock 判据不用开时钟
  let plain = @widgets.UiButton(b, "保存", theme=l)
  let pw = plain.widget()
  let _ = pw.fire(
    @moonui.MouseEnter(@moonui.EventTarget::of(pw.handle().unwrap())),
  )
  assert_eq(ui_test_fill(ui_test_redraw(b, pw)).5, l.accent_hover)
  @moonui.Backend::terminate(b)
}

///|
/// 造一个只带 key 的按键事件（修饰键全关），判据里方向键用。
fn ui_test_key(k : String) -> @moonui.KeyPress {
  @moonui.KeyPress::{
    key: k,
    ctrl: false,
    alt: false,
    shift: false,
    meta: false,
  }
}

///|
/// `T357`：分段与页签共用 `ui_strip_watch`，于是左右键换档也一次到位——
/// 首尾环绕、同一格不重复回调（与点击共用 `ui_strip_commit`）。
test "Segmented / Tabs：左右键换档、首尾环绕（T357）" {
  let b = mock()
  let seg = @widgets.UiSegmented(b, ["低", "中", "高"], selected=1)
  let w = seg.widget()
  let t = @moonui.EventTarget::of(w.handle().unwrap())
  let seen : Array[Int32] = []
  seg.on_change(fn(i) { seen.push(i) })
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(seg.selected(), 2)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(seg.selected(), 0)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Left")))
  assert_eq(seg.selected(), 2)
  // 无关按键不进这条链
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Enter")))
  assert_eq(seg.selected(), 2)
  assert_eq(seen, [2, 0, 2])

  let tabs = @widgets.UiTabs(b, ["甲", "乙", "丙"], selected=0)
  let tw = tabs.view()
  let tt = @moonui.EventTarget::of(tw.handle().unwrap())
  let _ = tw.fire(@moonui.KeyDown(tt, ui_test_key("Left")))
  assert_eq(tabs.selected(), 2)
  let _ = tw.fire(@moonui.KeyDown(tt, ui_test_key("Right")))
  assert_eq(tabs.selected(), 0)
}

///|
/// `T357`：滚轮落在输入框或步进器上都推一步；负增量往回走，range 外夹住不回调。
test "UiSpinbox：滚轮上滚加、下滚减，越界不回调（T357）" {
  let b = mock()
  let spin = @widgets.UiSpinbox(b, value=5, min=0, max=10, step=2)
  let seen : Array[Int32] = []
  spin.on_change(fn(v) { seen.push(v) })
  let field = spin.input().field()
  let ft = @moonui.EventTarget::of(field.handle().unwrap())
  let _ = field.fire(@moonui.Scroll(ft, @moonui.LogicalPoint(0.0, 120.0)))
  assert_eq(spin.value(), 7)
  let st = @moonui.EventTarget::of(spin.stepper().handle().unwrap())
  let _ = spin
    .stepper()
    .fire(@moonui.Scroll(st, @moonui.LogicalPoint(0.0, -120.0)))
  assert_eq(spin.value(), 5)
  // 零增量不做事；越界夹到端点且不重复回调
  let _ = field.fire(@moonui.Scroll(ft, @moonui.LogicalPoint(0.0, 0.0)))
  assert_eq(spin.value(), 5)
  let mut n = 0
  while n < 10 {
    let _ = field.fire(@moonui.Scroll(ft, @moonui.LogicalPoint(0.0, 120.0)))
    n = n + 1
  }
  assert_eq(spin.value(), 10)
  assert_eq(seen, [7, 5, 7, 9, 10])
}

///|
/// `T358` 第二档 B：自绘滑块——绘制三笔（凹槽 + 已填 + 钮），起点值夹在值域内，
/// 程序设值与回调只在值真变时发生。
test "UiSlider：轨道/已填/圆钮三笔，值域夹住、设值只在变化时回调（T358）" {
  let b = mock()
  let slider = @widgets.UiSlider(b, value=25.0, width=200.0)
  let w = slider.widget()
  assert_eq(w.intrinsic_size(), @moonui.LogicalSize(200.0, 32.0))
  assert_eq(slider.value(), 25.0)
  let dl = place(b, w)
  // 凹槽(1) + 已填(1) + 钮(1) = 3 笔填充；未聚焦没有焦点环那笔描边
  let (all, fills, strokes, _) = ui_test_count(dl)
  assert_eq((all, fills, strokes), (3, 3, 0))
  // 中值 25/100：钮心 x = inset(r=32*0.28=8.96) + 0.25×(200−2×8.96)
  //            = 8.96 + 45.52 = 54.48；已填那一截宽同此（第二笔填充，第一笔是凹槽）
  let mut nth = 0
  let mut fw = 0.0
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillRect(_, _, cw, _, _, _, _) => {
        nth += 1
        if nth == 2 {
          fw = cw
        }
      }
      _ => ()
    }
  }
  assert_true(fw > 54.0 && fw < 55.0)
  // 回调：值变了才响
  let seen : Array[Double] = []
  slider.on_change(fn(v) { seen.push(v) })
  slider.set_value(60.0)
  assert_eq(slider.value(), 60.0)
  slider.set_value(60.0) // 同值：不回调
  slider.set_value(999.0) // 越界夹住
  assert_eq(slider.value(), 100.0)
  slider.set_value(-5.0)
  assert_eq(slider.value(), 0.0)
  assert_eq(seen, [60.0, 100.0, 0.0])
  // 纯函数：比例映射与 min==max 的除零保护
  assert_eq(@widgets.ui_slider_fraction(50.0, 0.0, 100.0), 0.5)
  assert_eq(@widgets.ui_slider_fraction(-5.0, 0.0, 100.0), 0.0)
  assert_eq(@widgets.ui_slider_fraction(200.0, 0.0, 100.0), 1.0)
  assert_eq(@widgets.ui_slider_fraction(5.0, 7.0, 7.0), 0.0)
  b.terminate()
}

///|
/// 指针/键盘：按下记锚点、拖动按"起点 + 位移"重算（不逐帧累加），左右键步进、
/// Home/End 到端；禁用态不接事件。mock 上直接 fire，真机的指针捕获归平台层。
test "UiSlider：拖动按位移重算、方向键步进、禁用不接事件（T358）" {
  let b = mock()
  let slider = @widgets.UiSlider(b, value=50.0, width=200.0)
  let w = slider.widget()
  let _ = place(b, w)
  let t = @moonui.EventTarget::of(w.handle().unwrap())
  let seen : Array[Double] = []
  slider.on_change(fn(v) { seen.push(v) })
  // 拖动：按下 (x=100) 记锚点，移到 x=191 → 位移 91px / 轨道 182.08px × 值域 100
  //       ≈ 50 → 值从 50 走到约 100（夹到端点）
  assert_false(slider.dragging())
  let _ = w.fire(
    @moonui.MouseDown(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(100.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  assert_true(slider.dragging())
  let _ = w.fire(@moonui.MouseMove(t, @moonui.LogicalPoint(191.0, 16.0)))
  assert_true(slider.value() > 95.0) // 91/182.08×100 ≈ 49.98，50+≈100
  let _ = w.fire(
    @moonui.MouseUp(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(191.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  assert_false(slider.dragging())
  // 反向：从右端 191 按下（此时值≈100）、移回 100（−91px ≈ −50）→ 值落回中点附近
  let _ = w.fire(
    @moonui.MouseDown(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(191.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  let _ = w.fire(@moonui.MouseMove(t, @moonui.LogicalPoint(100.0, 16.0)))
  assert_true(slider.value() > 45.0 && slider.value() < 55.0)
  let _ = w.fire(
    @moonui.MouseUp(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(100.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  // 键盘：左右各 1/20 值域（5），Home/End 到端
  let before_key = slider.value()
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_true(slider.value() > before_key && slider.value() < before_key + 6.0)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Left")))
  assert_true(
    slider.value() < before_key + 1.0 && slider.value() > before_key - 1.0,
  )
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Home")))
  assert_eq(slider.value(), 0.0)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("End")))
  assert_eq(slider.value(), 100.0)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Enter"))) // 无关键不进链
  assert_eq(slider.value(), 100.0)
  // 禁用：按下不进拖动，值不动
  slider.set_value(40.0)
  slider.set_enabled(false)
  let _ = w.fire(
    @moonui.MouseDown(
      t,
      @moonui.MouseButton::Left,
      @moonui.LogicalPoint(100.0, 16.0),
      @moonui.Mods::none(),
    ),
  )
  assert_false(slider.dragging())
  let _ = w.fire(@moonui.MouseMove(t, @moonui.LogicalPoint(191.0, 16.0)))
  assert_eq(slider.value(), 40.0)
  let _ = w.fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(slider.value(), 40.0)
  // 换主题不丢值、不崩
  slider.set_theme(@widgets.UiTheme::dark())
  assert_eq(slider.value(), 40.0)
  assert_true(seen.length() > 0)
  b.terminate()
}

///|
/// `T360` 第三档：八只新控件。口径与前两档一致——跑在 mock 上、断言"这一帧
/// 收到了什么命令"，交互一律 `fire` 直接投事件。
/// 卡片是唯一走样式通道的（它要装孩子，自绘面装不了），所以它的判据读
/// `style()` 而不是绘制清单。
test "UiCard：外层边色内层面色、圆角差 1，换主题两层同步（T360）" {
  let b = mock()
  let content = @moonui.Widget::label(b, "内容")
  let card = @widgets.UiCard(b, content)
  let lt = @widgets.UiTheme::light()
  assert_eq(
    card.widget().style().unwrap().background,
    Some(@widgets.ui_color(lt.border)),
  )
  assert_eq(
    card.content().style().unwrap().background,
    Some(@widgets.ui_color(lt.surface)),
  )
  let ro = card.widget().style().unwrap().radius.unwrap()
  let ri = card.content().style().unwrap().radius.unwrap()
  assert_true(near(ro - ri, 1.0))
  // 换深色：两层都换，不留"边是新色、面是旧色"的半截
  let dt = @widgets.UiTheme::dark()
  card.set_theme(dt)
  assert_eq(
    card.widget().style().unwrap().background,
    Some(@widgets.ui_color(dt.border)),
  )
  assert_eq(
    card.content().style().unwrap().background,
    Some(@widgets.ui_color(dt.surface)),
  )
  // 内边距档：padded=false 时内层零内边距（贴边放图那一档）
  let card2 = @widgets.UiCard(b, @moonui.Widget::label(b, "x"), padded=false)
  assert_eq(
    card2.content().style().unwrap().padding,
    Some(@moonui.EdgeInsets::zero()),
  )
  b.terminate()
}

///|
test "UiAlert：单行/带标题两档高度、底色跟语义、只有叉能关（T360）" {
  let b = mock()
  let lt = @widgets.UiTheme::light()
  let one = @widgets.UiAlert(b, "保存成功")
  let line = lt.font_size * 1.45
  assert_true(near(one.widget().intrinsic_size().height, 24.0 + line))
  let dl = place(b, one.widget())
  // 底 + 左竖条两笔填充；只有一行字
  assert_eq(ui_test_count(dl).1, 2)
  let (t1, _, _, _) = ui_test_text(dl)
  assert_eq(t1, "保存成功")
  // 带标题：高度多一行 + 2，字多一行
  let two = @widgets.UiAlert(
    b,
    "磁盘剩余 3%",
    title="空间不足",
    tone=@widgets.UiTone::UiWarning,
  )
  assert_true(
    near(two.widget().intrinsic_size().height, 24.0 + line * 2.0 + 2.0),
  )
  let dl2 = place(b, two.widget())
  let (t2, _, _, _) = ui_test_text(dl2)
  assert_eq(t2, "空间不足")
  // 换语义色：底色就是 danger 的淡底那份，与角标同一套混色
  two.set_tone(@widgets.UiTone::UiDanger)
  let dl3 = ui_test_redraw(b, two.widget())
  let (_, _, _, _, _, bg) = ui_test_fill(dl3)
  assert_eq(bg, lt.tone_surface(@widgets.UiTone::UiDanger))
  // 关闭：只有叉的命中区能触发；点主体不响
  let closeable = @widgets.UiAlert(b, "已保存", closable=true, width=360.0)
  let _ = place(b, closeable.widget())
  let fired : Array[Int32] = [0]
  closeable.on_close(fn() { fired[0] = fired[0] + 1 })
  let t = @moonui.EventTarget::of(closeable.widget().handle().unwrap())
  let _ = closeable
    .widget()
    .fire(
      @moonui.MouseDown(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(340.0, 15.0),
        @moonui.Mods::none(),
      ),
    )
  let _ = closeable
    .widget()
    .fire(
      @moonui.MouseUp(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(340.0, 15.0),
        @moonui.Mods::none(),
      ),
    )
  assert_eq(fired[0], 1)
  // 主体：按下抬起都不算
  let _ = closeable
    .widget()
    .fire(
      @moonui.MouseDown(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(100.0, 15.0),
        @moonui.Mods::none(),
      ),
    )
  let _ = closeable
    .widget()
    .fire(
      @moonui.MouseUp(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(100.0, 15.0),
        @moonui.Mods::none(),
      ),
    )
  assert_eq(fired[0], 1)
  b.terminate()
}

///|
test "UiSkeleton：行数/末行短一截、相位来回、不交 app 不空转（T360）" {
  let b = mock()
  let sk = @widgets.UiSkeleton(b, width=320.0, line_h=12.0, lines=3, gap=8.0)
  assert_true(near(sk.widget().intrinsic_size().width, 320.0))
  assert_true(near(sk.widget().intrinsic_size().height, 52.0))
  let dl = place(b, sk.widget())
  assert_eq(ui_test_count(dl).1, 3)
  // 末行取 60% 宽
  let (_, _, lw, _, _, _) = ui_test_last_fill(dl)
  assert_true(near(lw, 192.0))
  // 相位是纯函数：半程 0.5、整程回到 1（PingPong 在 t=dur 处是端点 1）
  assert_eq(@widgets.ui_skeleton_phase(0), 0.0)
  assert_true(near(@widgets.ui_skeleton_phase(700), 0.5))
  assert_true(near(@widgets.ui_skeleton_phase(1400), 1.0))
  assert_true(near(@widgets.ui_skeleton_phase(2100), 0.5))
  assert_eq(@widgets.ui_skeleton_phase(2800), 0.0)
  // 不交 app：静态，链不空转
  assert_false(sk.ticking())
  // 交 app：一拍就动，相位跟着时钟走
  let app = @moonui.App(b)
  let now : Array[Int32] = [0]
  app.set_anim_clock(fn() { now[0] })
  let live = @widgets.UiSkeleton(b, lines=2, app=Some(app))
  assert_true(live.ticking())
  let _ = app.step()
  assert_true(live.phase() > 0.0)
  b.terminate()
}

///|
test "UiToast：常驻不空转、带时长会倒数并只回调一次（T360）" {
  let b = mock()
  // 常驻（duration<=0）：没有帧链，也不该 done
  let pinned = @widgets.UiToast(b, "离线模式", duration_ms=0)
  assert_false(pinned.ticking())
  assert_false(pinned.done())
  assert_eq(pinned.remaining_ms(), 0)
  let dl = place(b, pinned.widget())
  assert_eq(ui_test_count(dl).1, 2) // 底 + 左侧语义圆点
  let (tt, _, _, _) = ui_test_text(dl)
  assert_eq(tt, "离线模式")
  // 带时长：一拍一减，到点回调一次、链自己收
  let app = @moonui.App(b)
  let now : Array[Int32] = [0]
  app.set_anim_clock(fn() { now[0] })
  let toast = @widgets.UiToast(b, "已保存", duration_ms=64, app=Some(app))
  let fired : Array[Int32] = [0]
  toast.on_dismiss(fn() { fired[0] = fired[0] + 1 })
  assert_true(toast.remaining_ms() > 0)
  let _ = app.step()
  assert_true(toast.remaining_ms() < 64)
  let mut n = 0
  while n < 10 {
    now[0] = now[0] + 16
    let _ = app.step()
    n = n + 1
  }
  assert_true(toast.done())
  assert_eq(toast.remaining_ms(), 0)
  assert_eq(fired[0], 1)
  assert_false(toast.ticking())
  b.terminate()
}

///|
test "UiSteps：圆点/连线/标签三笔、当前步换色、节点可点可键（T360）" {
  let b = mock()
  let labels : Array[String] = [
    "填写", "校验", "提交", "审核", "完成",
  ]
  let st = @widgets.UiSteps(b, labels, current=2, width=400.0)
  assert_eq(st.count(), 5)
  assert_eq(st.current(), 2)
  let dl = place(b, st.widget())
  let (all, fills, strokes, _) = ui_test_count(dl)
  // 4 段连线 + 5 个圆点 = 9 笔填充；current=2 时只有 i=3,4 两个未到节点，
  // 各一圈描边（i<2 已完成填实、i=2 是当前步也填实）
  assert_eq((fills, strokes), (9, 2))
  assert_true(all > 9)
  // 点第 4 个节点（cell=80，中心 280）
  let seen : Array[Int32] = []
  st.on_change(fn(i) { seen.push(i) })
  let t = @moonui.EventTarget::of(st.widget().handle().unwrap())
  let _ = st
    .widget()
    .fire(
      @moonui.MouseDown(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(280.0, 10.0),
        @moonui.Mods::none(),
      ),
    )
  let _ = st
    .widget()
    .fire(
      @moonui.MouseUp(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(280.0, 10.0),
        @moonui.Mods::none(),
      ),
    )
  assert_eq(st.current(), 3)
  assert_eq(seen, [3])
  // 键盘右移一步；左移回来
  let _ = st.widget().fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(st.current(), 4)
  let _ = st.widget().fire(@moonui.KeyDown(t, ui_test_key("Left")))
  assert_eq(st.current(), 3)
  // 到端夹住：再右移不动、也不回调
  let _ = st.widget().fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(st.current(), 4)
  let _ = st.widget().fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(st.current(), 4)
  assert_eq(seen, [3, 4, 3, 4])
  // 换主题不丢当前步
  st.set_theme(@widgets.UiTheme::dark())
  assert_eq(st.current(), 4)
  b.terminate()
}

///|
test "UiBreadcrumb：项与分隔符各一笔、点项回调项号（T360）" {
  let b = mock()
  let items : Array[String] = ["首页", "文档", "控件"]
  let crumb = @widgets.UiBreadcrumb(b, items)
  assert_eq(crumb.count(), 3)
  assert_eq(crumb.item(1), "文档")
  let dl = place(b, crumb.widget())
  // 3 项 + 2 个分隔符 = 5 笔文本
  let mut texts = 0
  for cmd in dl.commands() {
    match cmd {
      @moonui.Text(_, _, _, _, _, _) => texts = texts + 1
      _ => ()
    }
  }
  assert_eq(texts, 5)
  // 点第一项：x 落在 [0, 首页宽] 内
  let seen : Array[Int32] = []
  crumb.on_select(fn(i) { seen.push(i) })
  let t = @moonui.EventTarget::of(crumb.widget().handle().unwrap())
  let _ = crumb
    .widget()
    .fire(
      @moonui.MouseUp(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(4.0, 10.0),
        @moonui.Mods::none(),
      ),
    )
  assert_eq(seen, [0])
  // 项表换了：宽度与文字跟着变
  crumb.set_items(["a", "b"])
  assert_eq(crumb.count(), 2)
  let dl2 = ui_test_redraw(b, crumb.widget())
  let (first, _, _, _) = ui_test_text(dl2)
  assert_eq(first, "a")
  b.terminate()
}

///|
test "UiPagination：槽位省略号规则、翻页回调、到端不动（T360）" {
  let b = mock()
  let pg = @widgets.UiPagination(b, total=20, current=10)
  // 首 + … + 9,10,11 + … + 末
  assert_eq(pg.slots(), [1, 0, 9, 10, 11, 0, 20])
  // 9 格 × 32 + 8 × 4 = 320
  assert_true(near(pg.widget().intrinsic_size().width, 320.0))
  let seen : Array[Int32] = []
  pg.on_change(fn(p) { seen.push(p) })
  let t = @moonui.EventTarget::of(pg.widget().handle().unwrap())
  // 点"下一页"：最后一格中心 x = 8×36+16 = 304
  let _ = pg
    .widget()
    .fire(
      @moonui.MouseDown(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(304.0, 16.0),
        @moonui.Mods::none(),
      ),
    )
  let _ = pg
    .widget()
    .fire(
      @moonui.MouseUp(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(304.0, 16.0),
        @moonui.Mods::none(),
      ),
    )
  assert_eq(pg.current(), 11)
  assert_eq(seen, [11])
  // 点省略号（第 3 格，0=上一页 / 1=页码 1 / 2=省略号，中心 x = 2×36+16 = 88）：
  // 不翻页、不回调
  let _ = pg
    .widget()
    .fire(
      @moonui.MouseDown(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(88.0, 16.0),
        @moonui.Mods::none(),
      ),
    )
  let _ = pg
    .widget()
    .fire(
      @moonui.MouseUp(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(88.0, 16.0),
        @moonui.Mods::none(),
      ),
    )
  assert_eq(pg.current(), 11)
  assert_eq(seen, [11])
  // 键盘左移一页
  let _ = pg.widget().fire(@moonui.KeyDown(t, ui_test_key("Left")))
  assert_eq(pg.current(), 10)
  // 到端：末页再往后不动
  pg.set_current(20)
  assert_eq(pg.current(), 20)
  let _ = pg.widget().fire(@moonui.KeyDown(t, ui_test_key("Right")))
  assert_eq(pg.current(), 20)
  // 页数缩到 5：槽位全列，宽度跟着缩（7 格 × 32 + 6 × 4 = 248）
  pg.set_total(5)
  assert_eq(pg.slots(), [1, 2, 3, 4, 5])
  assert_true(near(pg.widget().intrinsic_size().width, 248.0))
  b.terminate()
}

///|
test "UiRate：五颗星五条多边形、亮暗跟值、悬停预览不写值（T360）" {
  let b = mock()
  let rate = @widgets.UiRate(b, value=3)
  assert_eq(rate.value(), 3)
  assert_true(near(rate.widget().intrinsic_size().width, 116.0))
  let dl = place(b, rate.widget())
  let colors : Array[Int32] = []
  for cmd in dl.commands() {
    match cmd {
      @moonui.FillPolygon(pts, rgb, _) => {
        assert_eq(pts.length(), 10)
        colors.push(rgb)
      }
      _ => ()
    }
  }
  let lt = @widgets.UiTheme::light()
  assert_eq(colors.length(), 5)
  assert_eq(colors[0], lt.warning)
  assert_eq(colors[2], lt.warning)
  assert_eq(colors[3], lt.track)
  // 悬停预览：扫到第 2 颗，绘制亮到第 2 颗，但 value 不动
  let t = @moonui.EventTarget::of(rate.widget().handle().unwrap())
  let _ = rate
    .widget()
    .fire(@moonui.MouseMove(t, @moonui.LogicalPoint(30.0, 10.0)))
  assert_eq(rate.hover(), 1)
  assert_eq(rate.value(), 3)
  let dl2 = ui_test_redraw(b, rate.widget())
  let mut lit = 0
  for cmd in dl2.commands() {
    match cmd {
      @moonui.FillPolygon(_, rgb, _) => if rgb == lt.warning { lit = lit + 1 }
      _ => ()
    }
  }
  assert_eq(lit, 2)
  let _ = rate.widget().fire(@moonui.MouseLeave(t))
  assert_eq(rate.hover(), -1)
  // 点第 5 颗：step = 24，第 5 颗 x ∈ [96,116] → 点 106
  let seen : Array[Int32] = []
  rate.on_change(fn(v) { seen.push(v) })
  let _ = rate
    .widget()
    .fire(
      @moonui.MouseUp(
        t,
        @moonui.Left,
        @moonui.LogicalPoint(106.0, 10.0),
        @moonui.Mods::none(),
      ),
    )
  assert_eq(rate.value(), 5)
  assert_eq(seen, [5])
  // 键盘左减一星
  let _ = rate.widget().fire(@moonui.KeyDown(t, ui_test_key("Left")))
  assert_eq(rate.value(), 4)
  b.terminate()
}
