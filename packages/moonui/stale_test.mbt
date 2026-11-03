// `T198` 最新一轮为准的请求账（`StaleBox`）的黑盒判据。
//
// 这只账的三条判据都来自真窗上的事故形状：旧结果盖掉新结果、连点发两趟、
// 关窗重开之后上一轮的结果落进新窗。三条各自一条测试，用的是同一只账。

///|
/// 连点挡板只挡"同一个人"：身份不同必须发得出去。
///
/// 真窗上的形状（`T163`①）：打开搜索窗会自动查一轮，那一轮还在路上时用户改了
/// 名字再点「查询」——必须发得出去，否则得等上一轮回来才动得了；而那一轮的
/// 结果本来就会被下面的落地比对整轮丢掉。
test "StaleBox：挡连点只挡同一身份，换了名字照样发（T198）" {
  let stale : @moonui.StaleBox[(String, String)] = @moonui.StaleBox::new()
  assert_false(stale.has_key())
  assert_false(stale.is_pending())
  assert_false(stale.pending_same(("晴天", "周杰伦")))
  let _ = stale.issue(("晴天", "周杰伦"))
  assert_true(stale.has_key())
  assert_true(stale.is_pending())
  assert_true(stale.pending_same(("晴天", "周杰伦")))
  assert_false(stale.pending_same(("晴天", "翻唱")))
  // 落地即结账：同一身份再问就不再挡了
  let gen = stale.issue(("晴天", "翻唱"))
  assert_true(stale.land(gen))
  assert_false(stale.is_pending())
  assert_false(stale.pending_same(("晴天", "翻唱")))
}

///|
/// 最新一轮为准：**A → B → A** 之后，第一轮 A 的结果必须作废。
///
/// 这一条是"按轮次戳比对"与"按身份值比对"唯一分得开的地方，也是这只账存在的
/// 理由：三连之后当前身份又是 `("晴天", "周杰伦")`，按身份比对会把第一轮的
/// 结果当成当前那一轮收下（用旧结果盖了新结果）；轮次戳不会。
///
/// 负控制：把 `land` 里的 `gen != self.gen` 换成"身份值与这一轮相同"，上面那一
/// 句 `land(g1)` 会返回真——判据红在"旧结果被收下"。
test "StaleBox：A→B→A 之后第一轮 A 的落点仍然作废（T198）" {
  let stale : @moonui.StaleBox[(String, String)] = @moonui.StaleBox::new()
  let g1 = stale.issue(("晴天", "周杰伦"))
  let g2 = stale.issue(("晴天", "翻唱"))
  let g3 = stale.issue(("晴天", "周杰伦"))
  // 第一轮的结果现在回来：身份与当前相同，轮次早就不是它
  assert_false(stale.land(g1))
  assert_false(stale.land(g2))
  assert_true(stale.land(g3))
  // 同一轮重复落地只认第一次
  assert_false(stale.land(g3))
}

///|
/// `reset` 清账，并让**在飞的那一轮**作废（关窗重开时上一轮的结果不该落进新窗）。
///
/// 只清身份不清轮次是不够的：在飞那一轮的号还对得上，落地时会被当成当前。
/// 真窗上的形状：关掉搜索窗再打开，上一轮的网络请求此时回来，把结果塞进新窗的
/// 列表——新窗明明"还没查过"。
test "StaleBox：reset 之后回到还没问过，在飞那一轮的落点作废（T198）" {
  let stale : @moonui.StaleBox[String] = @moonui.StaleBox::new()
  let in_flight = stale.issue("晴天")
  assert_true(stale.has_key())
  stale.reset()
  assert_false(stale.has_key())
  assert_false(stale.is_pending())
  // 真窗形状：清账之后立刻又问了一轮（新窗自动查一次），旧那一轮此时才回来。
  // 这一句必须在**新一轮在路上**的时候判——`in_flight` 为假时"不落地"是另一条
  // 理由（没人欠着落地），盖不住轮次比对。
  let fresh = stale.issue("晴天")
  assert_true(stale.has_key())
  assert_true(stale.is_pending())
  assert_false(stale.land(in_flight))
  assert_true(stale.land(fresh))
}
