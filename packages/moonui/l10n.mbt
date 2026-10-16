///|
/// 国际化——文案层与资源层（`T88②`）：MoonBit 侧一条实现，两平台零分叉。
///
/// 资源层是**程序内注册的档案**（locale → key → 文案的查表），不读文件——
/// 档案来源是另一条分平台的账（wasm 没有文件系统），条目原文只要"文案层与
/// 资源层、两平台零分叉"，程序注册就是最小加法：资源跟着应用代码走，一条
/// MoonBit 数据声明在哪个平台都能编译。按 locale 注册档案、切 locale、查表，
/// 三步都在 Core 侧，零 C 零 ABI。
///
/// 缺席纪律（§33——不静默回退）：查表缺 key 是**显式缺席**，错误串带 key 与
/// locale 当场点名；不跨 locale 回退（zh 档缺的 key 不会拿 en 档的顶上）、不
/// 回退默认串——静默回退只会把"漏翻译"藏进界面里。显式缺席的另一半通道是
/// `text_or`（Option 语义，`window_state` 读档的"缺席是常态"同一条读法——
/// 哪些 key 允许缺席由应用自己点名，框架不猜）。
///
/// 切档刷新语义（记案，最小版）：**切档后新建控件生效，存量控件调 set_text
/// 刷新由应用自理**。`label`/`button` 是构造时查表——查得的文案烙进控件，
/// 与控件的生命周期绑定；`set_locale` 不广播、不标脏、不追踪哪只控件是查表
/// 造的（那是控件级的状态账，Core 没有这条索引——最小加法的边界）。应用要
/// 刷新存量控件，自己在切档回调里 set_text；判据把"存量不变、新建生效"钉死，
/// 这条语义就是文档。

///|
pub struct L10n {
  /// 已注册的档案：locale → (key → 文案)。重复注册整份替换（沿 `set_menubar`
  /// 的同一条重建语义——档案是资源，不是增量的账）。
  archives : Map[String, Map[String, String]]
  /// 当前 locale。`L10n::new()` 是空串哨兵——还没切过档；查表在哨兵上是显式
  /// 错误，不猜默认档。
  mut locale : String
}

///|
pub fn L10n::new() -> L10n {
  L10n::{ archives: Map([]), locale: "", }
}

///|
/// 注册一份 locale 档案（`T88②`）：整份替换，已注册的同名 locale 被覆盖。
/// entries 是该 locale 的完整 key → 文案表。
pub fn L10n::add_archive(
  self : L10n,
  locale : String,
  entries : Map[String, String],
) -> Unit {
  self.archives.set(locale, entries)
}

///|
/// 切换 locale（`T88②`）：之后查表、构造控件都按这份档案。未注册的 locale
/// 是显式错误（§33——切到一份不存在的档，等于整个应用查不到文案，必须当场
/// 报错而不是静默变成"所有 key 缺席"的档）。
pub fn L10n::set_locale(self : L10n, locale : String) -> Unit raise UiError {
  match self.archives.get(locale) {
    Some(_) => self.locale = locale
    None =>
      raise OperationFailed("L10n 未注册 locale \{locale}，不能切换")
  }
}

///|
/// 当前 locale：`L10n::new()` 后是空串哨兵（还没切过档）。
pub fn L10n::locale(self : L10n) -> String {
  self.locale
}

///|
/// 查表（`T88②`）：当前 locale 的档案里取 key 的文案。三种缺席全部显式报错，
/// 错误串带 key 与 locale 当场点名（§33——漏翻译不许静默顶替）：
/// - 没切过档（哨兵 locale）；
/// - 缺 key；
/// - locale 档案被注册过（`set_locale` 已拦）——这条到不了，哨兵统一拦。
pub fn L10n::text(self : L10n, key : String) -> String raise UiError {
  match self.archives.get(self.locale) {
    Some(table) =>
      match table.get(key) {
        Some(text) => text
        None =>
          raise OperationFailed(
            "L10n 缺少文案 key \{key}（locale=\{self.locale}）",
          )
      }
    None =>
      raise OperationFailed(
        "L10n 没有当前 locale 可查（切档后再查表）",
      )
  }
}

///|
/// 查表的显式缺席通道（`T88②`）：`None` = 当前档案没有这只 key（没切过档
/// 也是 `None`）。哪些 key 允许缺席由应用点名，框架不猜——与 `text` 的报错
/// 口径互为两半：报错的必是缺席，缺席的未必报错。
pub fn L10n::text_or(self : L10n, key : String) -> String? {
  match self.archives.get(self.locale) {
    Some(table) => table.get(key)
    None => None
  }
}

