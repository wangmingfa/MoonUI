///|
/// ABI 判定表的无头判据（`T143`）。
///
/// 这些判据的价值在**它们不需要宿主**：零真窗口、零真鼠标、零平台 C，wasm
/// 门就跑了。此前这套判定只活在 `native_on_mouse` 的闭包身体里，一条判据都没有——
/// `T141`（kind 3 没人认领，`on_double_click` 在原生后端上从来没有事件源）
/// 正是从这里漏出去的，而它要真窗口加真鼠标才看得见。
///
/// 每条判据旁边都标了它挡的是哪一类缺口，因为这堆断言本身看不出主次。

///|
fn h(id : Int32) -> @moonui.NativeHandle {
  @moonui.NativeHandle::{ id, generation: 1, }
}

///|
/// 便捷包装：只给命中的控件，没有窗口、没有 owner 第二本账。
fn at_target(
  kb : Int32,
  id : Int32,
  custom? : Bool,
) -> @native-abi.MouseDecision {
  @native-abi.mouse_decision(
    kb,
    Some(h(id)),
    None,
    None,
    custom.unwrap_or(false),
    false,
  )
}

///|
test "ABI 判据：kind*8+button 拆包，负值不漏出负按钮号（T143）" {
  // 词表内的四格：kind 0..3 配 button 0..2
  assert_eq(@native-abi.split_kind_button(0), { kind: 0, button: 0, })
  assert_eq(@native-abi.split_kind_button(1), { kind: 0, button: 1, })
  assert_eq(@native-abi.split_kind_button(8), { kind: 1, button: 0, })
  assert_eq(@native-abi.split_kind_button(24), { kind: 3, button: 0, })
  assert_eq(@native-abi.split_kind_button(38), { kind: 4, button: 6, })
  // 负数：C 侧把 `int` 递过来时能到。button 必须非负，kind 跟着落到负数那一档，
  // 判定表里没有分支认它 → 整条丢掉（不在拆包这一步崩）。
  assert_eq(@native-abi.split_kind_button(-1), { kind: -1, button: 7, })
  assert_eq(@native-abi.split_kind_button(-8), { kind: -1, button: 0, })
}

///|
test "ABI 判据：kind 3 双击真产 DoubleClick——T141 漏的那一支（T143）" {
  // 这是本包存在的第一条理由。`T141` 之前 kind 3 落在"右键按下"和"自绘面左键"
  // 两支都不认的地方，整条丢掉，于是 `on_double_click` 在原生后端上永远不响，
  // 而自绘后端（canvas-macos）译了它——两个后端行为不一致，只有真窗口加真鼠标
  // 才能发现。
  assert_eq(at_target(24, 7), @native-abi.MouseDecision::DoubleTo(h(7)))
  // 双击不看控件种类：普通控件与自绘面同样产 DoubleClick
  assert_eq(
    at_target(24, 7, custom=true),
    @native-abi.MouseDecision::DoubleTo(h(7)),
  )
  // 但空白处的双击仍然丢掉（没有 Core 侧消费者，不猜"那应该是窗口吧"）
  assert_eq(
    @native-abi.mouse_decision(24, None, None, None, false, false),
    @native-abi.MouseDecision::Drop,
  )
}

///|
test "ABI 判据：右键只认按下那一支，左键按下不重复建（T143）" {
  // kind 0 button 1 = 右键按下 → MouseDown(Right)
  assert_eq(
    at_target(1, 7),
    @native-abi.MouseDecision::PressTo(h(7), @moonui.Right),
  )
  // 右键**抬起**（kind 1 button 1）没有消费者：Core 的右键菜单在按下时就开
  assert_eq(at_target(9, 7), @native-abi.MouseDecision::Drop)
  // 左键按下落在**非自绘面**上 → 丢掉。它的消费者是控件回调自己发的 Click，
  // 这里再建一条就重复了（也会惊动 `T86⑧` 的长按识别账）。
  assert_eq(at_target(0, 7), @native-abi.MouseDecision::Drop)
}

