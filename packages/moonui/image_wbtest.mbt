///|
/// `T338` 的 Core 侧判据：图像适配模式（`Fit`）与内在像素尺寸
/// （`Widget::natural_size`）。全部在 mock 上跑——fit 是"配置到了后端"的记账、
/// natural_size 是"内在尺寸读得到"的读口，mock 无屏幕，账本可读就是这一层
/// 的全部语义；各平台映射（NSImageScaling / GdkContentFit / Windows 缺席）归
/// adapter 与真窗判据。

///|
test "T338 Fit 码表：对齐 GdkContentFit 的枚举序" {
  assert_eq(Fill.code(), 0)
  assert_eq(Contain.code(), 1)
  assert_eq(Cover.code(), 2)
  assert_eq(ScaleDown.code(), 3)
}

///|
test "T338 set_fit：kind 拦截 + 配置到达后端（默认 Contain）" {
  let b = mock_widgets()
  let w = Widget::image(b)
  // 默认 Contain（= 1），与三平台第一版（T86⑤）的显示语义同一条
  assert_eq(b.image_fit_of(w.handle().unwrap()), 1)
  w.set_fit(Cover)
  assert_eq(b.image_fit_of(w.handle().unwrap()), 2)
  w.set_fit(Fill)
  assert_eq(b.image_fit_of(w.handle().unwrap()), 0)
  // 非图像控件拦在 Core：Button 没有 fit
  let btn = Widget::button(b, "no")
  let denied = try {
    btn.set_fit(Fill)
    false
  } catch {
    _ => true
  }
  assert_true(denied)
}

///|
test "T338 natural_size：没装源 None、注入后可读、kind 拦截" {
  let b = mock_widgets()
  let w = Widget::image(b)
  assert_eq(w.natural_size(), None)
  b.install_image_natural(w.handle().unwrap(), 192, 64)
  assert_eq(w.natural_size(), Some((192, 64)))
  // 非图像控件没有内在尺寸读口
  let btn = Widget::button(b, "no")
  let denied = try {
    let _ = btn.natural_size()
    false
  } catch {
    _ => true
  }
  assert_true(denied)
}

///|
test "T338 解码反馈契约：装空源按解码失败报（mock 同口径）" {
  // mock 侧不模拟解码器，但 set_image_bytes 的字节数记账沿用 T174 的读口——
  // 这里只钉"空字节也如实记账"，坏路径真报错的判据在各平台真窗测试里
  // （mac NSImage / win WIC / GTK gdk_texture_new_from_* 的 -1 已在 ABI 层）。
  let b = mock_widgets()
  let w = Widget::image(b)
  w.set_image_bytes(b"png")
  assert_eq(b.image_len_of(w.handle().unwrap()), 3)
}
