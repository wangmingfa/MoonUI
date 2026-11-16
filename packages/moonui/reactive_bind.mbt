///|
/// 响应式（MVVM）数据驱动 —— Layer 2 绑定层（`T284`，DESIGN §53.4）。
///
/// 把 `Signal[T]` 接到 `Widget[B]` 属性：`bind_*` 全是 `Widget[B]` 的扩展方法，
/// 复用既有 `set_*` 语义（种类守卫、标脏、后端推送、错误传播原样继承），Core
/// 既有 API 一字不动。
///
/// 单向（Signal → Widget 属性）：
/// - `bind_text` / `bind_text_fmt`：文案。
/// - `bind_checked` / `bind_value` / `bind_selected`：勾选、数值、选中下标。
/// - `bind_enabled` / `bind_visible`：可用、可见。
/// - `bind_placeholder` / `bind_style`：占位、样式。
/// - `bind`（通用兜底）：自己给 `apply : (Widget[B], T) -> Unit raise UiError`。
///
/// 双向（Widget 事件 → Signal → Widget，带防回环）：
/// - `bind_input`：TextInput 的 `Input` 事件 ↔ `Signal[String]`。
/// - `bind_check`：Checkbox 的 `Change` 事件 ↔ `Signal[Bool]`。
///
/// **读值走 `get` 而非 `peek`**：绑定要的是新鲜值——computed 且 `dirty` 时
/// `get` 会重算（`peek` 返回可能过期的旧值）。副作用：若 `get` 恰好在某帧
/// 追踪里（effect 内 `set` 信号这种边缘情况）会把信号注册成那帧的依赖，那个
/// effect 会多跟一轮——无害，绑定不是派生态的消费者。
///
/// **订阅生命周期（R1，§53.7）**：绑定闭包挂在 `Signal.subs`，捕获控件。控件
/// `close_tree`（§8）后，闭包下次触发时先看 `closed` 位——真就自解绑
/// （`unsubscribe`）并返回，不碰已销毁控件。这是"闭包捕获 `closed` 位，
/// `closed=true` 直接返回"的对策；自解绑把残留上限压到"关树后再来一次信号"。
/// 控件未被关掉时订阅常驻（与手写 `on_click` 同生命周期，随控件树回收）。
///
/// **防回环（双向）**：`suppress` 是共享重入闸。任一方向进入时先置位，期间
/// 另一方向（或本方向的重入）看到置位即跳过；收尾复位。防止"打字 →
/// `set_text` 回写自己 → 游标跳动"，以及真后端上程序性 `set_text` 回声成
/// `Input` 的假回环。

///|
/// 通用绑定（§53.4 兜底）：初始值立即 `apply`，Signal 变化时再 `apply`。
///
/// `apply` 由调用方给出，通常是 `fn(w, v) { w.set_xxx(v) }`——它把 `B : Backend`
/// 的约束带在闭包构造点（`bind` 本身不要求 Backend），`set_style` 这类不要
/// Backend 的 setter 也能走这条路。
pub fn[B, T] Widget::bind(
  self : Widget[B],
  r : Signal[T],
  apply : (Widget[B], T) -> Unit raise UiError,
) -> Widget[B] raise UiError {
  apply(self, r.get())
  let w = self
  let mut sub_id = 0
  sub_id = r.subscribe(fn() raise UiError {
    if w.closed {
      // R1：控件已销毁，自解绑（Signal.subs 不再悬空引用）。
      r.unsubscribe(sub_id)
      return
    }
    apply(w, r.get())
  })
  self
}

///|
/// 文案绑定（§53.4）。复用 `set_text` 的语义：种类守卫、`mark_needs_layout`、
/// 错误传播原样继承。
pub fn[B : Backend] Widget::bind_text(
  self : Widget[B],
  r : Signal[String],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_text(v) })
}

///|
/// 文案绑定 + 格式化（§53.4）。`fmt` 把信号值转文案，`bind_text` 是
/// `fmt = identity` 的特例。`fmt` 不 raise（§53.4 签名），setter 的 raise 照旧。
pub fn[B : Backend, T] Widget::bind_text_fmt(
  self : Widget[B],
  r : Signal[T],
  fmt : (T) -> String,
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_text(fmt(v)) })
}

///|
/// 勾选绑定（§53.4）。复用 `set_checked`：只对 Checkbox / MenuRow 有效，
/// 其余种类由 `set_checked` 的种类守卫抛 `Unsupported`。
pub fn[B : Backend] Widget::bind_checked(
  self : Widget[B],
  r : Signal[Bool],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_checked(v) })
}