///|
test "ABI 判据：自绘面的左键按下/抬起进 Core，键位恒报 Left（T143）" {
  // `T110` 开的口：自绘面没有原生事件源，左键此前只有一条不带坐标的 Click，
  // "点表头排序"这类接线做不了。
  assert_eq(
    at_target(0, 7, custom=true),
    @native-abi.MouseDecision::PressTo(h(7), @moonui.Left),
  )
  assert_eq(
    at_target(8, 7, custom=true),
    @native-abi.MouseDecision::ReleaseTo(h(7), @moonui.Left),
  )
  // **中键在自绘面上也报 Left**——这条判据钉的是"这一轮是搬运、不是改行为"：
  // 原闭包那一支从来没读过 button 位（`kb / 8 == 0 || kb / 8 == 1` 就往下走，
  // 键位写死 `Left`），C 侧报的 kind 0 button 2（mac 的 OtherMouseDown）于是
  // 也落到 Left。谁将来接中键，先改这条判据、再改表。
  assert_eq(
    at_target(2, 7, custom=true),
    @native-abi.MouseDecision::PressTo(h(7), @moonui.Left),
  )
}

///|
test "ABI 判据：右键按下排在自绘面左键前面，自绘面上按右键仍走 Right（T143）" {
  // 分支顺序是有行为意义的东西，不是风格：若把"自绘面 kind 0/1"那支提到前面，
  // 自绘面上的右键会被当成 Left 按下——`T110` 的接线于是收到错的键。
  assert_eq(
    at_target(1, 7, custom=true),
    @native-abi.MouseDecision::PressTo(h(7), @moonui.Right),
  )
}

///|
test "ABI 判据：悬停 kind 2 / 离开 kind 5 同落点，空白处报窗口（T143）" {
  // 悬停在控件上 → 报控件
  assert_eq(at_target(16, 7), @native-abi.MouseDecision::MoveTo(h(7)))
  // 离开窗口（kind 5，`T98①` 从 kind 3 挪出来的那一格）→ 同样报控件；
  // "离开了"由 Core 从目标变化里合成，后端只说"现在在谁身上"
  assert_eq(at_target(40, 7), @native-abi.MouseDecision::MoveTo(h(7)))
  // 空白处的移动/离开 → 报**窗口自己**，Core 拿"target 是窗口"当 unhover 信号
  assert_eq(
    @native-abi.mouse_decision(16, None, Some(h(3)), None, false, false),
    @native-abi.MouseDecision::MoveTo(h(3)),
  )
  // 控件与窗口都不认识 → 丢
  assert_eq(
    @native-abi.mouse_decision(16, None, None, None, false, false),
    @native-abi.MouseDecision::Drop,
  )
}

///|
test "ABI 判据：滚轮三级退，只有 owner 是自绘面才改判（T143）" {
  // ① 命中控件 → 报控件（自绘面或原生控件都一样，命中优先）
  assert_eq(at_target(32, 7), @native-abi.MouseDecision::WheelTo(h(7)))
  // ② 空白处 + owner 是自绘面 → 改判给自绘面。`T102` 第八刀的缺口：自绘面
  //    没有原生滚动容器，除了这条没有别的路能收到滚轮。
  assert_eq(
    @native-abi.mouse_decision(32, None, Some(h(3)), Some(h(9)), false, true),
    @native-abi.MouseDecision::WheelTo(h(9)),
  )
  // ③ 空白处 + owner **不是**自绘面 → 仍归窗口。原生控件的滚轮照旧归窗口
  //    （被 NSScrollView 之类自己吃掉），"滚轮调音量"这类整窗手势依赖这条。
  assert_eq(
    @native-abi.mouse_decision(32, None, Some(h(3)), Some(h(9)), false, false),
    @native-abi.MouseDecision::WheelTo(h(3)),
  )
  // ④ 全空 → 丢
  assert_eq(
    @native-abi.mouse_decision(32, None, None, None, false, false),
    @native-abi.MouseDecision::Drop,
  )
}

