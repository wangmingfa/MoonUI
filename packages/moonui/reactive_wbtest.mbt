// Whitebox tests run within the package scope.
// `T284` 响应式核心判据（DESIGN §53.3 / §53.8）。白盒能读内部字段
// （`subs`/`dirty`/`pending`/`react_state.depth`），判据钉的是机制本身。
//
// 判据清单（§53.8）：
// ① `Signal::set` 后依赖它的 computed/effect 已更新
// ② 代际失效（R2）：effect 重跑后旧依赖不再触发
// ③ 批处理去重（R3）：一轮多次 set，effect 每轮只跑一次
// ④ computed 只读（R5）：set 抛 Unsupported
// ⑤ unsubscribe 摘掉订阅（R1 的解绑口）
// ⑥ 错误传播（§33）：computed 求值失败从 get 传出

///|
test "ref 基础：new/get/set/update/peek" {
  let r = Signal(10)
  assert_eq(r.get(), 10)
  r.set(42)
  assert_eq(r.get(), 42)
  assert_eq(r.peek(), 42)
  r.update(fn(x) { x + 8 })
  assert_eq(r.get(), 50)
}

///|
test "ref subscribe：set 触发回调，unsubscribe 摘掉" {
  let r = Signal(0)
  let mut seen = 0
  let id = r.subscribe(fn() raise UiError { seen = r.get() })
  r.set(7)
  assert_eq(seen, 7)
  r.unsubscribe(id)
  r.set(9)
  assert_eq(seen, 7) // 摘掉后不再触发
}

///|
test "computed：依赖变、惰性重算、只读" {
  let a = Signal(2)
  let b = Signal(3)
  let sum = computed(fn() raise UiError { a.get() + b.get() })
  assert_eq(sum.get(), 5)
  assert_false(sum.dirty) // 初始求值完不脏
  a.set(10)
  // 惰性：set 只标脏，这里 get 才重算
  assert_true(sum.dirty)
  assert_eq(sum.get(), 13)
  assert_false(sum.dirty)
  b.set(1)
  assert_eq(sum.get(), 11)
}

