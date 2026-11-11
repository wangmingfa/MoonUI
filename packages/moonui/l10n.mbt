///|
/// 国际化——文案层与资源层（`T88②`）：MoonBit 侧一条实现，两平台零分叉。
///
/// 资源层是**程序内注册的档案**（locale → key → 文案的查表）。`T88②` 先只做
/// 程序注册（资源跟着应用代码走，一条 MoonBit 数据声明在哪个平台都能编译）；
/// `T93②` 补上"档案从文件进来"那半，用的是 `T197` 的 `Fs` 门面——读档那层在
/// native 上走 libc、wasm 上同签名显式报 `Unsupported`，缺席纪律（§33）不外溢：
/// 调用方在哪个平台都只看见 `UiError`。
///
/// 文件格式就是设置档那份 JSON 对象（`settings.mbt` 的同一口径）：
/// `{"app.title": "月亮", "app.ok": "确定"}`。不另造一门小语言的理由是最小加法
/// ——`@json` 已在 Core 的依赖里，转义/嵌套/编码这些坑都在库里；多一门自造格式
/// 就多一套要自己写判据的解析器。
///
/// 缺席纪律（§33——不静默回退）：查表缺 key 是**显式缺席**，错误串带 key 与
/// locale 当场点名；不跨 locale 回退（zh 档缺的 key 不会拿 en 档的顶上）、不
/// 回退默认串——静默回退只会把"漏翻译"藏进界面里。显式缺席的另一半通道是
/// `text_or`（Option 语义，`window_state` 读档的"缺席是常态"同一条读法——
/// 哪些 key 允许缺席由应用自己点名，框架不猜）。读档同一条口径：缺档、不是
/// JSON、顶层不是对象、某个值不是字符串，四种都当场报错点名 path 与 key，
/// **不**跳过坏条目注册半份档——半份档在界面上就是"漏翻译"，正是要拦住的东西。
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
/// 从整份文本注册一份档案（`T93②`）：顶层必须是 JSON 对象，每个值必须是字符串。
///
/// 与 `Settings::parse` 的分叉点在这里：设置档解析不了返回 `None`（"档坏了就当
/// 没设过"），文案档解析不了**必须报错**——少一份档等于整个应用查不到文案，
/// 静默退回空档只会让界面四处显式缺席，报错反而离病因更近。
pub fn L10n::add_archive_json(
  self : L10n,
  locale : String,
  text : String,
) -> Unit raise UiError {
  l10n_register(self, locale, text, "（内存文本）")
}

///|
/// 从文件读一份档案（`T93②`）：读不出来的系统错误、缺档、格式不对都显式报错，
/// 错误串点名 path 与 locale。
///
/// 缺档为什么也报错：语言档不是"第一次启动没有是常态"的那类档（`Fs::read_text`
/// 返回 `None` 的常态口径），它是应用**自己点名要读**的资源——点名要的档不在，
/// 就是配置坏了。要"没有就退回程序注册"的应用，用 `Fs::read_text` 先判存在，
/// 或者自己吞掉这条错误；框架不替它猜。
pub fn L10n::add_archive_file(
  self : L10n,
  locale : String,
  path : String,
) -> Unit raise UiError {
  match Fs::read_text(path) {
    None =>
      raise OperationFailed(
        "L10n 文案档不存在：\{path}（locale=\{locale}）",
      )
    Some(text) => l10n_register(self, locale, text, path)
  }
}

///|
/// 读档/解析的共同落点：解析出来的是**整份**档案，要么全收、要么一条都不收。
/// `source` 只用于错误串（文件路径，或"内存文本"）。
fn l10n_register(
  l10n : L10n,
  locale : String,
  text : String,
  source : String,
) -> Unit raise UiError {
  let j = @json.parse(text) catch {
    _ =>
      raise OperationFailed(
        "L10n 文案档 \{source} 不是合法 JSON（locale=\{locale}）",
      )
  }
  match j {
    Object(m) => {
      let entries : Map[String, String] = Map([])
      for k, v in m {
        match v {
          String(s) => entries.set(k, s)
          _ =>
            raise OperationFailed(
              "L10n 文案档 \{source} 的 key \{k} 不是字符串（locale=\{locale}）",
            )
        }
      }
      l10n.add_archive(locale, entries)
    }
    _ =>
      raise OperationFailed(
        "L10n 文案档 \{source} 顶层必须是 JSON 对象（locale=\{locale}）",
      )
  }
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
test "L10n 从文本读档：JSON 对象整份收下，转义与中文原样往返（T93②判据）" {
  let l10n = L10n::new()
  l10n.add_archive_json(
    "zh", "{\"app.title\": \"月亮\", \"app.quote\": \"他说：\\\"好\\\"\", \"app.tab\": \"甲\\t乙\"}",
  )
  l10n.set_locale("zh")
  assert_eq(l10n.text("app.title"), "月亮")
  assert_eq(l10n.text("app.quote"), "他说：\"好\"")
  assert_eq(l10n.text("app.tab"), "甲\t乙")
  // 空对象是合法的"一份空档"：能切档，查表走既有缺席纪律（不是解析失败）
  l10n.add_archive_json("fr", "{}")
  l10n.set_locale("fr")
  assert_eq(l10n.text_or("app.title"), None)
}

///|
test "L10n 读档的四种坏档全部显式报错，且一条都不注册（T93②判据·§33）" {
  let l10n = L10n::new()
  let msg = fn(f : () -> Unit raise UiError) -> String? {
    try {
      f()
      None
    } catch {
      e => Some(e.message())
    }
  }
  // ① 不是 JSON
  assert_eq(
    msg(fn() raise UiError { l10n.add_archive_json("zh", "{not json") }),
    Some(
      "操作失败：L10n 文案档 （内存文本） 不是合法 JSON（locale=zh）",
    ),
  )
  // ② 顶层不是对象（数组没有"字段"可言）
  assert_eq(
    msg(fn() raise UiError { l10n.add_archive_json("zh", "[\"月亮\"]") }),
    Some(
      "操作失败：L10n 文案档 （内存文本） 顶层必须是 JSON 对象（locale=zh）",
    ),
  )
  // ③ 某个值不是字符串：点名那只 key
  assert_eq(
    msg(fn() raise UiError { l10n.add_archive_json("zh", "{\"app.ok\": 1}") }),
    Some(
      "操作失败：L10n 文案档 （内存文本） 的 key app.ok 不是字符串（locale=zh）",
    ),
  )
  // ④ 坏档一条都不许落地：zh 没注册过，切档当场报错
  assert_eq(
    msg(fn() raise UiError { l10n.set_locale("zh") }),
    Some("操作失败：L10n 未注册 locale zh，不能切换"),
  )
  // 反过来：整份好的照样进得去（证明上面三次失败没把对象弄脏）
  l10n.add_archive_json("zh", "{\"app.ok\": \"确定\"}")
  l10n.set_locale("zh")
  assert_eq(l10n.text("app.ok"), "确定")
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