///|
test "ABI 判据：词表外的 kind 整条丢掉，不猜（T143）" {
  // adapter.h 只定义 kind 0..5。表外的值（含负数）一个分支都不认 → Drop，
  // 于是将来 C 侧加了新编码而这里没跟上时，行为是"安静丢掉"而不是"派成某个
  // 已有的动作"。
  assert_eq(at_target(48, 7), @native-abi.MouseDecision::Drop) // kind 6
  assert_eq(at_target(56, 7), @native-abi.MouseDecision::Drop) // kind 7
  assert_eq(at_target(-8, 7), @native-abi.MouseDecision::Drop) // kind -1
}

///|
test "ABI 判据：只有滚轮要 owner 第二本账（T143）" {
  // owner 的反查沿存活控件线性扫，而移动是最高频事件——别的编码一律不问。
  assert_true(@native-abi.needs_owner(32)) // kind 4 wheel
  for kb in [0, 1, 8, 16, 24, 40] {
    assert_false(@native-abi.needs_owner(kb))
  }
}

///|
test "ABI 判据：手势相位与滑动方向的词表（T143）" {
  // 相位：0 began / 2 ended / 3 cancelled；1 与**表外**都按 Changed——那是
  // "这一步的增量"最保守的一档，不把来路不明的读数说成开始或结束。
  assert_eq(@native-abi.gesture_phase(0), @moonui.GesturePhase::Began)
  assert_eq(@native-abi.gesture_phase(1), @moonui.GesturePhase::Changed)
  assert_eq(@native-abi.gesture_phase(2), @moonui.GesturePhase::Ended)
  assert_eq(@native-abi.gesture_phase(3), @moonui.GesturePhase::Cancelled)
  assert_eq(@native-abi.gesture_phase(99), @moonui.GesturePhase::Changed)
  // 方向：0 左 / 1 右 / 2 上 / 3 下；表外按左
  assert_eq(@native-abi.swipe_direction(0), @moonui.SwipeDirection::Left)
  assert_eq(@native-abi.swipe_direction(1), @moonui.SwipeDirection::Right)
  assert_eq(@native-abi.swipe_direction(2), @moonui.SwipeDirection::Up)
  assert_eq(@native-abi.swipe_direction(3), @moonui.SwipeDirection::Down)
  assert_eq(@native-abi.swipe_direction(9), @moonui.SwipeDirection::Left)
}

///|
test "ABI 判据：修饰键位掩码的四格进格（T102 第二十三刀）" {
  // 与键盘那半同一张表：bit0 ctrl / bit1 alt / bit2 shift / bit3 meta。
  let none = @native-abi.mods_of_bits(0)
  assert_false(none.ctrl && none.alt && none.shift && none.meta)
  let shift = @native-abi.mods_of_bits(4)
  assert_true(shift.shift)
  assert_false(shift.ctrl || shift.alt || shift.meta)
  let cmd = @native-abi.mods_of_bits(8)
  assert_true(cmd.meta)
  assert_false(cmd.ctrl || cmd.alt || cmd.shift)
  let combo = @native-abi.mods_of_bits(1 | 4 | 8)
  assert_true(combo.ctrl && combo.shift && combo.meta)
  assert_false(combo.alt)
  // 表外位如实忽略：bit5 之类不认作任何一格
  let odd = @native-abi.mods_of_bits(32)
  assert_false(odd.ctrl || odd.alt || odd.shift || odd.meta)
}

///|
/// 打包 helper（`T169`）：照 adapter.h 输出设备段现编一份小端包。
fn i32le_bytes(v : Int32) -> Array[Byte] {
  [v.to_byte(), (v >> 8).to_byte(), (v >> 16).to_byte(), (v >> 24).to_byte()]
}