///|
test "computed set 抛 Unsupported（R5，只读）" {
  let a = Signal(1)
  let c = computed(fn() raise UiError { a.get() * 2 })
  let raised = try {
    c.set(99)
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "effect：依赖变触发重跑，stop 停链" {
  let a = Signal(1)
  let mut runs = 0
  let mut last = 0
  let eff = effect(fn() raise UiError {
    runs = runs + 1
    last = a.get()
  })
  assert_eq(runs, 1) // 初始立即跑
  assert_eq(last, 1)
  a.set(5)
  assert_eq(runs, 2)
  assert_eq(last, 5)
  eff.stop()
  a.set(9)
  assert_eq(runs, 2) // 停链后不再触发
}

///|
test "代际失效（R2）：effect 重跑后旧依赖不再触发" {
  let a = Signal(1)
  let b = Signal(10)
  let mut runs = 0
  let mut reads_b = true
  let _ = effect(fn() raise UiError {
    runs = runs + 1
    if reads_b {
      let _ = b.get()
    }
    let _ = a.get()
  })
  assert_eq(runs, 1)
  // 第一次重跑后不再读 b
  reads_b = false
  a.set(2) // 触发重跑（现在只读 a）
  assert_eq(runs, 2)
  let before = runs
  b.set(99) // b 不再是依赖，不应触发
  assert_eq(runs, before)
}

///|
test "批处理去重（R3）：batch 一轮多次 set，effect 每轮只跑一次" {
  let a = Signal(0)
  let b = Signal(0)
  let mut runs = 0
  let _ = effect(fn() raise UiError {
    runs = runs + 1
    let _ = a.get() + b.get()
  })
  assert_eq(runs, 1)
  batch(fn() raise UiError {
    a.set(1)
    b.set(2)
  })
  // batch 内两个 set 只触发一次 flush → effect 只重跑一次
  assert_eq(runs, 2)
  // 不带 batch 的顺序 set 各自 flush
  a.set(3)
  b.set(4)
  assert_eq(runs, 4)
}

///|
test "watch：旧值/新值" {
  let a = Signal(1)
  let mut old = 0
  let mut new = 0
  let mut calls = 0
  let _ = watch(a, fn(o, n) {
    old = o
    new = n
    calls = calls + 1
  })
  assert_eq(calls, 0) // 初始不回调
  a.set(2)
  assert_eq(calls, 1)
  assert_eq(old, 1)
  assert_eq(new, 2)
  a.set(3)
  assert_eq(calls, 2)
  assert_eq(old, 2)
  assert_eq(new, 3)
}

///|
test "computed 链：computed 依赖 computed" {
  let a = Signal(3)
  let doubled = computed(fn() raise UiError { a.get() * 2 })
  let quadrupled = computed(fn() raise UiError { doubled.get() * 2 })
  assert_eq(quadrupled.get(), 12)
  a.set(5)
  assert_eq(quadrupled.get(), 20)
}

///|
test "循环依赖（R4）：computed 读自己 raise Unsupported" {
  let a = Signal(0)
  // 鸡生蛋：computed 的求值函数要读自己，用 self 槽。构造期槽未填 → 求值得 0，
  // 且只注册了 `a` 为依赖；`a` 一变，`c` 标脏，下一次 `get` 重算时槽已填，
  // `c.get()` 重入自己——`running` 位拦下，`raise Unsupported`。
  let mut c_ref : Signal[Int32]? = None
  let c = computed(fn() raise UiError {
    let _ = a.get()
    match c_ref {
      Some(cc) => cc.get() + 1
      None => 0
    }
  })
  c_ref = Some(c)
  assert_eq(c.get(), 0)
  a.set(1) // 标脏 c
  let raised = try {
    let _ = c.get() // 重算 → 读自己 → 循环
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "set_if_changed：同值不通知订阅者（Eq 短路）" {
  let r = Signal(0)
  let mut runs = 0
  let _ = r.subscribe(fn() { runs = runs + 1 })
  r.set_if_changed(0) // 同值：不通知
  assert_eq(runs, 0)
  r.set_if_changed(1) // 异值：通知
  assert_eq(runs, 1)
  r.set_if_changed(1) // 同值：不通知
  assert_eq(runs, 1)
}

///|
test "computed Eq 短路：值不变不通知下游（传递性）" {
  let a = Signal(0)
  let even = computed(fn() raise UiError { a.get() % 2 == 0 }) // Bool : Eq
  let mut runs = 0
  let _ = effect(fn() raise UiError {
    runs = runs + 1
    let _ = even.get()
  })
  assert_eq(runs, 1)
  // a 0→2，even 都是 true（值没变）→ 不通知 → effect 不重跑
  a.set(2)
  assert_eq(runs, 1)
  // a 2→3，even false（值变了）→ 通知 → effect 重跑
  a.set(3)
  assert_eq(runs, 2)
}

///|
test "computed 求值失败从 get 传出（§33 不吞）" {
  let a = Signal(0)
  let c = computed(fn() raise UiError {
    if a.get() > 0 {
      raise Unsupported("故意失败")
    }
    a.get()
  })
  // 初始求值：a=0，不失败
  assert_eq(c.get(), 0)
  // 触发重算（惰性）：a 变 1，下次 get 重跑 f 会失败
  a.set(1)
  let raised = try {
    let _ = c.get()
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}

///|
test "flush 排空排程队列（批处理落点）" {
  let a = Signal(0)
  let mut runs = 0
  let _ = effect(fn() raise UiError {
    runs = runs + 1
    let _ = a.get()
  })
  assert_eq(runs, 1)
  // 手动把 effect 排入（模拟嵌套 set 中），flush 排空
  a.set(1)
  assert_eq(runs, 2)
  // 没有待排空的任务
  assert_eq(react_state.pending.length(), 0)
}

///|
test "map：派生值跟随源、Eq 短路、只读（T292）" {
  let count = Signal(0)
  let text = count.map(fn(c) { "\{c} 次" })
  // 构造即求值一次
  assert_eq(text.get(), "0 次")
  // 源变，派生跟随
  count.set(3)
  assert_eq(text.get(), "3 次")
  // computed 语义：只读
  let raised = try {
    text.set("改不动")
    false
  } catch {
    Unsupported(_) => true
    _ => false
  }
  assert_true(raised)
  // Eq 短路：映射结果相同时下游 effect 不重跑
  let raw = Signal(0)
  let rounded = raw.map(fn(x : Int32) { x / 10 })
  let mut runs = 0
  let _ = effect(fn() raise UiError {
    runs = runs + 1
    let _ = rounded.get()
  })
  assert_eq(runs, 1)
  raw.set(5) // 0/10 == 5/10 == 0，值没变不通知下游
  assert_eq(runs, 1)
  raw.set(20) // 20/10 == 2，值变了才重跑
  assert_eq(runs, 2)
}

///|
test "事件派发自动批处理（T292）：一次事件内多次 set，effect 只跑一轮" {
  let b = MockBackend()
  b.init()
  let app = App(b)
  let win = app.create_window("batch", LogicalSize(200.0, 200.0))
  win.show()
  let _ = app.step()
  let a = Signal(0)
  let c = Signal(0)
  let mut runs = 0
  let _ = effect(fn() raise UiError {
    runs = runs + 1
    let _ = a.get()
    let _ = c.get()
  })
  assert_eq(runs, 1) // 构造即首跑
  // 一次事件回调里改两个信号：自动 batch 合并成一轮 flush
  let wt = win.target()
  let _ = app.on_event(wt, fn(_) raise UiError {
    a.set(1)
    c.set(2)
  })
  let _ = app.dispatch(MouseMove(wt, LogicalPoint(0.0, 0.0)))
  assert_eq(a.get(), 1)
  assert_eq(c.get(), 2)
  assert_eq(runs, 2) // 不是 3：两次 set 只触发一轮重跑
  // 一次 set 一条事件：仍是每事件一轮
  let _ = app.dispatch(MouseMove(wt, LogicalPoint(0.0, 0.0)))
  assert_eq(runs, 3)
}
