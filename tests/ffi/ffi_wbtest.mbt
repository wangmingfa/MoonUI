///|
/// FFI 闭环验证（只在 native 目标下编译，见 moon.pkg 的 targets 门控）。

///|
/// 钉住 `NativePtr(Int64)` 这个决定的前提：MoonBit 的 `Int` 只有 32 位，
/// 装不下 x64 指针。若哪天 `Int` 变成 64 位，这条断言会先失败。
test "Int 是 32 位，指针必须用 Int64 承载" {
  assert_eq(@int.MAX_VALUE, 2147483647)
  // 地址量级的值只有 Int64 装得下
  let addr = alloc_raw(9)
  assert_true(addr != 0L)
  assert_eq(@moonui.NativePtr(addr).0, addr)
  free_raw(addr)
}

///|
test "指针地址用 Int64 往返，double free 由 HandleTable 挡住" {
  let table = @moonui.HandleTable::new()
  let a = table.register(@moonui.NativePtr(alloc_raw(41)))
  let b = table.register(@moonui.NativePtr(alloc_raw(42)))
  // 两个不同对象的地址必须不同——若地址被截断成 32 位，这里就会撞车
  assert_true(table.resolve(a) != table.resolve(b))
  assert_eq(read_raw(table.resolve(a).0), 41)
  assert_eq(read_raw(table.resolve(b).0), 42)
  assert_eq(raw_live_count(), 2)

  // 先注销再释放：unregister 成功后才允许碰 C 的 free
  let NativePtr(addr_a) = table.resolve(a)
  table.unregister(a)
  free_raw(addr_a)
  assert_eq(raw_live_count(), 1)

  // 旧句柄已经换不回指针，所以不可能对同一地址 free 第二次
  let msg = try {
    let _ = table.resolve(a)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg, Some("无效的原生句柄"))
  let msg2 = try {
    table.unregister(a)
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg2, Some("对象已销毁"))

  let NativePtr(addr_b) = table.resolve(b)
  table.unregister(b)
  free_raw(addr_b)
  assert_eq(raw_live_count(), 0)
}

///|
test "空地址不会进入 Core，读侧被判为无效句柄" {
  let msg = try {
    ignore(read_raw(0L))
    None
  } catch {
    e => Some(@moonui.UiError::message(e))
  }
  assert_eq(msg, Some("无效的原生句柄"))
}

///|
test "external object 的显式释放与 finalizer 互不重复计数" {
  let before = live_objects()
  let o = new_object(7)
  assert_eq(live_objects(), before + 1)
  assert_eq(o.value(), 7)
  o.release()
  o.release()
  assert_eq(live_objects(), before)
  // 已释放的对象读回哨兵值，而不是崩溃
  assert_eq(o.value(), -1)
}

///|
test "UTF-8 字符串跨 FFI 往返" {
  assert_eq(utf8_byte_length("界面"), 6)
  assert_eq(utf8_byte_length("GUI, the MoonBit way."), 21)
  assert_eq(shout("界面"), "界面!")
  assert_eq(shout(""), "!")
  // emoji 是 4 字节，说明走的是 UTF-8 而非按字符数计长
  assert_eq(utf8_byte_length("👀"), 4)
}

///|
test "C 循环回调 MoonBit 闭包，捕获状态有效" {
  let mut sum = 0
  each(4, fn(i) { sum = sum + i })
  assert_eq(sum, 6)
  each(0, fn(i) { sum = sum + i })
  assert_eq(sum, 6)
}

///|
test "C 持有闭包期间不被 GC 回收" {
  let mut hits = 0
  store_callback(fn(v) { hits = hits + v })
  // 制造分配压力，逼 GC 走动；C 侧 incref 过，闭包必须还活着
  for i = 0; i < 3000; i = i + 1 {
    let junk = [i, i * 2, i * 3]
    assert_eq(junk.length(), 3)
  }
  assert_eq(fire_callback(3), 1)
  assert_eq(fire_callback(4), 1)
  assert_eq(hits, 7)
  clear_callback()
  assert_eq(fire_callback(1), -1)
}