///|
fn pack_outputs(count : Int32, current : Int32, names : Array[String]) -> Bytes {
  let mut out = Bytes::from_array(i32le_bytes(count) + i32le_bytes(current))
  for name in names {
    let b = @utf8.encode(name)
    out = out.add(Bytes::from_array(i32le_bytes(b.length())))
    out = out.add(b)
  }
  out
}

///|
test "ABI 判据：输出设备包解码——全部设备名 + 当前下标（T169）" {
  let p = pack_outputs(2, 1, ["内置扬声器", "AirPods Pro"])
  let r = @native-abi.decode_audio_outputs_packet(p)
  assert_eq(r.devices, ["内置扬声器", "AirPods Pro"])
  assert_eq(r.current, 1)
}

///|
test "ABI 判据：空包（Windows 空桩那格 [0][-1]）降级为空表 + 无当前（T169）" {
  let r = @native-abi.decode_audio_outputs_packet(pack_outputs(0, -1, []))
  assert_eq(r.devices, [])
  assert_eq(r.current, -1)
  // 短包（不足 8）：同一格——调用方对两者处理相同
  let short = @native-abi.decode_audio_outputs_packet(
    Bytes::from_array([0, 0, 0, 0]),
  )
  assert_eq(short.devices, [])
  assert_eq(short.current, -1)
}

///|
test "ABI 判据：布局坏了一项丢一项，current 不因尾部损坏丢失（T169）" {
  // count 记 3 但只装得下 2 项 → 返回前 2 项；头部完好，current 原样带出
  let mut p = pack_outputs(3, 0, ["外接", "HDMI"])
  p = p.add(Bytes::from_array(i32le_bytes(999))) // 第三项只有长度没有内容
  let r = @native-abi.decode_audio_outputs_packet(p)
  assert_eq(r.devices, ["外接", "HDMI"])
  assert_eq(r.current, 0)
  // 长度为负：同一格，到此为止
  let neg = Bytes::from_array(
    i32le_bytes(1) + i32le_bytes(-1) + i32le_bytes(-4),
  )
  let rn = @native-abi.decode_audio_outputs_packet(neg)
  assert_eq(rn.devices, [])
  assert_eq(rn.current, -1)
}

///|
/// ---------------------------------------------------------------------------
/// `T230`：native-common 抽出判定表的无头判据
/// ---------------------------------------------------------------------------
///
/// 这些算式此前一条判据都没有（整包 native-only，见 native_abi.mbt 的段注）。
/// 每组 packed 都是**手算的位布局**——高 32 位在前、低 32 位在后，用移位+OR
/// 独立构造，不复用被验函数、也不经它自己的 pack，避免两边同带一个 bug 互相
/// 印证着通过。负坐标与 INT32 边界是重点。

///|
fn kind_code_or(k : @moonui.WidgetKind, fallback : Int32) -> Int32 {
  @native-abi.widget_kind_code(k) catch {
    _ => fallback
  }
}

///|
fn kind_error(k : @moonui.WidgetKind) -> String {
  try {
    let _ = @native-abi.widget_kind_code(k)
    "没有报错"
  } catch {
    @moonui.Unsupported(m) => "UN:\{m}"
    @moonui.OperationFailed(m) => "OF:\{m}"
    _ => "别的错"
  }
}

///|
test "ABI 判据：Int64 拆成两个 int32，负数与 INT32 边界不丢符号（T230）" {
  assert_eq(@native-abi.unpack_i32_pair(0L), (0, 0))
  assert_eq(@native-abi.unpack_i32_pair((1L << 32) | 2L), (1, 2))
  assert_eq(@native-abi.unpack_i32_pair((-5L << 32) | 7L), (-5, 7))
  assert_eq(@native-abi.unpack_i32_pair((5L << 32) | 0xFFFFFFFAL), (5, -6))
  assert_eq(
    @native-abi.unpack_i32_pair((1L << 32) | 0x80000000L),
    (1, -2147483648),
  )
  assert_eq(
    @native-abi.unpack_i32_pair((-1L << 32) | 0x7FFFFFFFL),
    (-1, 2147483647),
  )
  assert_eq(@native-abi.unpack_i32_pair(-1L), (-1, -1))
}

