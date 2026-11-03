///|
/// `T200`：`trim_ws` 与 core 的 `trim()` 的差别就在全角空格上——这条判据同时
/// 钉住"认 U+3000"与"不误伤中间的空白"（trim 只该动两侧）。
test "trim_ws：认全角空格，中间的不动（T200）" {
  // core 的默认集只有 \t\n\r 空格：全角空格会被原样留下（这就是本函数存在的理由）
  assert_eq("　周杰伦　".trim().to_owned(), "　周杰伦　")
  assert_eq(@util.trim_ws("　周杰伦　"), "周杰伦")
  // 两侧混着来一样处理
  assert_eq(@util.trim_ws(" \t\n晴天\r\n　"), "晴天")
  // 中间的空白属于内容，一个字都不能动
  assert_eq(@util.trim_ws("晴天 周杰伦"), "晴天 周杰伦")
  assert_eq(@util.trim_ws("晴天　周杰伦"), "晴天　周杰伦")
  // 空串与纯空白
  assert_eq(@util.trim_ws(""), "")
  assert_eq(@util.trim_ws("　 \t"), "")
}

///|
/// `T200`：`squeeze_ws` 删的是**全部**空白（不只是两侧），而且不把非 BMP
/// 字符拼坏——按段切片再拼接的实现如果退化成"逐码元重建"，表情符号会变成乱码，
/// 这条判据就是那道闸。
test "squeeze_ws：删全部空白，代理对不被拆开（T200）" {
  assert_eq(@util.squeeze_ws(" 晴 天 "), "晴天")
  assert_eq(@util.squeeze_ws("晴天　-　周杰伦"), "晴天-周杰伦")
  assert_eq(@util.squeeze_ws("a\tb\nc\rd"), "abcd")
  // 没有空白时原样返回（不是"重新拼一遍"）
  assert_eq(@util.squeeze_ws("晴天"), "晴天")
  assert_eq(@util.squeeze_ws(""), "")
  // 非 BMP：每个表情是 UTF-16 的代理对，逐码元拼回去会坏
  assert_eq(@util.squeeze_ws("😀 a 😀"), "😀a😀")
  assert_eq(@util.squeeze_ws("😀"), "😀")
}

///|
/// `T200`：`same_text_ci` = 抹平空白 + 忽略 ASCII 大小写。
/// 两条都得测：只测大小写的话，"空白版本也只抹不平"这种半边坏掉看不出来。
test "same_text_ci：空白与 ASCII 大小写都不算差别（T200）" {
  assert_true(@util.same_text_ci("周杰伦", "周杰伦　"))
  assert_true(@util.same_text_ci("晴天-周杰伦", "晴天 - 周杰伦"))
  assert_true(@util.same_text_ci("Hello", "hello"))
  assert_true(@util.same_text_ci("", "　"))
  assert_false(@util.same_text_ci("晴天", "晴天2"))
  // 只折叠 ASCII：非 ASCII 的大小写折叠属各语言自己的规则，这里不猜
  assert_false(@util.same_text_ci("Ä", "ä"))
}

///|
/// `T200`：纯 ASCII 数字串，空串不算；全角数字不算（它是歌名里的字符，
/// 不是编号）。
test "is_all_digits：只认 0-9，空串与全角都不算（T200）" {
  assert_true(@util.is_all_digits("2004"))
  assert_true(@util.is_all_digits("03"))
  assert_true(@util.is_all_digits("0"))
  assert_false(@util.is_all_digits(""))
  assert_false(@util.is_all_digits("20 04"))
  assert_false(@util.is_all_digits("２０"))
  assert_false(@util.is_all_digits("20a"))
  assert_false(@util.is_all_digits("-1"))
}
