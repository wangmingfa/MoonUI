// `T198` 周期投递（`post_every`）的黑盒判据：全走公共 API，在 MockBackend 上跑。
//
// 时刻走注入的帧钟（`T84` 先例）：Core 一行不读时钟，所以"每 100ms 一拍"在
// 测试里是逐拍可断言的确定值，而不是"大概多久"。真后端上"不碰输入也能按自己的
// 节奏醒"那条性质由 `T152` 的判据钉着（同一本定时账），这里不重复。

///|
/// 起一只 App + 一格可控时钟。返回 `(后端, app, 时钟格)`——后端要留着给收尾的
/// `terminate`（判据里那句"退出后没有遗留句柄"）。
fn every_rig() -> (
  @moonui.MockBackend,
  @moonui.App[@moonui.MockBackend],
  Array[Int32],
) raise Error {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let now : Array[Int32] = [0]
  app.set_anim_clock(fn() { now[0] })
  (b, app, now)
}

///|
/// 点火 → 逐拍到期 → `task` 返回 `false` 收链。
///
/// 三处都是这条 API 的契约，缺一条就退化成"能跑但说不清"：
/// ①**点火即跑第一拍**（不等一个间隔，且 `first` 为真）——手写版为此要
///  `post_task` + 自续两步；
/// ②**到期才跑**（99ms 不跑、100ms 跑）——判据是 `due <= now`，不是"差不多"；
/// ③**收链之后零唤醒**——最后的 `step()` 必须回 `false`，否则"静止的界面还在
///  每秒醒 20 次"这种事判据看不见。
test "post_every：点火即第一拍、按间隔到期、返回 false 收链（T198）" {
  let (b, app, now) = every_rig()
  let tk = @moonui.Ticker::new()
  let ticks : Array[(Int32, Bool)] = []
  assert_false(tk.running())
  assert_true(
    app.post_every(tk, 100, fn(first) {
      ticks.push((now[0], first))
      ticks.length() < 3
    }),
  )
  assert_true(tk.running())
  let _ = app.step()
  assert_eq(ticks, [(0, true)])
  // 差一毫：还没到期，一拍都不许多跑
  now[0] = 99
  let _ = app.step()
  assert_eq(ticks.length(), 1)
  now[0] = 100
  let _ = app.step()
  assert_eq(ticks, [(0, true), (100, false)])
  // 第三拍返回 false ⇒ 当场收链，`running` 立刻为假
  now[0] = 200
  let _ = app.step()
  assert_eq(ticks, [(0, true), (100, false), (200, false)])
  assert_false(tk.running())
  // 收链之后既不跑也不再唤醒：这一圈"没有任何进展"
  now[0] = 5000
  assert_false(app.step())
  assert_eq(ticks.length(), 3)
  @moonui.Backend::terminate(b)
}

///|
/// 点火幂等 / 停链幂等 / 重开从头算。
///
/// 幂等这条不是洁癖：真窗上的症状是"帧率翻倍"（同一条链挂了两条自续分支）——
/// 手写版靠一个 `live` 布尔挡它，漏判一处就中。停链之后重开必须重新算第一拍，
/// 否则"接上一轮的时刻锚点"会让动画在重开后第一帧直接跳一大步。
test "post_every：活着时再点火不动、停链可停、重开从头算（T198）" {
  let (b, app, now) = every_rig()
  let tk = @moonui.Ticker::new()
  let ticks : Array[(Int32, Bool)] = []
  let task : (Bool) -> Bool raise @moonui.UiError = fn(first) {
    ticks.push((now[0], first))
    true
  }
  assert_true(app.post_every(tk, 100, task))
  let _ = app.step()
  assert_eq(ticks.length(), 1)
  // 活着时再点火：返回 false，且不许并出第二条链
  assert_false(app.post_every(tk, 100, task))
  now[0] = 100
  let _ = app.step()
  now[0] = 200
  let _ = app.step()
  // 再点火若真的并出第二条链，这里会是 4~5 拍。
  //
  // 这一句与上一句 `assert_false` 是两道网：挡板在时，上一句先红；万一挡板被
  // 去掉，`gen` 换号也会把老链的那一拍作废，计数仍是 3——所以这条**不是**
  // "挡板"的判据，而是"两条链真的并起来"这一更深层的判据（`gen` 那层也坏掉
  // 时，红的是这里）。
  assert_eq(ticks, [(0, true), (100, false), (200, false)])
  // 停链：返回"此前是活的"，重复停返回 false
  assert_true(app.cancel_every(tk))
  assert_false(tk.running())
  assert_false(app.cancel_every(tk))
  now[0] = 300
  let _ = app.step()
  assert_eq(ticks.length(), 3)
  // 重新点火：从头算，第一拍仍是 `first = true`
  assert_true(app.post_every(tk, 50, task))
  assert_true(app.step())
  assert_eq(ticks.length(), 4)
  assert_eq(ticks[3], (300, true))
  let _ = app.cancel_every(tk)
  @moonui.Backend::terminate(b)
}

///|
/// 残影拍：**停链之后已经到期搬进排队账的那一拍**不许跑、也不许把链接回去。
///
/// 这一条是 `Ticker` 里 `gen` 存在的唯一理由，也是手写版最容易漏的一处：
/// `cancel_task` 只能撤还没到期的（`T152`：到期即搬进 `posted`，搬走就离开
/// `timed`）。构造方式就是真窗上的时序——同一圈里先有一只"停链"任务排在前头：
/// `step` 开头 `drain_timed` 把到期的那一拍搬进排队账，随后 `run_posted` 先跑
/// 停链任务，此时撤号已经撤不到它，只剩下换号能拦住。
///
/// 负控制：把 `tick_every` 开头那句 `if t.gen != gen { return }` 删掉，残影拍
/// 照跑（`ticks` 变 2 条）并自己续上下一拍（`running` 为真）——两条断言一起红。
test "post_every：停链之后已经到期的那一拍不跑、也不自己续上（T198）" {
  let (b, app, now) = every_rig()
  let tk = @moonui.Ticker::new()
  let ticks : Array[Int32] = []
  let _ = app.post_every(tk, 100, fn(_first) {
    ticks.push(now[0])
    true
  })
  let _ = app.step()
  assert_eq(ticks, [0])
  now[0] = 100
  let _ = app.post_task(fn() { let _ = app.cancel_every(tk) })
  let _ = app.step()
  assert_eq(ticks.length(), 1)
  assert_false(tk.running())
  now[0] = 200
  let _ = app.step()
  assert_eq(ticks.length(), 1)
  @moonui.Backend::terminate(b)
}

///|
/// 没接时钟（`anim_clock = None`）时退化成"每一圈一拍"：宁可早到不可不到。
///
/// 这条退路是给无头环境与 `App::new()` 之后还没注入时钟的那一小段路留的——
/// 没有时钟就算不出到期时刻，此时的正确做法是把拍子交给"下一圈"（与
/// `post_task` 同义），而不是静默不跑（判据会假绿）。
test "post_every：没接时钟时每圈一拍，不静默不跑（T198）" {
  let b = @moonui.MockBackend::new()
  @moonui.Backend::init(b)
  let app = @moonui.App::new(b)
  let tk = @moonui.Ticker::new()
  let mut n = 0
  let _ = app.post_every(tk, 500, fn(_first) {
    n = n + 1
    n < 3
  })
  for _ in 0..<4 {
    let _ = app.step()
  }
  assert_eq(n, 3)
  assert_false(tk.running())
  @moonui.Backend::terminate(b)
}