///|
/// 整张码表 28 格全过一遍：13 个有效格、7 个纯布局节点、8 个专属入口。
/// 6..12 是**空洞**，任何"顺手补上"的改动都会撞上 Unsupported 断言。
test "ABI 判据：widget kind → 适配器整型码整张表（T230）" {
  assert_eq(kind_code_or(@moonui.Label, -999), 0)
  assert_eq(kind_code_or(@moonui.Button, -999), 1)
  assert_eq(kind_code_or(@moonui.TextInput, -999), 2)
  assert_eq(kind_code_or(@moonui.Checkbox, -999), 3)
  assert_eq(kind_code_or(@moonui.PasswordInput, -999), 4)
  assert_eq(kind_code_or(@moonui.Separator, -999), 5)
  assert_eq(kind_code_or(@moonui.VSeparator, -999), 13)
  assert_eq(kind_code_or(@moonui.MenuRow, -999), 14)
  assert_eq(kind_code_or(@moonui.Scroll, -999), 15)
  assert_eq(kind_code_or(@moonui.Image, -999), 16)
  assert_eq(kind_code_or(@moonui.Panel, -999), 17)
  assert_eq(kind_code_or(@moonui.Custom, -999), 18)
  // Windows 半没有 WKWebView，码表仍要报 19（缺席由下游 register 如实报）
  assert_eq(kind_code_or(@moonui.WebView, -999), 19)
  // 7 个纯布局节点：不占原生对象，一个码都不该给
  // 数组字面量没有类型上下文，构造子要写全限定：`Spacer` / `Center` 等
  // 同时是 `WidgetKind` 与 `LayoutSpec` 的变体，裸写会报 4124 ambiguous。
  for
    k in [
      @moonui.WidgetKind::Row,
      @moonui.WidgetKind::Column,
      @moonui.WidgetKind::Padding,
      @moonui.WidgetKind::Spacer,
      @moonui.WidgetKind::Center,
      @moonui.WidgetKind::Stack,
      @moonui.WidgetKind::Grid,
    ] {
    assert_eq(kind_code_or(k, -999), -999)
  }
  // 8 个走专属创建入口的叶子：一样不给码
  for
    k in [
      @moonui.WidgetKind::Slider,
      @moonui.WidgetKind::Spinbox,
      @moonui.WidgetKind::Progress,
      @moonui.WidgetKind::ComboBox,
      @moonui.WidgetKind::MultilineEntry,
      @moonui.WidgetKind::RadioButtons,
      @moonui.WidgetKind::DatePicker,
      @moonui.WidgetKind::Sized,
    ] {
    assert_eq(kind_code_or(k, -999), -999)
  }
}

///|
/// 上一格只验"没给码"，这一格验**报的是哪一种错、文本是什么**：两族不能混，
/// 也不能拿 OperationFailed 冒充 Unsupported。
test "ABI 判据：布局节点与专属入口各自报 Unsupported，不猜码（T230）" {
  let layout = "UN:纯布局节点（Row/Column/…）不占原生对象"
  assert_eq(kind_error(@moonui.Row), layout)
  assert_eq(kind_error(@moonui.Grid), layout)
  let dedicated = "UN:这个控件种类走专属的创建入口，不走 moonui_native_widget_new"
  assert_eq(kind_error(@moonui.Slider), dedicated)
  assert_eq(kind_error(@moonui.DatePicker), dedicated)
  // Sized 在今天的实现里落在 `_` 分支，不是布局分支——钉实际行为
  assert_eq(kind_error(@moonui.Sized), dedicated)
}