///|
/// 文案层的控件通道（`T88②`）：按当前 locale 查表构造标签。查表的缺席纪律
/// 与 `text` 同一条——构造当场失败，不造出一只空标签让缺席往后传。
///
/// 刷新语义见文件段注：文案在构造时刻烙进控件，`set_locale` 之后**新建**的
/// 控件按新档生效；存量控件调 `set_text` 刷新由应用自理。
pub fn[B : Backend] L10n::label(
  self : L10n,
  b : B,
  key : String,
) -> Widget[B] raise UiError {
  Widget::label(b, self.text(key))
}

///|
/// 文案层的控件通道（`T88②`）：按钮同 `label` 的构造时刻查表与缺席纪律。
pub fn[B : Backend] L10n::button(
  self : L10n,
  b : B,
  key : String,
) -> Widget[B] raise UiError {
  Widget::button(b, self.text(key))
}

///|
test "L10n 查表往返：注册 → 查得原文 → 切档往返（T88②判据）" {
  let l10n = L10n::new()
  l10n.add_archive("zh", Map([("app.title", "月亮"), ("app.ok", "确定")]))
  l10n.add_archive("en", Map([("app.title", "Moon"), ("app.ok", "OK")]))
  // 没切过档：查表显式报错（哨兵，不猜默认档）
  let msg = try {
    let _ = l10n.text("app.title")
    None
  } catch {
    e => Some(e.message())
  }
  assert_eq(
    msg,
    Some(
      "操作失败：L10n 没有当前 locale 可查（切档后再查表）",
    ),
  )
  // 往返：切 zh 查得 zh 原文，切 en 查得 en 原文，来回切来回查
  l10n.set_locale("zh")
  assert_eq(l10n.locale(), "zh")
  assert_eq(l10n.text("app.title"), "月亮")
  l10n.set_locale("en")
  assert_eq(l10n.text("app.title"), "Moon")
  l10n.set_locale("zh")
  assert_eq(l10n.text("app.ok"), "确定")
  assert_eq(l10n.text("app.title"), "月亮")
}

///|
test "L10n 缺 key 显式缺席：报错带 key 与 locale，不跨档回退（T88②判据·§33）" {
  let l10n = L10n::new()
  l10n.add_archive("zh", Map([("app.ok", "确定")]))
  l10n.add_archive("en", Map([("app.title", "Moon"), ("app.ok", "OK")]))
  l10n.set_locale("zh")
  // zh 档缺 app.title、en 档有——报错点名 key 与 locale，不拿 en 档顶上
  let msg = try {
    let _ = l10n.text("app.title")
    None
  } catch {
    e => Some(e.message())
  }
  assert_eq(
    msg,
    Some("操作失败：L10n 缺少文案 key app.title（locale=zh）"),
  )
  // 显式缺席的 Option 通道：缺席是 None，常态照常往返
  assert_eq(l10n.text_or("app.title"), None)
  assert_eq(l10n.text_or("app.ok"), Some("确定"))
  // 切到没注册的 locale：显式报错，不是静默变成空档
  l10n.set_locale("en")
  let msg2 = try {
    l10n.set_locale("fr")
    None
  } catch {
    e => Some(e.message())
  }
  assert_eq(
    msg2,
    Some("操作失败：L10n 未注册 locale fr，不能切换"),
  )
  // 报错之后当前档原地（en），查表照常
  assert_eq(l10n.locale(), "en")
  assert_eq(l10n.text("app.title"), "Moon")
}

///|
test "L10n 切档语义：新建控件生效，存量控件文案自理（T88②判据·记案语义）" {
  let b = MockBackend::new()
  Backend::init(b)
  let l10n = L10n::new()
  l10n.add_archive("zh", Map([("app.ok", "确定")]))
  l10n.add_archive("en", Map([("app.ok", "OK")]))
  l10n.set_locale("zh")
  // 构造时刻查表：文案烙进控件
  let existing = l10n.button(b, "app.ok")
  assert_eq(existing.text(), "确定")
  // 切档：存量控件不动（刷新由应用自理——记案语义，判据钉的就是这条）
  l10n.set_locale("en")
  assert_eq(existing.text(), "确定")
  // 新建控件按新档生效
  let fresh = l10n.button(b, "app.ok")
  let label = l10n.label(b, "app.ok")
  assert_eq(fresh.text(), "OK")
  assert_eq(label.text(), "OK")
  // 档案整份替换：重新注册同 locale 即覆盖，查表与新建控件跟上
  l10n.add_archive("en", Map([("app.ok", "Okay")]))
  assert_eq(l10n.text("app.ok"), "Okay")
  assert_eq(l10n.button(b, "app.ok").text(), "Okay")
  Backend::terminate(b)
  assert_eq(b.live(), 0)
}
