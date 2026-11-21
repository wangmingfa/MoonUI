///|
/// Assets 图标解析的 mock 无头往返（`T339`）：注册的名字在所有平台都真
/// （注册表优先）；未注册的名字在 mock 上缺席（mock 无系统图标表，resolve
/// 的假只可能来自平台层）；缓存按名字记账——注册发生在探测之后再 resolve，
/// 注册表照样赢。
test "Assets：注册名恒真、未注册缺席、注册表优先于缓存（T339）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  @moonui.Assets::clear_for_test()
  // 未注册：平台（mock）缺席。
  assert_eq(@moonui.Assets::resolve(b, "app/rewind"), false)
  // 注册后：同一个名字再 resolve，注册表优先于"已缓存的缺席"。
  @moonui.Assets::register("app/rewind")
  assert_eq(@moonui.Assets::resolve(b, "app/rewind"), true)
  // 第二次 resolve 走注册表，结果仍真（幂等往返）。
  assert_eq(@moonui.Assets::resolve(b, "app/rewind"), true)
  // 没注册过的名字照走平台层：mock 无头，缺席。
  assert_eq(@moonui.Assets::resolve(b, "sf/play.fill"), false)
  // 抹掉重放：注册表还在（注册不是缓存），缺席的名字缓存清掉后仍缺席。
  @moonui.Assets::clear_for_test()
  assert_eq(@moonui.Assets::resolve(b, "app/rewind"), true)
  assert_eq(@moonui.Assets::resolve(b, "sf/play.fill"), false)
  @moonui.Backend::terminate(b)
}