///|
/// `check_rc`：0 是唯一成功值，正 rc 也算失败（不只是 -1/-2/-3 那几个桩码）。
test "ABI 判据：返回码 → UiError，正 rc 同样失败（T230）" {
  let ok = try {
    @native-abi.check_rc(0, "画布 开帧")
    "没报错"
  } catch {
    _ => "抛了"
  }
  assert_eq(ok, "没报错")
  let msg = try {
    @native-abi.check_rc(-2, "画布 贴图")
    "没报错"
  } catch {
    @moonui.OperationFailed(m) => "OF:\{m}"
    _ => "别的错"
  }
  assert_eq(msg, "OF:画布 贴图 失败（rc=-2）")
  let msg2 = try {
    @native-abi.check_rc(3, "画布 上屏")
    "没报错"
  } catch {
    @moonui.OperationFailed(m) => "OF:\{m}"
    _ => "别的错"
  }
  assert_eq(msg2, "OF:画布 上屏 失败（rc=3）")
}

///|
/// 两处 Int64 拆包的口径**不一样**：`unpack_i32_pair` 低位当有符号，
/// `unpack_measure_text` 低位当无符号。这条同时钉住两边，防止有人顺手统一。
test "ABI 判据：measure_text 拆包低位无符号，与窗口二元组拆包有符号（T230）" {
  assert_eq(@native-abi.unpack_measure_text(0L), (0.0, 0.0))
  assert_eq(@native-abi.unpack_measure_text((100L << 32) | 40L), (100.0, 40.0))
  assert_eq(@native-abi.unpack_measure_text(0xFFFFFFFFL), (0.0, 4294967295.0))
  assert_eq(@native-abi.unpack_measure_text((-1L << 32) | 12L), (-1.0, 12.0))
  // 同一个 packed 在两种拆包下结果不同：-1 与 4294967295
  assert_eq(@native-abi.unpack_i32_pair(0xFFFFFFFFL), (0, -1))
}

///|
/// ---------------------------------------------------------------------------
/// `T236`：从 native-common 搬来的返回码翻译与位拆包，判据随包进 wasm 门
/// ---------------------------------------------------------------------------
///
/// 这里的期望值都是**逐字抄自搬迁前 ffi.mbt 的分支**：文案不改、码不改，
/// 所以判据红就说明有人改了行为，而不是"重构顺手美化了一下"。

///|
fn stage_rc_or(rc : Int32) -> String {
  try {
    @native-abi.check_two_stage_rc(rc, "第一类故障", "第二类故障")
    "没报错"
  } catch {
    @moonui.OperationFailed(m) => "OF:\{m}"
    _ => "别的错"
  }
}

///|
fn answer_rc_or(rc : Int32) -> String {
  try {
    let ans = @native-abi.dialog_answer_rc(
      rc, "文案没交给系统", "没弹出来",
    )
    if ans {
      "选中"
    } else {
      "取消"
    }
  } catch {
    @moonui.OperationFailed(m) => "OF:\{m}"
    _ => "别的错"
  }
}

///|
test "ABI 判据：三档返回码 0 是唯一成功值，-1 与其余两档不混（T236）" {
  assert_eq(stage_rc_or(0), "没报错")
  assert_eq(stage_rc_or(-1), "OF:第一类故障")
  assert_eq(stage_rc_or(-2), "OF:第二类故障")
  assert_eq(stage_rc_or(-3), "OF:第二类故障")
  // 正 rc 同样是失败，且只能落第二档（写成 rc < 0 就整条不报错）
  assert_eq(stage_rc_or(1), "OF:第二类故障")
  assert_eq(stage_rc_or(3), "OF:第二类故障")
  assert_eq(stage_rc_or(2147483647), "OF:第二类故障")
  assert_eq(stage_rc_or(-2147483648), "OF:第二类故障")
}

///|
test "ABI 判据：对话框四态里 1/0 是答案不是成功码（T236）" {
  assert_eq(answer_rc_or(1), "选中")
  assert_eq(answer_rc_or(0), "取消")
  assert_eq(answer_rc_or(-1), "OF:文案没交给系统")
  assert_eq(answer_rc_or(-2), "OF:没弹出来")
  assert_eq(answer_rc_or(2), "OF:没弹出来")
  assert_eq(answer_rc_or(-2147483648), "OF:没弹出来")
}

