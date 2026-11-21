///|
/// 应用内图标注册表（`T339`）：应用自有图标名 → 平台解析通道的记账。
/// 进程级——系统/主题图标表在一次会话里是静态事实，同一名字重复解析没有
/// 第二种结果，缓存按名字记账即可，不随 Backend 实例走。
///
/// 两层语义：
/// 1. `Assets::register` 把一个名字登记成"应用已知"——之后 `resolve` 在
///    **所有**平台上都真（注册表优先于平台探测，mock 上也一样）。这给
///    应用一条"自带图标"的命名空间，不必知道平台给不给得出这个名字。
/// 2. `Assets::resolve` 按名字要一个"平台给不给得出这张图标"的判断：
///    先查注册表，再查缓存，都未命中才走一次平台探测（Backend::icon_resolved，
///    mac 查 SF Symbols、Linux 查图标主题 hicolor、Windows 显式缺席）。
///    结果按名字缓存，同一名字只探一次。

///|
/// 图标服务的命名空间载体：注册表与缓存都是进程级的，这个类型只是把
/// `Assets::register` / `Assets::resolve` 挂到一个可读的名字下。
pub(all) struct Assets {
  /// 占位：实例无状态，进程级表见 `icon_registry`。
  _private : Unit
}

///|
/// 占位构造（命名空间类型不需要实例，但包内不给一个构造点会被
/// "never constructed" 判掉）。
pub fn Assets::new() -> Assets {
  { _private: (), }
}

///|
/// 注册表：应用经 register 登记的名字。产品路径只增不减——"应用已知"
/// 是会话级的静态事实，与平台探测缓存（会随 clear_for_test 抹掉重放）
/// 分开记，clear 抹缓存不该动到注册。
let icon_registered : Map[String, Bool] = Map([], capacity=8)

///|
/// 探测缓存：平台问过的名字按结果记，同一名字最多探一次。
let icon_cache : Map[String, Bool] = Map([], capacity=32)

///|
/// 把一个图标名登记成"应用已知"：之后 `Assets::resolve` 在所有平台都真。
/// 重复登记幂等。名字空间由应用自己约定（如 `"app/rewind"`），与平台的
/// 系统图标名不冲突即可——平台表里已有的名字不该被注册盖掉语义，这里
/// 不拦截，靠约定。
pub fn Assets::register(name : String) -> Unit {
  icon_registered[name] = true
}

///|
/// 按名字要"平台给不给得出这张图标"的判断（`T339`）。注册过的名字直接真；
/// 未注册的走一次平台探测并把结果缓存——同一名字最多探一次。
pub fn[B : Backend] Assets::resolve(backend : B, name : String) -> Bool {
  if icon_registered.contains(name) {
    return true
  }
  match icon_cache.get(name) {
    Some(v) => return v
    None => ()
  }
  let v = backend.icon_resolved(name)
  icon_cache[name] = v
  v
}

///|
/// 把探测缓存抹掉（测试缝）：平台图标表在一次会话里是静态的，产品路径
/// 没有需要重算的场景；mock 判据要重放"未命中 → 探测"那一步时用。
/// **注册表不动**——注册是应用自有的事实，不是缓存。
pub fn Assets::clear_for_test() -> Unit {
  icon_cache.clear()
}

///|
/// 从注册表摘掉一个名字（测试缝）：注册是进程级的，同一个测试二进制里的
/// 多个判据共用它——判据 A 注册过的名字会渗进判据 B 的预期。产品路径
/// 不摘（应用已知是会话级事实）。
pub fn Assets::unregister_for_test(name : String) -> Unit {
  let _ = icon_registered.remove(name)
  let _ = icon_cache.remove(name)
}
