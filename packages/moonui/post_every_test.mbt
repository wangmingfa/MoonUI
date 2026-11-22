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
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
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
/// ②**到期才跑**（99ms 不跑、100ms 跑）——判据是 `now - due >= 0`（差值口径，
///  `T221`：`due` 是模 2^32 残差，绝对比较 `due <= now` 跨回绕会永不判到期），
///  不是"差不多"；
/// ③**收链之后零唤醒**——最后的 `step()` 必须回 `false`，否则"静止的界面还在
///  每秒醒 20 次"这种事判据看不见。
test "post_every：点火即第一拍、按间隔到期、返回 false 收链（T198）" {
  let (b, app, now) = every_rig()
  let tk = @moonui.Ticker()
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
  let tk = @moonui.Ticker()
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
  let tk = @moonui.Ticker()
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
/// 这条退路是给无头环境与 `App()` 之后还没注入时钟的那一小段路留的——
/// 没有时钟就算不出到期时刻，此时的正确做法是把拍子交给"下一圈"（与
/// `post_task` 同义），而不是静默不跑（判据会假绿）。
test "post_every：没接时钟时每圈一拍，不静默不跑（T198）" {
  let b = @moonui.MockBackend()
  @moonui.Backend::init(b)
  let app = @moonui.App(b)
  let tk = @moonui.Ticker()
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

///|
/// `T345` 帧节拍（`post_animation`）：**周期上限是 interval，不是 interval + 本拍耗时**。
///
/// 这是它与 `post_every` 唯一的语义差别，也是"16ms 一拍却只能量出 30fps"的全部
/// 原因：`post_every` 在 `task` 返回之后才 `post_after(interval)`，于是真周期 =
/// 本拍耗时 + interval。判据用同一本账把两条 API 摆在一起看：本拍耗时 6ms、
/// 间隔 16ms 时，帧节拍必须在 t=16 点火（绝对节拍），而 `post_every` 要等到
/// t=22（6 + 16）。差这 6ms 在 16ms 的预算里就是 27fps 与 60fps 的差别。
test "post_animation：按绝对节拍续期，本拍耗时不额外加时（T345）" {
  let (_b_every, app_every, now_every) = every_rig()
  let (_b_anim, app_anim, now_anim) = every_rig()
  let tk_every = @moonui.Ticker()
  let tk_anim = @moonui.Ticker()
  // 每拍"干活"6ms：注入钟由 task 自己往前推——真窗上这就是绘制耗时。
  let ticks_every : Array[Int32] = []
  let ticks_anim : Array[Int32] = []
  let _ = app_every.post_every(tk_every, 16, fn(_first) {
    ticks_every.push(now_every[0])
    now_every[0] = now_every[0] + 6
    true
  })
  let _ = app_anim.post_animation(tk_anim, 16, fn(_first) {
    ticks_anim.push(now_anim[0])
    now_anim[0] = now_anim[0] + 6
    true
  })
  let _ = app_every.step()
  let _ = app_anim.step()
  // 第一拍都在 t=0 点火，各自把钟推到 6
  assert_eq(ticks_every, [0])
  assert_eq(ticks_anim, [0])
  // t=15：都没到期
  now_every[0] = 15
  now_anim[0] = 15
  let _ = app_every.step()
  let _ = app_anim.step()
  assert_eq(ticks_every.length(), 1)
  assert_eq(ticks_anim.length(), 1)
  // t=16：帧节拍到（0 + 16），`post_every` 还要等到 22（6 + 16）
  now_every[0] = 16
  now_anim[0] = 16
  let _ = app_every.step()
  let _ = app_anim.step()
  assert_eq(ticks_every.length(), 1)
  assert_eq(ticks_anim, [0, 16])
  // t=22：`post_every` 这才轮到第二拍
  now_every[0] = 22
  let _ = app_every.step()
  assert_eq(ticks_every, [0, 22])
}

///|
/// `T345`：**排队的任务不许让主循环睡到"等原生事件"**。
///
/// 帧节拍会在"本拍超时"时续一个 0 毫秒的拍子，那一条进的是 `posted`（排队账，
/// 下一圈就跑）而不是 `timed`。`push_wait_cap` 原先只看 `timed`：账空就推 `-1`
/// （睡到下一个原生事件）。可重绘**不产** Core 事件——于是主循环在那一觉里再也
/// 醒不过来，画面停在某一帧、进程还活着（帧节拍第一次真跑就撞上了）。
///
/// 判据读 mock 的等待上限流水：只要有排队的拍子，推下去的上限必须是 1（"立刻
/// 回来"），不能是 -1。负控制：把 `push_wait_cap` 里 `posted.length() > 0`
/// 那支删掉，这里读回 -1。
test "post_animation：排队的拍子不让主循环睡到 -1（T345）" {
  let (b, app, now) = every_rig()
  let tk = @moonui.Ticker()
  // 本拍耗时 > 间隔：余量夹到 0，续的那一拍进排队账（`posted`）。
  let _ = app.post_animation(tk, 16, fn(_first) {
    now[0] = now[0] + 20
    true
  })
  let _ = app.step()
  let (cap, log) = @moonui.MockBackend::wait_caps(b)
  assert_eq(cap, 1)
  assert_true(log.length() > 0)
  assert_eq(log[log.length() - 1], 1)
  // 那一拍真的在下一圈就跑（不是睡过去）
  let before = now[0]
  let _ = app.step()
  assert_eq(now[0], before + 20)
  let _ = app.cancel_every(tk)
  @moonui.Backend::terminate(b)
}
