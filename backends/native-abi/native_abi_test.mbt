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
