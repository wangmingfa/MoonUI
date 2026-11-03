///|
/// `T200`：稳定排序——同分的元素保持原有先后。
///
/// 这条判据的牙在**同分**上：给一批"只有两个分值"的数据排一次，再比一次同分
/// 元素之间的相对次序。用 core 的 `Array::sort_by`（快排）实现的话，16 个元素
/// 以上必然重排；本条同时用一个够长的数组（> 快排的小数组阈值）钉住这件事。
test "sort_stable_by：同分保持原先后（T200）" {
  // 40 条：rank 只有 0/1/2 三档，payload 是原下标
  let xs : Array[(Int32, Int32)] = []
  for i = 0; i < 40; i = i + 1 {
    xs.push((i % 3, i))
  }
  @util.sort_stable_by(xs, fn(a, b) {
    if a.0 < b.0 {
      -1
    } else if a.0 > b.0 {
      1
    } else {
      0
    }
  })
  // 主序：rank 升序
  for i = 1; i < xs.length(); i = i + 1 {
    assert_true(xs[i - 1].0 <= xs[i].0)
  }
  // 次序：同一 rank 内部，下标严格递增（= 保持原有先后）
  let prev : Array[Int32] = [-1, -1, -1]
  for (rank, idx) in xs {
    assert_true(idx > prev[rank])
    prev[rank] = idx
  }
}

///|
/// `T200`：比较器恒返回 0（"按原序排"）时，结果必须与输入逐位相同。
/// 这条是 `ByIndex` 那个档位的形状——不稳定排序会在这里把列表洗一遍。
test "sort_stable_by：全同分等于不动（T200）" {
  let xs : Array[Int32] = []
  for i = 0; i < 30; i = i + 1 {
    xs.push(100 - i)
  }
  let before = xs.copy()
  @util.sort_stable_by(xs, fn(_a, _b) { 0 })
  assert_eq(xs, before)
  // 空数组与单元素不炸
  let empty : Array[Int32] = []
  @util.sort_stable_by(empty, fn(_a, _b) { 0 })
  assert_eq(empty, [])
  let one : Array[Int32] = [7]
  @util.sort_stable_by(one, fn(_a, _b) { 0 })
  assert_eq(one, [7])
}
