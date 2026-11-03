///|
/// 稳定排序（`T200`）。
///
/// 为什么需要包一层：core 的 `Array::sort_by` 是**快排，不保证稳定**；稳定那份
/// （timsort）只挂在 `FixedArray` 与 `MutArrayView` 上，`Array` 上要借
/// `mut_view()` 才够得着。于是"我要稳定排序"在 `Array` 上写成 `arr.sort_by(...)`
/// 是**看起来对、实际上会打乱同分元素先后**的一行——本仓库为此交过学费：
/// lunamusic 的曲目表有个 `ByIndex`（原始顺序）档，比较器恒返回 0（"哪两首都
/// 算同分"），换个不稳定排序就是每次点"按原序"都把列表洗一遍。
///
/// `arr.mut_view()` 是整段视图，排序当场写回数组本身（窗口只覆盖这一段，不碰
/// 邻居）。全程零分配、零拷贝。
pub fn[T] sort_stable_by(arr : Array[T], cmp : (T, T) -> Int32) -> Unit {
  arr.mut_view().stable_sort_by(cmp)
}