///|
test "ABI 判据：窗口态只认 bit0 / bit1，其余位忽略（T236）" {
  assert_eq(@native-abi.window_state_of_bits(0), @moonui.WindowState::{
    minimized: false,
    maximized: false,
  })
  assert_eq(@native-abi.window_state_of_bits(1), @moonui.WindowState::{
    minimized: true,
    maximized: false,
  })
  assert_eq(@native-abi.window_state_of_bits(2), @moonui.WindowState::{
    minimized: false,
    maximized: true,
  })
  assert_eq(@native-abi.window_state_of_bits(3), @moonui.WindowState::{
    minimized: true,
    maximized: true,
  })
  // 4 及以上是 C 侧没置过的位：不能因为"非 0"就认成最小化
  assert_eq(@native-abi.window_state_of_bits(4), @moonui.WindowState::{
    minimized: false,
    maximized: false,
  })
  assert_eq(@native-abi.window_state_of_bits(7), @moonui.WindowState::{
    minimized: true,
    maximized: true,
  })
}

///|
test "ABI 判据：图像探针高在 bit32..47，不是旧注释写的 24..39（T236）" {
  assert_eq(@native-abi.unpack_image_probe(0L), (false, 0, 0))
  assert_eq(@native-abi.unpack_image_probe(1L), (true, 0, 0))
  assert_eq(
    @native-abi.unpack_image_probe(1L | (320L << 8) | (240L << 32)),
    (true, 320, 240),
  )
  // 宽高各占 16 位、互不串位
  assert_eq(
    @native-abi.unpack_image_probe(1L | (0xFFFFL << 8) | (0xFFFFL << 32)),
    (true, 65535, 65535),
  )
  // 旧注释说"24..39 位是像素高"：往 bit24 塞一个数，高必须仍是 0
  assert_eq(@native-abi.unpack_image_probe(1L | (9L << 24)), (true, 0, 0))
}

///|
test "ABI 判据：宿主码表只认 1/2，其余降级 Unknown（T236）" {
  assert_eq(@native-abi.host_platform_of_code(1), @moonui.Macos)
  assert_eq(@native-abi.host_platform_of_code(2), @moonui.Windows)
  assert_eq(@native-abi.host_platform_of_code(0), @moonui.Unknown)
  assert_eq(@native-abi.host_platform_of_code(3), @moonui.Unknown)
  assert_eq(@native-abi.host_platform_of_code(-1), @moonui.Unknown)
  assert_eq(@native-abi.host_platform_of_code(2147483647), @moonui.Unknown)
}

///|
test "ABI 判据：无障碍状态位包 bit0/1/2-3，checked 三态不串（T236）" {
  assert_eq(
    @native-abi.access_state_code(@moonui.AccessState::{
      visible: false,
      enabled: false,
      checked: None,
    }),
    0,
  )
  assert_eq(
    @native-abi.access_state_code(@moonui.AccessState::{
      visible: true,
      enabled: false,
      checked: None,
    }),
    1,
  )
  assert_eq(
    @native-abi.access_state_code(@moonui.AccessState::{
      visible: false,
      enabled: true,
      checked: None,
    }),
    2,
  )
  assert_eq(
    @native-abi.access_state_code(@moonui.AccessState::{
      visible: true,
      enabled: true,
      checked: None,
    }),
    3,
  )
  assert_eq(
    @native-abi.access_state_code(@moonui.AccessState::{
      visible: false,
      enabled: false,
      checked: Some(false),
    }),
    4,
  )
  assert_eq(
    @native-abi.access_state_code(@moonui.AccessState::{
      visible: false,
      enabled: false,
      checked: Some(true),
    }),
    8,
  )
  assert_eq(
    @native-abi.access_state_code(@moonui.AccessState::{
      visible: true,
      enabled: true,
      checked: Some(true),
    }),
    11,
  )
}
