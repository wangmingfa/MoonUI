// `T198`：最新一轮为准的请求账。
//
// 异步请求（worker 扫描目录、网络查歌词、后台探测标签）普遍要判三件事：
// ①这一轮问的是不是上一轮问过的**同一个人**——连点两次不该发两趟；
// ②回来的结果还是不是当前那一轮——旧结果必须让位；
// ③现在有没有一轮还在路上——界面文案（"查询中…"）与空态提示靠它。
//
// 手写要三格状态（上次问了谁 / 还在路上没有 / 落地时比对），三处各判一遍，
// 判漏一处就是"旧结果盖掉新结果"或"点了没反应"。收进这只值之后，三件事各是
// 一条方法，判据也只有一处。

///|
/// `T198`：**以轮次为准**的请求账。
///
/// 关键是**轮次戳**而不是身份值：用户 A → B → A 连问三次时，第一轮 A 的结果
/// 与当前身份**完全相同**，按身份比对会把陈旧结果当成当前那一轮收下；轮次戳
/// 不会——第一轮的号早被第三轮顶掉了。身份值仍然记着，但只用来挡连点。
///
/// 用法（三步，缺一不可）：
/// ```text
/// if box.pending_same(key) { return }        // 挡连点：同一个人、那一轮还在路上
/// let gen = box.issue(key)                   // 开一轮，拿到这一轮的号
/// on_done(fn(result) {
///   if !box.land(gen) { return }             // 落地比对：不是当前那一轮就整轮丢掉
///   ...                                      // 收结果
/// })
/// ```
pub struct StaleBox[T] {
  /// 轮次。`issue` 与 `reset` 各 +1。
  mut gen : Int32
  /// 最近一轮的身份值（`None` = 还没问过任何一轮）。
  mut key : T?
  /// 当前这一轮是否还欠一次落地。
  mut in_flight : Bool
}

///|
/// `T198`：造一只空账（还没问过任何一轮）。
pub fn[T] StaleBox::new() -> StaleBox[T] {
  { gen: 0, key: None, in_flight: false, }
}

///|
/// `T198`：开一轮，返回这一轮的轮次戳。调用方把这个号带进回调，落地时交给
/// `land` 比对——**捕获号而不是捕获身份值**，这是"最新一轮为准"能成立的前提。
pub fn[T] StaleBox::issue(self : StaleBox[T], key : T) -> Int32 {
  self.gen = self.gen + 1
  self.key = Some(key)
  self.in_flight = true
  self.gen
}

///|
/// `T198`：现在有没有一轮还在路上（界面文案用）。
pub fn[T] StaleBox::is_pending(self : StaleBox[T]) -> Bool {
  self.in_flight
}

///|
/// `T198`：挡连点——在路上那一轮问的正是 `key` 吗？
///
/// 只挡"同一个人"：身份不同就必须能发出去（用户改了名字再点，不能等上一轮回来
/// 才动得了）。
pub fn[T : Eq] StaleBox::pending_same(self : StaleBox[T], key : T) -> Bool {
  if !self.in_flight {
    return false
  }
  match self.key {
    Some(asked) => asked == key
    None => false
  }
}

///|
/// `T198`：落地比对 + 结账。`gen` 是当前那一轮吗？
///
/// 是：结账（不再"在路上"）并返回 `true`，调用方收结果。
/// 不是（旧一轮、或 `reset` 之前发出的那一轮）：返回 `false`，整轮丢掉。
///
/// 同一轮重复落地（上游回调重复触发）也只认第一次：第二次 `in_flight` 已经是
/// 假，返回 `false`。
pub fn[T] StaleBox::land(self : StaleBox[T], gen : Int32) -> Bool {
  if !self.in_flight || gen != self.gen {
    return false
  }
  self.in_flight = false
  true
}

///|
/// `T198`：问过没有。空态提示靠它区分"还没查"与"查了没结果"——比拿某个哨兵
/// 身份值（空串对）去比更清楚：哨兵会和"真的拿空串查了一次"撞车。
pub fn[T] StaleBox::has_key(self : StaleBox[T]) -> Bool {
  self.key is Some(_)
}

///|
/// `T198`：清账——回到"还没问过"，**同时让在飞的那一轮作废**（关窗重开时上一轮
/// 的结果不该落进新窗）。只清身份不清轮次的话，在飞的那一轮落地时仍然对得上号。
pub fn[T] StaleBox::reset(self : StaleBox[T]) -> Unit {
  self.gen = self.gen + 1
  self.key = None
  self.in_flight = false
}