///|
/// 数值绑定（§53.4，Slider / Spinbox / Progress）。复用 `set_value` 的种类守卫。
pub fn[B : Backend] Widget::bind_value(
  self : Widget[B],
  r : Signal[Int32],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_value(v) })
}

///|
/// 可用性绑定（§53.4）。复用 `set_enabled`。
pub fn[B : Backend] Widget::bind_enabled(
  self : Widget[B],
  r : Signal[Bool],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_enabled(v) })
}

///|
/// 可见性绑定（§53.4）。复用 `set_visible`（含 `T89③` 的淡入过渡语义）。
pub fn[B : Backend] Widget::bind_visible(
  self : Widget[B],
  r : Signal[Bool],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_visible(v) })
}

///|
/// 占位提示绑定（§53.4，TextInput / PasswordInput）。复用 `set_placeholder`
/// 的种类守卫与"空串 = 清掉"语义。
pub fn[B : Backend] Widget::bind_placeholder(
  self : Widget[B],
  r : Signal[String],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_placeholder(v) })
}

///|
/// 选中下标绑定（§53.4，ComboBox / RadioButtons）。复用 `set_selected` 的
/// 种类守卫；越界行为由后端定义（调用方自律）。
pub fn[B : Backend] Widget::bind_selected(
  self : Widget[B],
  r : Signal[Int32],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_selected(v) })
}

///|
/// 样式绑定（§53.4）。`set_style` 不要 `B : Backend`，所以本绑定也是——
/// 局部样式不直接推后端，度量在重排那一刻才读（与 `.layer_local` 同账）。
pub fn[B] Widget::bind_style(
  self : Widget[B],
  r : Signal[Style?],
) -> Widget[B] raise UiError {
  self.bind(r, fn(w, v) raise UiError { w.set_style(v) })
}

///|
/// 双向文本绑定（§53.4）：TextInput 的 `Input` 事件写回信号，信号变化写回
/// 控件。初始值立即 `set_text`。
///
/// 防回环（§53.4）：`suppress` 是共享重入闸。`Input` 方向先置位再 `r.set`；
/// 信号订阅里看到置位只读不写（不 `set_text` 回写自己）。反之亦然——信号
/// 方向先置位再 `set_text`，若真后端把程序性 `set_text` 回声成 `Input`，
/// 该回调看到置位即跳过，不回环。
pub fn[B : Backend] Widget::bind_input(
  self : Widget[B],
  r : Signal[String],
) -> Widget[B] raise UiError {
  self.set_text(r.get())
  let w = self
  let mut suppress = false
  let mut sub_id = 0
  sub_id = r.subscribe(fn() raise UiError {
    if w.closed {
      // R1：控件已销毁，自解绑（Signal.subs 不再悬空引用）。与通用 `bind` 同策。
      r.unsubscribe(sub_id)
      return
    }
    if !suppress {
      suppress = true
      let err = try {
        w.set_text(r.get())
        None
      } catch {
        e => Some(e)
      }
      suppress = false
      match err {
        Some(e) => raise e
        None => ()
      }
    }
  })
  let _ = self.on_input(fn(text) raise UiError {
    if !suppress {
      suppress = true
      let err = try {
        r.set(text)
        None
      } catch {
        e => Some(e)
      }
      suppress = false
      match err {
        Some(e) => raise e
        None => ()
      }
    }
  })
  self
}

///|
/// 双向勾选绑定（§53.4）：Checkbox 的 `Change` 事件写回信号，信号变化写回
/// 控件。初始值立即 `set_checked`。防回环同 `bind_input`。
pub fn[B : Backend] Widget::bind_check(
  self : Widget[B],
  r : Signal[Bool],
) -> Widget[B] raise UiError {
  self.set_checked(r.get())
  let w = self
  let mut suppress = false
  let mut sub_id = 0
  sub_id = r.subscribe(fn() raise UiError {
    if w.closed {
      // R1：控件已销毁，自解绑（Signal.subs 不再悬空引用）。与通用 `bind` 同策。
      r.unsubscribe(sub_id)
      return
    }
    if !suppress {
      suppress = true
      let err = try {
        w.set_checked(r.get())
        None
      } catch {
        e => Some(e)
      }
      suppress = false
      match err {
        Some(e) => raise e
        None => ()
      }
    }
  })
  let _ = self.on_change(fn() raise UiError {
    if !suppress {
      suppress = true
      let err = try {
        r.set(w.checked())
        None
      } catch {
        e => Some(e)
      }
      suppress = false
      match err {
        Some(e) => raise e
        None => ()
      }
    }
  })
  self
}
