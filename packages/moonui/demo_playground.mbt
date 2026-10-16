///|
/// Playground 双档 Demo 本体（2026-10-16，owner 裁决在案）：独立双档——
/// **DSL 构树描述档**（一段贴 `T83` 脸的文本形状，无头可判、可进门禁）加
/// **参数面板档**（左树右面板，选中→读回→改值→即时重渲染）。判据随包
/// （黑盒 playground_test.mbt），无头薄壳进 examples/playground（[Demo 10]），
/// 真窗演示壳进 examples/playground-native（不进任何自动闸门）。
///
/// === 裁决理由：DSL 吃文本形状，不吃 MoonBit 源码 ===
///
/// DSL 的输入是**文本形状的一段构树描述**——`Row(8, [Text("Hello").font_size(18)])`
/// 风格——不是 MoonBit 源码。MoonBit 不是脚本语言、没有 eval：编译后的程序读不到
/// "一段 MoonBit 表达式"的求值通道，把源码当输入要么另带编译器（荒唐）、要么静默
/// 打折扣（§33 不许）。所以 DSL 定格为"种类×构造参数 + 外观链 + children 括号"
/// 的文本形状，解析器是纯 MoonBit 递归下降（tokens → 种类 → 参数 → 链 → children
/// 递归），零 C 零 ABI 零 Event 变体。
///
/// === 文法定稿表（第一版盖全的形状；实现与 T83 脸逐条对表） ===
///
/// 种类（11 个，构造参数按旧命令式构造族 `Widget::*` 的签名定稿）：
///
/// | DSL 种类    | MoonBit 脸                        | 构造参数文法 |
/// | ----------- | --------------------------------- | ------------ |
/// | Row         | `Widget::row(b, spacing, kids)`   | spacing: 数字，children `[...]` 必需 |
/// | Column      | `Widget::column(b, spacing, kids)`| 同 Row |
/// | Padding     | `Widget::padding(b, insets, kid)` | insets: 数字（=all）或四数字（top,end,bottom,start 字段序），children `[...]` 必需、钉单元素 |
/// | Text        | `Widget::label(b, text)`          | text: 字符串 |
/// | Button      | `Widget::button(b, text)`         | text: 字符串 |
/// | CheckBox    | `Widget::checkbox(b, text, v)`    | text: 字符串，checked: true/false |
/// | Slider      | `Widget::slider(b, min, max)`     | min, max: 整数档数字（带小数点显式报错） |
/// | ProgressBar | `Widget::progress(b)`             | 无参数（空括号） |
/// | ComboBox    | `Widget::combobox(b, options)`    | options: 字符串数组 `["a","b"]` |
/// | RadioButtons| `Widget::radio_buttons(b, opts)`  | options 同 ComboBox |
/// | MenuRow     | `Widget::menu_row(b, text, sel)`  | text: 字符串，selected: true/false |
///
/// 外观链（11 条，即 `T83` 的 11 条链；值文法逐条钉死）：
///
/// | 链名       | 值文法 |
/// | ---------- | ------ |
/// | font_size  | 数字 |
/// | font_weight| Regular / Medium / Bold |
/// | foreground | #RRGGBB 颜色字面量 |
/// | background | #RRGGBB 颜色字面量 |
/// | opacity    | 数字 |
/// | radius     | 数字 |
/// | width      | 数字（注记：`T94` 在案——width 覆盖存进局部样式但测量未消费，判据只断样式账不断 frame） |
/// | height     | 数字（同 width 注记） |
/// | min_width  | 数字 |
/// | max_width  | 数字 |
/// | margin     | 数字（=all）或四数字（top,end,bottom,start 字段序） |
///
/// 词法与语法的其余形状：字符串字面量双引号、转义只支持 `\\` 与 `\"`（其余
/// 显式报错）；数字档支持可选负号与可选小数点；children 与 options 都是
/// `[...]` 括号（按种类位置分档——Row 要 children、ComboBox 要 options，
/// 形状混放显式报错）；同节点重复同名链**允许**、后链赢（与 MoonBit 脸
/// `layer_local` 的稀疏合并语义同账）。
///
/// === 等真需求（第一版宁小勿滥，缺席都是显式的） ===
///
/// - **行为/事件链**：`on_click` 等需要闭包——DSL 文本表示闭包是深水区
///   （语法的语义通道、回调的文本账），第一版不做；面板档的行为接线走
///   程序 API，等真需求再按 `T18` 判据分。
/// - **种类**：Spinbox / PasswordInput / Multiline / DatePicker / Image /
///   Separator / VSeparator / Spacer / Center / Sized / Stack / Grid / Scroll
///   不在这版文法里（上面 11 个盖的是通用构造族——列出以证缺席）。
/// - **面板侧**：options / min / max 等构造参数的编辑（只读回）等真需求；
///   内容树的真点击选中需要"重建后重挂命中订阅"的钩子（面板行的接线随
///   重建自挂、内容树的接线不随重建幸存），第一版选中走 `select_at`
///   （Mock 判据经 `Window::widget_at`——`T86①` 右键命中反查同族）加面板
///   控件接线；选中高亮描框等真需求。
///
/// === 面板档的缝合法（头注记案） ===
///
/// 面板改一条参数 = **改描述 = 解析重建**：选中账记内容根到选中叶子的下标
/// 路径（AST 是描述账的解析账），面板改值先改 AST 节点，再 `to_dsl()` 序列化
/// 成新描述、`parse` 再解析、`build` 构树、`set_content` 整棵换——"描述→解析→
/// 构树→set_content 整棵换"的闭环正好把 DSL 档和面板档缝在一起。序列化输出
/// 闭合于文法（`to_dsl` 只产文法内的形状），再解析防炸照显式 raise（§33）。
/// `set_content` 的既有语义负责旧树整棵回收与新树挂接（§8），重建零手工回收。
/// 选中按路径幸存（链值编辑不改结构），状态行显式显示每次编辑的结果（§33
/// 不静默——面板校验失败的描述不变、状态行点名收到什么）。

///|
/// DSL 值档（判据与面板编辑共用一张表）：形状在解析时按种类/链名钉死，
/// 构树时按表取值。
pub(all) enum PlayValue {
  Num(Double)
  Str(String)
  Bool(Bool)
  /// 颜色字面量存原文（"#RRGGBB" 形状在词法钉死）——序列化往返按原文。
  Color(String)
  /// 枚举字面量（font_weight 的 Regular/Medium/Bold），存原文。
  Ident(String)
  /// 内缩/margin 形：1 个数字 = all，4 个按 (top,end,bottom,start) 字段序。
  NumList(Array[Double])
  /// options 形（ComboBox / RadioButtons）。
  StrList(Array[String])
} derive(Debug, Eq)

///|
/// 一条外观链：链名 + 值 + 链名记号偏移（错误报告用）。
pub(all) struct PlayChain {
  name : String
  mut value : PlayValue
  offset : Int32
} derive(Debug, Eq)

///|
/// DSL 构树描述的解析账：种类名 + 构造参数（children 除外）+ children 递归 +
/// 外观链。判据与面板编辑直接读写这份账。
pub(all) struct PlayNode {
  kind : String
  params : Array[PlayValue]
  children : Array[PlayNode]
  chains : Array[PlayChain]
  offset : Int32
} derive(Debug, Eq)

///|
/// 词法记号：形状档 + 原文 + 字符偏移 + 记号序号（1 起，错误报告用）。
priv struct Token {
  tag : TokTag
  text : String
  offset : Int32
  index : Int32
}

///|
priv enum TokTag {
  Ident
  Num
  Str
  Color
  Punct
}

///|
/// 链的形状档（值文法按形状分档：数值 / 枚举 / 颜色 / 内缩）。
priv enum PlayChainShape {
  CNum
  CWeight
  CColor
  CInsets
}

///|
/// 单字符读法：第 i 个 code unit 成 1 长字符串（词法循环按它走——与
/// demo_dx 的 `s[0:2].to_owned()` 切片同款，不用字符 API 猜形状）。
fn unit_at(s : String, i : Int32) -> String {
  s[i:i + 1].to_owned()
}

///|
fn play_is_digit(u : String) -> Bool {
  u == "0" ||
  u == "1" ||
  u == "2" ||
  u == "3" ||
  u == "4" ||
  u == "5" ||
  u == "6" ||
  u == "7" ||
  u == "8" ||
  u == "9"
}

///|
fn play_digit_val(u : String) -> Int32 {
  if u == "0" {
    0
  } else if u == "1" {
    1
  } else if u == "2" {
    2
  } else if u == "3" {
    3
  } else if u == "4" {
    4
  } else if u == "5" {
    5
  } else if u == "6" {
    6
  } else if u == "7" {
    7
  } else if u == "8" {
    8
  } else if u == "9" {
    9
  } else {
    0
  }
}

///|
/// 十六进制一位（0..9 / a..f / A..F → 0..15），颜色字面量与面板校验共用。
fn play_hex_val(u : String) -> Int32? {
  if u == "0" {
    Some(0)
  } else if u == "1" {
    Some(1)
  } else if u == "2" {
    Some(2)
  } else if u == "3" {
    Some(3)
  } else if u == "4" {
    Some(4)
  } else if u == "5" {
    Some(5)
  } else if u == "6" {
    Some(6)
  } else if u == "7" {
    Some(7)
  } else if u == "8" {
    Some(8)
  } else if u == "9" {
    Some(9)
  } else if u == "a" {
    Some(10)
  } else if u == "b" {
    Some(11)
  } else if u == "c" {
    Some(12)
  } else if u == "d" {
    Some(13)
  } else if u == "e" {
    Some(14)
  } else if u == "f" {
    Some(15)
  } else if u == "A" {
    Some(10)
  } else if u == "B" {
    Some(11)
  } else if u == "C" {
    Some(12)
  } else if u == "D" {
    Some(13)
  } else if u == "E" {
    Some(14)
  } else if u == "F" {
    Some(15)
  } else {
    None
  }
}

///|
/// 标识符起步档（字母或下划线）。
fn play_is_ident_start(u : String) -> Bool {
  (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || u == "_"
}

///|
/// 标识符续档（字母、数字或下划线）。单字符比较走 code unit 序——
/// 词法只盖 ASCII（种类/链/枚举名都是 ASCII），中文走字符串字面量。
fn play_is_ident_unit(u : String) -> Bool {
  play_is_ident_start(u) || play_is_digit(u)
}

///|
/// 文本 → 数字（面板编辑与词法复查共用一条）：可选负号、整数段、可选小数
/// 段；全量消耗、缺段显式缺席（返回 None，不许静默截断）。手工累积——
/// 不依赖字符串转数字的库函数。
fn play_num_of(text : String) -> Double? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if unit_at(text, 0) == "-" {
    neg = true
    i = 1
    if n == 1 {
      return None
    }
  }
  let mut saw_digit = false
  while i < n && play_is_digit(unit_at(text, i)) {
    saw_digit = true
    i = i + 1
  }
  if !saw_digit {
    return None
  }
  let mut has_frac = false
  if i < n {
    if unit_at(text, i) == "." {
      has_frac = true
      i = i + 1
      let mut frac_digit = false
      while i < n && play_is_digit(unit_at(text, i)) {
        frac_digit = true
        i = i + 1
      }
      if !frac_digit {
        return None
      }
    } else {
      return None
    }
  }
  if i != n {
    return None
  }
  let mut j = if neg { 1 } else { 0 }
  let mut whole = 0.0
  while j < n {
    let u = unit_at(text, j)
    if u == "." {
      break
    }
    whole = whole * 10.0 + play_digit_val(u).to_double()
    j = j + 1
  }
  let mut frac = 0.0
  if has_frac {
    j = j + 1
    let mut div = 10.0
    while j < n {
      frac = frac + play_digit_val(unit_at(text, j)).to_double() / div
      div = div * 10.0
      j = j + 1
    }
  }
  let v = whole + frac
  Some(if neg { -v } else { v })
}

///|
/// 数字记号文本里有没有小数点（Slider 的整数档检查用）。
fn play_has_dot(text : String) -> Bool {
  for i = 0; i < text.length(); i = i + 1 {
    if unit_at(text, i) == "." {
      return true
    }
  }
  false
}

///|
/// 颜色字面量 → Color（"#RRGGBB"，两位一位十六进制逐位换算）。
/// 面板编辑与构树共用——形状不对显式缺席（None）。
fn play_color_parse(s : String) -> Color? {
  if s.length() != 7 {
    return None
  }
  if unit_at(s, 0) != "#" {
    return None
  }
  match (play_hex2(s, 1), play_hex2(s, 3), play_hex2(s, 5)) {
    (Some(r), Some(g), Some(b)) => Some(Color::rgb(r, g, b))
    _ => None
  }
}

///|
/// 两位十六进制（s[i:i+2] → 0..255）。
fn play_hex2(s : String, i : Int32) -> Int32? {
  match (play_hex_val(unit_at(s, i)), play_hex_val(unit_at(s, i + 1))) {
    (Some(hi), Some(lo)) => Some(hi * 16 + lo)
    _ => None
  }
}

///|
/// 枚举字面量 → FontWeight（面板编辑与构树共用）。
fn play_weight_of(text : String) -> FontWeight? {
  if text == "Regular" {
    Some(Regular)
  } else if text == "Medium" {
    Some(Medium)
  } else if text == "Bold" {
    Some(Bold)
  } else {
    None
  }
}

///|
/// 内缩文本 → 字段序数字段（"8" = all 单值；"8,0,8,0" = 四值；其余 None）。
fn play_insets_parse(text : String) -> Array[Double]? {
  let xs : Array[Double] = []
  for p in text.split(",") {
    match play_num_of(p.to_owned()) {
      Some(d) => xs.push(d)
      None => return None
    }
  }
  if xs.length() == 1 || xs.length() == 4 {
    Some(xs)
  } else {
    None
  }
}

///|
/// 记号形状档判断（不用枚举相等——按变体模式走）。
fn tok_is_punct(t : Token, mark : String) -> Bool {
  match t.tag {
    Punct => t.text == mark
    _ => false
  }
}

///|
fn tok_is_ident(t : Token) -> Bool {
  match t.tag {
    Ident => true
    _ => false
  }
}

///|
fn tok_is_num(t : Token) -> Bool {
  match t.tag {
    Num => true
    _ => false
  }
}

///|
fn tok_is_str(t : Token) -> Bool {
  match t.tag {
    Str => true
    _ => false
  }
}

///|
fn tok_is_color(t : Token) -> Bool {
  match t.tag {
    Color => true
    _ => false
  }
}

///|
/// 记号定位前缀（第几段 + 字符偏移——错误报告的"位置"形状）。
fn play_err_tok(t : Token, body : String) -> UiError {
  OperationFailed(
    "playground DSL：第 \{t.index} 个记号（偏移 \{t.offset}）：\{body}",
  )
}

///|
/// 词法：文本 → 记号数组。空白跳过；字符串转义只支持 `\\` 与 `\"`；数字
/// 可选负号可选小数点；颜色 #RRGGBB；其余显式报错带偏移。
fn play_tokenize(text : String) -> Array[Token] raise UiError {
  let toks : Array[Token] = []
  let n = text.length()
  let mut i = 0
  while i < n {
    let u = unit_at(text, i)
    if u == " " || u == "\t" || u == "\n" || u == "\r" {
      i = i + 1
    } else if u == "(" ||
      u == ")" ||
      u == "[" ||
      u == "]" ||
      u == "," ||
      u == "." {
      toks.push({ tag: Punct, text: u, offset: i, index: toks.length() + 1, })
      i = i + 1
    } else if u == "\"" {
      let start = i
      let mut payload = ""
      let mut j = i + 1
      let mut closed = false
      while j < n {
        let cu = unit_at(text, j)
        if cu == "\"" {
          closed = true
          j = j + 1
          break
        } else if cu == "\\" {
          if j + 1 < n {
            let nx = unit_at(text, j + 1)
            if nx == "\\" {
              payload = payload + "\\"
              j = j + 2
            } else if nx == "\"" {
              payload = payload + "\""
              j = j + 2
            } else {
              raise OperationFailed(
                "playground DSL：偏移 \{j}：转义只支持 \\ 与 \\\"（收到 \\\{nx}）",
              )
            }
          } else {
            raise OperationFailed(
              "playground DSL：偏移 \{j}：转义只支持 \\ 与 \\\"（收到挂尾）",
            )
          }
        } else {
          payload = payload + cu
          j = j + 1
        }
      }
      if !closed {
        raise OperationFailed(
          "playground DSL：偏移 \{start}：字符串未闭合",
        )
      }
      toks.push({
        tag: Str,
        text: payload,
        offset: start,
        index: toks.length() + 1,
      })
      i = j
    } else if u == "#" {
      let start = i
      let mut j = i + 1
      let mut hexs = ""
      while j < n {
        match play_hex_val(unit_at(text, j)) {
          Some(_) => {
            hexs = hexs + unit_at(text, j)
            j = j + 1
          }
          None => break
        }
      }
      if j - start - 1 != 6 {
        raise OperationFailed(
          "playground DSL：偏移 \{start}：颜色字面量要 #RRGGBB（收到 \{hexs}）",
        )
      }
      toks.push({
        tag: Color,
        text: "#" + hexs,
        offset: start,
        index: toks.length() + 1,
      })
      i = j
    } else if play_is_digit(u) || u == "-" {
      let start = i
      let mut j = i
      if u == "-" {
        if i + 1 < n && play_is_digit(unit_at(text, i + 1)) {
          j = i + 1
        } else {
          raise OperationFailed(
            "playground DSL：偏移 \{start}：不认识的记号（-）",
          )
        }
      }
      while j < n && play_is_digit(unit_at(text, j)) {
        j = j + 1
      }
      if j < n && unit_at(text, j) == "." {
        j = j + 1
        while j < n && play_is_digit(unit_at(text, j)) {
          j = j + 1
        }
      }
      let ntext = text[start:j].to_owned()
      match play_num_of(ntext) {
        Some(_) => ()
        None =>
          raise OperationFailed(
            "playground DSL：偏移 \{start}：数字记号形状不对（\{ntext}）",
          )
      }
      toks.push({
        tag: Num,
        text: ntext,
        offset: start,
        index: toks.length() + 1,
      })
      i = j
    } else if play_is_ident_start(u) {
      let start = i
      let mut j = i
      while j < n && play_is_ident_unit(unit_at(text, j)) {
        j = j + 1
      }
      toks.push({
        tag: Ident,
        text: text[start:j].to_owned(),
        offset: start,
        index: toks.length() + 1,
      })
      i = j
    } else {
      raise OperationFailed(
        "playground DSL：偏移 \{i}：不认识的记号（\{u}）",
      )
    }
  }
  toks
}

///|
/// 递归下降解析器状态：记号数组 + 游标。
priv struct PlayParser {
  toks : Array[Token]
  mut pos : Int32
}

///|
fn PlayParser::peek(self : PlayParser) -> Token? {
  if self.pos < self.toks.length() {
    Some(self.toks[self.pos])
  } else {
    None
  }
}

///|
/// 游标后第二格（数字形内缩的续档判断用）。
fn PlayParser::peek2(self : PlayParser) -> Token? {
  let i = self.pos + 1
  if i < self.toks.length() {
    Some(self.toks[i])
  } else {
    None
  }
}

///|
fn PlayParser::expect_punct(
  self : PlayParser,
  mark : String,
  message : String,
) -> Unit raise UiError {
  match self.peek() {
    Some(t) =>
      if tok_is_punct(t, mark) {
        self.pos = self.pos + 1
      } else {
        raise play_err_tok(t, "\{message}（收到 \{t.text}）")
      }
    None => raise OperationFailed("playground DSL：意外收尾：\{message}")
  }
}

///|
/// 数字形参数（可选负号可选小数点——整数档约束在种类分支里另查）。
fn PlayParser::expect_num_param(
  self : PlayParser,
  name : String,
  kind : String,
) -> Double raise UiError {
  match self.peek() {
    Some(t) =>
      if tok_is_num(t) {
        self.pos = self.pos + 1
        match play_num_of(t.text) {
          Some(d) => d
          None =>
            raise OperationFailed(
              "playground DSL：构树账错位：数字 \{t.text}",
            )
        }
      } else {
        raise play_err_tok(
          t,
          "\{name} 的值是数字（\{kind}——收到 \{t.text}）",
        )
      }
    None =>
      raise OperationFailed(
        "playground DSL：意外收尾：缺少参数 \{name}（\{kind}）",
      )
  }
}

///|
/// 整数档数字形参数（Slider 的 min/max——带小数点显式报错）。
fn PlayParser::expect_range_param(
  self : PlayParser,
  name : String,
  kind : String,
) -> Double raise UiError {
  let d = self.expect_num_param(name, kind)
  let dtok = self.toks[self.pos - 1]
  if play_has_dot(dtok.text) {
    raise play_err_tok(
      dtok,
      "\{kind} 的 \{name} 是整数档（收到 \{dtok.text}——带小数点）",
    )
  }
  d
}

///|
fn PlayParser::expect_str_param(
  self : PlayParser,
  name : String,
  kind : String,
) -> String raise UiError {
  match self.peek() {
    Some(t) =>
      if tok_is_str(t) {
        self.pos = self.pos + 1
        t.text
      } else {
        raise play_err_tok(
          t,
          "\{name} 的值是字符串（\{kind}——收到 \{t.text}）",
        )
      }
    None =>
      raise OperationFailed(
        "playground DSL：意外收尾：缺少参数 \{name}（\{kind}）",
      )
  }
}

///|
/// 布尔参数（true/false 字面量——标识符档按文本核对，其余显式报错）。
fn PlayParser::expect_bool_param(
  self : PlayParser,
  name : String,
  kind : String,
) -> Bool raise UiError {
  match self.peek() {
    Some(t) => {
      let bad = play_err_tok(
        t,
        "\{name} 的值是 true/false（\{kind}——收到 \{t.text}）",
      )
      if tok_is_ident(t) {
        if t.text == "true" {
          self.pos = self.pos + 1
          true
        } else if t.text == "false" {
          self.pos = self.pos + 1
          false
        } else {
          raise bad
        }
      } else {
        raise bad
      }
    }
    None =>
      raise OperationFailed(
        "playground DSL：意外收尾：缺少参数 \{name}（\{kind}）",
      )
  }
}

///|
/// 数字形内缩（1 个 = all；4 个按 top,end,bottom,start 字段序；其余显式报错）。
/// `Padding(...)` 的 insets 与 `.margin(...)` 的值共用这条。
fn PlayParser::parse_numlist(
  self : PlayParser,
  what : String,
) -> Array[Double] raise UiError {
  let d1 = match self.peek() {
    Some(t) =>
      if tok_is_num(t) {
        self.pos = self.pos + 1
        match play_num_of(t.text) {
          Some(d) => d
          None =>
            raise OperationFailed(
              "playground DSL：构树账错位：数字 \{t.text}",
            )
        }
      } else {
        raise play_err_tok(
          t,
          "\{what} 的值是数字（=all）或四个数字（top,end,bottom,start）（收到 \{t.text}）",
        )
      }
    None =>
      raise OperationFailed(
        "playground DSL：意外收尾：\{what} 的值是数字（=all）或四个数字（top,end,bottom,start）",
      )
  }
  let xs : Array[Double] = [d1]
  let mut going = true
  while going {
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ",") {
          // 续档条件：逗号后面还是数字（否则逗号属于 children/options 那格）
          match self.peek2() {
            Some(t2) =>
              if tok_is_num(t2) {
                // 逗号与数字一起消耗（游标推进两格）
                self.pos = self.pos + 2
                match play_num_of(t2.text) {
                  Some(d) => xs.push(d)
                  None =>
                    raise OperationFailed(
                      "playground DSL：构树账错位：数字 \{t2.text}",
                    )
                }
              } else {
                going = false
              }
            None => going = false
          }
        } else {
          going = false
        }
      None => going = false
    }
  }
  if xs.length() != 1 && xs.length() != 4 {
    match self.peek() {
      Some(t) =>
        raise play_err_tok(
          t,
          "\{what} 的值是数字（=all）或四个数字（top,end,bottom,start）（收到 \{xs.length()} 个）",
        )
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：\{what} 的形状不对（收到 \{xs.length()} 个）",
        )
    }
  }
  xs
}

///|
/// children 括号：`[种类调用, ...]`——递归下降的 children 半。
fn PlayParser::parse_children(
  self : PlayParser,
  kind : String,
) -> Array[PlayNode] raise UiError {
  match self.peek() {
    Some(t) =>
      if tok_is_punct(t, "[") {
        self.pos = self.pos + 1
      } else {
        raise play_err_tok(
          t,
          "缺少 `[`（\{kind} 的 children——收到 \{t.text}）",
        )
      }
    None =>
      raise OperationFailed(
        "playground DSL：意外收尾：缺少 `[`（\{kind} 的 children）",
      )
  }
  let kids : Array[PlayNode] = []
  let mut going = true
  while going {
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, "]") {
          self.pos = self.pos + 1
          going = false
        } else {
          kids.push(self.parse_node())
          match self.peek() {
            Some(t2) =>
              if tok_is_punct(t2, ",") {
                self.pos = self.pos + 1
              } else if tok_is_punct(t2, "]") {
                self.pos = self.pos + 1
                going = false
              } else {
                raise play_err_tok(
                  t2,
                  "缺少 `,`（\{kind} 的 children——收到 \{t2.text}）",
                )
              }
            None =>
              raise OperationFailed(
                "playground DSL：意外收尾：缺少 `]`（\{kind} 的 children）",
              )
          }
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少 `]`（\{kind} 的 children）",
        )
    }
  }
  kids
}

///|
/// options 括号：`["a", "b"]`——形状混放显式报错（children 要种类调用，
/// options 要字符串，混放不算空档）。
fn PlayParser::parse_strlist(
  self : PlayParser,
  kind : String,
) -> Array[String] raise UiError {
  match self.peek() {
    Some(t) =>
      if tok_is_punct(t, "[") {
        self.pos = self.pos + 1
      } else {
        raise play_err_tok(
          t,
          "缺少 options `[`（\{kind}——收到 \{t.text}）",
        )
      }
    None =>
      raise OperationFailed(
        "playground DSL：意外收尾：缺少 options `[`（\{kind}）",
      )
  }
  let opts : Array[String] = []
  let mut going = true
  while going {
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, "]") {
          self.pos = self.pos + 1
          going = false
        } else if tok_is_str(t) {
          opts.push(t.text)
          self.pos = self.pos + 1
          match self.peek() {
            Some(t2) =>
              if tok_is_punct(t2, ",") {
                self.pos = self.pos + 1
              } else if tok_is_punct(t2, "]") {
                self.pos = self.pos + 1
                going = false
              } else {
                raise play_err_tok(
                  t2,
                  "缺少 `,`（\{kind} 的 options——收到 \{t2.text}）",
                )
              }
            None =>
              raise OperationFailed(
                "playground DSL：意外收尾：缺少 `]`（\{kind} 的 options）",
              )
          }
        } else {
          raise play_err_tok(
            t,
            "options 数组要字符串（收到 \{t.text}）",
          )
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少 `]`（\{kind} 的 options）",
        )
    }
  }
  opts
}

///|
/// 链名 → 形状档（白名单即文法定稿表的链半——白名单外显式报错）。
fn play_chain_shape(name : String) -> PlayChainShape? {
  match name {
    "font_size"
    | "opacity"
    | "radius"
    | "width"
    | "height"
    | "min_width"
    | "max_width" => Some(CNum)
    "font_weight" => Some(CWeight)
    "foreground" | "background" => Some(CColor)
    "margin" => Some(CInsets)
    _ => None
  }
}

///|
/// 链值形状错的可读账（解析报错与面板校验共用一条措辞——两处同账不漂）。
fn play_chain_shape_body(name : String, text : String) -> String {
  match play_chain_shape(name) {
    Some(CNum) => "\{name} 的值是数字（收到 \{text}）"
    Some(CWeight) => "\{name} 的值是 Regular/Medium/Bold（收到 \{text}）"
    Some(CColor) =>
      "\{name} 的值是 #RRGGBB 颜色字面量（收到 \{text}）"
    Some(CInsets) =>
      "\{name} 的值是数字（=all）或四个数字（top,end,bottom,start）（收到 \{text}）"
    None => "\{name} 不是链（收到 \{text}）"
  }
}

///|
/// 外观链：`.` 链名 `(值)`——值形状按链名钉死。
fn PlayParser::parse_chain(self : PlayParser) -> PlayChain raise UiError {
  let name_tok = match self.peek() {
    Some(t) =>
      if tok_is_ident(t) {
        self.pos = self.pos + 1
        t
      } else {
        raise play_err_tok(t, "缺少链名（收到 \{t.text}）")
      }
    None =>
      raise OperationFailed("playground DSL：意外收尾：缺少链名")
  }
  let name = name_tok.text
  let shape = match play_chain_shape(name) {
    Some(s) => s
    None => raise play_err_tok(name_tok, "链名不存在 \{name}")
  }
  self.expect_punct("(", "缺少 `(`")
  let value : PlayValue = match shape {
    CNum =>
      match self.peek() {
        Some(t) =>
          if tok_is_num(t) {
            self.pos = self.pos + 1
            match play_num_of(t.text) {
              Some(d) => PlayValue::Num(d)
              None =>
                raise OperationFailed(
                  "playground DSL：构树账错位：数字 \{t.text}",
                )
            }
          } else {
            raise play_err_tok(t, play_chain_shape_body(name, t.text))
          }
        None =>
          raise OperationFailed(
            "playground DSL：意外收尾：\{name} 的值是数字",
          )
      }
    CWeight =>
      match self.peek() {
        Some(t) =>
          if tok_is_ident(t) {
            match play_weight_of(t.text) {
              Some(_) => {
                self.pos = self.pos + 1
                PlayValue::Ident(t.text)
              }
              None => raise play_err_tok(t, play_chain_shape_body(name, t.text))
            }
          } else {
            raise play_err_tok(t, play_chain_shape_body(name, t.text))
          }
        None =>
          raise OperationFailed(
            "playground DSL：意外收尾：\{name} 的值是 Regular/Medium/Bold",
          )
      }
    CColor =>
      match self.peek() {
        Some(t) =>
          if tok_is_color(t) {
            self.pos = self.pos + 1
            PlayValue::Color(t.text)
          } else {
            raise play_err_tok(t, play_chain_shape_body(name, t.text))
          }
        None =>
          raise OperationFailed(
            "playground DSL：意外收尾：\{name} 的值是 #RRGGBB 颜色字面量",
          )
      }
    CInsets => PlayValue::NumList(self.parse_numlist(name))
  }
  self.expect_punct(")", "缺少 `)`")
  PlayChain::{ name, value, offset: name_tok.offset, }
}

///|
/// 种类调用：种类名 `(构造参数)`（外观链与 children 在各自位置解析）。
fn PlayParser::parse_node(self : PlayParser) -> PlayNode raise UiError {
  let kind_tok = match self.peek() {
    Some(t) =>
      if tok_is_ident(t) {
        self.pos = self.pos + 1
        t
      } else {
        raise play_err_tok(t, "缺少种类名（收到 \{t.text}）")
      }
    None =>
      raise OperationFailed("playground DSL：意外收尾：缺少种类名")
  }
  let kind = kind_tok.text
  // 种类白名单（文法定稿表的种类半——白名单外显式报错）
  match kind {
    "Row"
    | "Column"
    | "Padding"
    | "Text"
    | "Button"
    | "CheckBox"
    | "Slider"
    | "ProgressBar"
    | "ComboBox"
    | "RadioButtons"
    | "MenuRow" => ()
    _ => raise play_err_tok(kind_tok, "未知种类 \{kind}")
  }
  self.expect_punct("(", "缺少 `(`")
  let params : Array[PlayValue] = []
  let kids : Array[PlayNode] = []
  if kind == "Row" || kind == "Column" {
    params.push(PlayValue::Num(self.expect_num_param("spacing", kind)))
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ")") {
          raise play_err_tok(t, "缺少 children `[`（\{kind}）")
        } else if tok_is_punct(t, ",") {
          self.pos = self.pos + 1
          for k in self.parse_children(kind) {
            kids.push(k)
          }
          self.expect_close(kind)
        } else {
          raise play_err_tok(t, "缺少 `,`（\{kind}——收到 \{t.text}）")
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少 children `[`（\{kind}）",
        )
    }
  } else if kind == "Padding" {
    params.push(PlayValue::NumList(self.parse_numlist("insets")))
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ")") {
          raise play_err_tok(t, "缺少 children `[`（Padding）")
        } else if tok_is_punct(t, ",") {
          self.pos = self.pos + 1
          for k in self.parse_children("Padding") {
            kids.push(k)
          }
          // 单元素钉死（MoonBit 脸 Widget::padding 是单孩子参数）
          if kids.length() != 1 {
            match self.peek() {
              Some(t) =>
                raise play_err_tok(
                  t,
                  "Padding 的 children 钉单元素（MoonBit 脸 Widget::padding 是单孩子参数——收到 \{kids.length()} 个）",
                )
              None =>
                raise OperationFailed(
                  "playground DSL：意外收尾：Padding 的 children 钉单元素",
                )
            }
          }
          self.expect_close("Padding")
        } else {
          raise play_err_tok(t, "缺少 `,`（Padding——收到 \{t.text}）")
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少 children `[`（Padding）",
        )
    }
  } else if kind == "Text" || kind == "Button" {
    params.push(PlayValue::Str(self.expect_str_param("text", kind)))
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ")") {
          self.pos = self.pos + 1
        } else if tok_is_punct(t, ",") {
          raise play_err_tok(
            t,
            "参数过多（\{kind} 只吃 text——收到 \{t.text}）",
          )
        } else {
          raise play_err_tok(t, "缺少 `)`（\{kind}——收到 \{t.text}）")
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少 `)`（\{kind}）",
        )
    }
  } else if kind == "CheckBox" {
    params.push(PlayValue::Str(self.expect_str_param("text", kind)))
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ",") {
          self.pos = self.pos + 1
          params.push(PlayValue::Bool(self.expect_bool_param("checked", kind)))
          match self.peek() {
            Some(t2) =>
              if tok_is_punct(t2, ")") {
                self.pos = self.pos + 1
              } else {
                raise play_err_tok(
                  t2,
                  "参数过多（CheckBox 只吃 text、checked——收到 \{t2.text}）",
                )
              }
            None =>
              raise OperationFailed(
                "playground DSL：意外收尾：缺少 `)`（CheckBox）",
              )
          }
        } else if tok_is_punct(t, ")") {
          raise play_err_tok(t, "缺少参数 checked（CheckBox）")
        } else {
          raise play_err_tok(
            t,
            "缺少 `,`（CheckBox——收到 \{t.text}）",
          )
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少参数 checked（CheckBox）",
        )
    }
  } else if kind == "Slider" {
    params.push(PlayValue::Num(self.expect_range_param("min", kind)))
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ",") {
          self.pos = self.pos + 1
          params.push(PlayValue::Num(self.expect_range_param("max", kind)))
          match self.peek() {
            Some(t2) =>
              if tok_is_punct(t2, ")") {
                self.pos = self.pos + 1
              } else {
                raise play_err_tok(
                  t2,
                  "参数过多（Slider 只吃 min、max——收到 \{t2.text}）",
                )
              }
            None =>
              raise OperationFailed(
                "playground DSL：意外收尾：缺少 `)`（Slider）",
              )
          }
        } else if tok_is_punct(t, ")") {
          raise play_err_tok(t, "缺少参数 max（Slider）")
        } else {
          raise play_err_tok(t, "缺少 `,`（Slider——收到 \{t.text}）")
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少参数 max（Slider）",
        )
    }
  } else if kind == "ProgressBar" {
    // 空括号种类——参数多余由收尾 `)` 的形状错显式点名
    self.expect_close(kind)
  } else if kind == "ComboBox" || kind == "RadioButtons" {
    params.push(PlayValue::StrList(self.parse_strlist(kind)))
    self.expect_close(kind)
  } else if kind == "MenuRow" {
    params.push(PlayValue::Str(self.expect_str_param("text", kind)))
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ",") {
          self.pos = self.pos + 1
          params.push(PlayValue::Bool(self.expect_bool_param("selected", kind)))
          match self.peek() {
            Some(t2) =>
              if tok_is_punct(t2, ")") {
                self.pos = self.pos + 1
              } else {
                raise play_err_tok(
                  t2,
                  "参数过多（MenuRow 只吃 text、selected——收到 \{t2.text}）",
                )
              }
            None =>
              raise OperationFailed(
                "playground DSL：意外收尾：缺少 `)`（MenuRow）",
              )
          }
        } else if tok_is_punct(t, ")") {
          raise play_err_tok(t, "缺少参数 selected（MenuRow）")
        } else {
          raise play_err_tok(t, "缺少 `,`（MenuRow——收到 \{t.text}）")
        }
      None =>
        raise OperationFailed(
          "playground DSL：意外收尾：缺少参数 selected（MenuRow）",
        )
    }
  }
  // 外观链：`.` 链名 `(值)` 循环（重复同名链允许、后链赢）
  let chains : Array[PlayChain] = []
  let mut going = true
  while going {
    match self.peek() {
      Some(t) =>
        if tok_is_punct(t, ".") {
          self.pos = self.pos + 1
          chains.push(self.parse_chain())
        } else {
          going = false
        }
      None => going = false
    }
  }
  let node : PlayNode = {
    kind,
    params,
    children: kids,
    chains,
    offset: kind_tok.offset,
  }
  node
}

///|
fn PlayParser::expect_close(
  self : PlayParser,
  kind : String,
) -> Unit raise UiError {
  match self.peek() {
    Some(t) =>
      if tok_is_punct(t, ")") {
        self.pos = self.pos + 1
      } else {
        raise play_err_tok(t, "缺少 `)`（\{kind}——收到 \{t.text}）")
      }
    None =>
      raise OperationFailed(
        "playground DSL：意外收尾：缺少 `)`（\{kind}）",
      )
  }
}

///|
/// DSL 入口·解析：描述文本 → 解析账。空描述与空白描述显式缺席（§33），
/// 顶层记号多余显式报错——判据在 playground_test.mbt。
pub fn PlayNode::parse(text : String) -> PlayNode raise UiError {
  let toks = play_tokenize(text)
  if toks.length() == 0 {
    raise OperationFailed(
      "playground DSL：空描述（显式缺席——要构树请给一段种类调用）",
    )
  }
  let p = PlayParser::{ toks, pos: 0, }
  let node = p.parse_node()
  match p.peek() {
    Some(t) => raise play_err_tok(t, "多余记号（\{t.text}）")
    None => ()
  }
  node
}

///|
/// 值档 → 文本（描述序列化与面板读回共用一条措辞——两处同账不漂）。
fn play_render_value(v : PlayValue) -> String {
  match v {
    Num(d) => d.to_string()
    Str(s) => play_quote(s)
    Bool(b) => if b { "true" } else { "false" }
    Color(s) => s
    Ident(s) => s
    NumList(xs) =>
      if xs.length() == 1 {
        xs[0].to_string()
      } else {
        let parts : Array[String] = []
        for x in xs {
          parts.push(x.to_string())
        }
        parts.join(",")
      }
    StrList(xs) => {
      let parts : Array[String] = []
      for x in xs {
        parts.push(play_quote(x))
      }
      "[" + parts.join(", ") + "]"
    }
  }
}

///|
/// 字符串 → 带引号文本（转义 `\\` 与 `\"`——与词法的转义表闭合）。
fn play_quote(s : String) -> String {
  let mut out = "\""
  for i = 0; i < s.length(); i = i + 1 {
    let u = unit_at(s, i)
    if u == "\\" {
      out = out + "\\\\"
    } else if u == "\"" {
      out = out + "\\\""
    } else {
      out = out + u
    }
  }
  out + "\""
}

///|
/// DSL 出口·序列化：解析账 → 描述文本。面板档的缝合法靠它——改账后
/// 序列化成新描述（面板改值 = 改描述）。输出闭合于文法：再解析必成账
/// （面板档重建走的就是这条往返）。
pub fn PlayNode::to_dsl(self : PlayNode) -> String {
  let mut text = self.kind + "("
  for i = 0; i < self.params.length(); i = i + 1 {
    if i > 0 {
      text = text + ", "
    }
    text = text + play_render_value(self.params[i])
  }
  if self.children.length() > 0 {
    if self.params.length() > 0 {
      text = text + ", "
    }
    text = text + "["
    for i = 0; i < self.children.length(); i = i + 1 {
      if i > 0 {
        text = text + ", "
      }
      text = text + self.children[i].to_dsl()
    }
    text = text + "]"
  }
  text = text + ")"
  for chain in self.chains {
    text = text + "." + chain.name + "(" + play_render_value(chain.value) + ")"
  }
  text
}

///|
/// 构造参数取值（构树时的账走错显式报错——解析已钉形状，这里是 §33 的 belt）。
fn play_param(
  node : PlayNode,
  i : Int32,
  name : String,
) -> PlayValue raise UiError {
  if i < 0 || i >= node.params.length() {
    raise OperationFailed(
      "playground DSL：构树账错位：\{node.kind} 缺参数 \{name}",
    )
  }
  node.params[i]
}

///|
fn play_param_num(
  node : PlayNode,
  i : Int32,
  name : String,
) -> Double raise UiError {
  match play_param(node, i, name) {
    Num(d) => d
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{node.kind} 的 \{name} 应是数字",
      )
  }
}

///|
fn play_param_int(
  node : PlayNode,
  i : Int32,
  name : String,
) -> Int32 raise UiError {
  play_param_num(node, i, name).to_int()
}

///|
fn play_param_str(
  node : PlayNode,
  i : Int32,
  name : String,
) -> String raise UiError {
  match play_param(node, i, name) {
    Str(s) => s
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{node.kind} 的 \{name} 应是字符串",
      )
  }
}

///|
fn play_param_bool(
  node : PlayNode,
  i : Int32,
  name : String,
) -> Bool raise UiError {
  match play_param(node, i, name) {
    Bool(b) => b
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{node.kind} 的 \{name} 应是 true/false",
      )
  }
}

///|
fn play_param_strs(
  node : PlayNode,
  i : Int32,
  name : String,
) -> Array[String] raise UiError {
  match play_param(node, i, name) {
    StrList(xs) => xs
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{node.kind} 的 \{name} 应是字符串数组",
      )
  }
}

///|
fn play_param_insets(node : PlayNode, i : Int32) -> EdgeInsets raise UiError {
  match play_param(node, i, "insets") {
    NumList(xs) =>
      if xs.length() == 1 {
        EdgeInsets::all(xs[0])
      } else if xs.length() == 4 {
        EdgeInsets::{ top: xs[0], end: xs[1], bottom: xs[2], start: xs[3], }
      } else {
        raise OperationFailed(
          "playground DSL：构树账错位：insets 形状 \{xs.length()}",
        )
      }
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：insets 应是数字形",
      )
  }
}

///|
/// 链值取档（同上一条 belt 注）。
fn play_chain_num(chain : PlayChain) -> Double raise UiError {
  match chain.value {
    Num(d) => d
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{chain.name} 应是数字",
      )
  }
}

///|
fn play_chain_weight(chain : PlayChain) -> FontWeight raise UiError {
  match chain.value {
    Ident(s) =>
      match play_weight_of(s) {
        Some(w) => w
        None =>
          raise OperationFailed(
            "playground DSL：构树账错位：\{chain.name} 应是 Regular/Medium/Bold",
          )
      }
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{chain.name} 应是 Regular/Medium/Bold",
      )
  }
}

///|
fn play_chain_color(chain : PlayChain) -> Color raise UiError {
  match chain.value {
    Color(s) =>
      match play_color_parse(s) {
        Some(c) => c
        None =>
          raise OperationFailed(
            "playground DSL：构树账错位：\{chain.name} 应是 #RRGGBB",
          )
      }
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{chain.name} 应是 #RRGGBB",
      )
  }
}

///|
fn play_chain_insets(chain : PlayChain) -> EdgeInsets raise UiError {
  match chain.value {
    NumList(xs) =>
      if xs.length() == 1 {
        EdgeInsets::all(xs[0])
      } else if xs.length() == 4 {
        EdgeInsets::{ top: xs[0], end: xs[1], bottom: xs[2], start: xs[3], }
      } else {
        raise OperationFailed(
          "playground DSL：构树账错位：\{chain.name} 形状 \{xs.length()}",
        )
      }
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：\{chain.name} 应是数字形",
      )
  }
}

///|
/// 外观链挂上去（与 `T83` 脸的链逐条同账——链存值进局部样式，链的稀疏
/// 合并语义在 declarative.mbt 那半，这里只是逐条调它）。
fn[B] play_apply_chain(w : Widget[B], chain : PlayChain) -> Unit raise UiError {
  match chain.name {
    "font_size" => {
      let _ = w.font_size(play_chain_num(chain))
    }
    "opacity" => {
      let _ = w.opacity(play_chain_num(chain))
    }
    "radius" => {
      let _ = w.radius(play_chain_num(chain))
    }
    "width" => {
      let _ = w.width(play_chain_num(chain))
    }
    "height" => {
      let _ = w.height(play_chain_num(chain))
    }
    "min_width" => {
      let _ = w.min_width(play_chain_num(chain))
    }
    "max_width" => {
      let _ = w.max_width(play_chain_num(chain))
    }
    "font_weight" => {
      let _ = w.font_weight(play_chain_weight(chain))
    }
    "foreground" => {
      let _ = w.foreground(play_chain_color(chain))
    }
    "background" => {
      let _ = w.background(play_chain_color(chain))
    }
    "margin" => {
      let _ = w.margin(play_chain_insets(chain))
    }
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：链 \{chain.name} 不在白名单",
      )
  }
}

///|
/// DSL 出口·构树：解析账 → 真控件树（旧命令式构造族按文法定稿表逐条对表，
/// 外观链随后挂）。children 按声明顺序递归构——句柄序与 MoonBit 脸手构一致，
/// dump 逐行判据靠这条。
pub fn[B : Backend] PlayNode::build(
  b : B,
  node : PlayNode,
) -> Widget[B] raise UiError {
  let kids : Array[Widget[B]] = []
  let needs_kids = node.kind == "Row" ||
    node.kind == "Column" ||
    node.kind == "Padding"
  if needs_kids {
    for k in node.children {
      kids.push(PlayNode::build(b, k))
    }
  }
  let w : Widget[B] = match node.kind {
    "Row" => Widget::row(b, play_param_num(node, 0, "spacing"), kids)
    "Column" => Widget::column(b, play_param_num(node, 0, "spacing"), kids)
    "Padding" => {
      if kids.length() != 1 {
        raise OperationFailed(
          "playground DSL：构树账错位：Padding 的孩子数 \{kids.length()}",
        )
      }
      Widget::padding(b, play_param_insets(node, 0), kids[0])
    }
    "Text" => Widget::label(b, play_param_str(node, 0, "text"))
    "Button" => Widget::button(b, play_param_str(node, 0, "text"))
    "CheckBox" =>
      Widget::checkbox(
        b,
        play_param_str(node, 0, "text"),
        play_param_bool(node, 1, "checked"),
      )
    "Slider" =>
      Widget::slider(
        b,
        play_param_int(node, 0, "min"),
        play_param_int(node, 1, "max"),
      )
    "ProgressBar" => Widget::progress(b)
    "ComboBox" => Widget::combobox(b, play_param_strs(node, 0, "options"))
    "RadioButtons" =>
      Widget::radio_buttons(b, play_param_strs(node, 0, "options"))
    "MenuRow" =>
      Widget::menu_row(
        b,
        play_param_str(node, 0, "text"),
        play_param_bool(node, 1, "selected"),
      )
    _ =>
      raise OperationFailed(
        "playground DSL：构树账错位：未知种类 \{node.kind}",
      )
  }
  for chain in node.chains {
    play_apply_chain(w, chain)
  }
  w
}

///|
/// 有 text 参数的种类（面板 text 行与读回共用）。
fn play_kind_has_text(kind : String) -> Bool {
  kind == "Text" || kind == "Button" || kind == "CheckBox" || kind == "MenuRow"
}

///|
/// 有 Bool 参数的种类（CheckBox 的 checked / MenuRow 的 selected）。
fn play_kind_has_bool(kind : String) -> Bool {
  kind == "CheckBox" || kind == "MenuRow"
}

///|
/// Bool 参数名（面板行标签与读回共用）。
fn play_bool_param_name(kind : String) -> String {
  if kind == "MenuRow" {
    "selected"
  } else {
    "checked"
  }
}

///|
/// 字重字面量 → 选项下标（面板 ComboBox 初选用；白名单外归 0——解析已钉白名单，这条是 belt）。
fn play_weight_index(text : String) -> Int32 {
  if text == "Regular" {
    0
  } else if text == "Medium" {
    1
  } else if text == "Bold" {
    2
  } else {
    0
  }
}

///|
/// 按句柄 id 在子树里找下标路径（命中反查 → 选中账）。
fn[B] play_path_of(root : Widget[B], id : Int32) -> Array[Int32]? raise UiError {
  match root.handle() {
    Some(h) => if h.id == id { return Some([]) }
    None => ()
  }
  let kids = root.children()
  for i = 0; i < kids.length(); i = i + 1 {
    match play_path_of(kids[i], id) {
      Some(p) => {
        let full : Array[Int32] = [i]
        for x in p {
          full.push(x)
        }
        return Some(full)
      }
      None => ()
    }
  }
  None
}

///|
/// 按下标路径取节点（选中账的 AST 半——账走错显式报错）。
fn play_node_at(node : PlayNode, path : Array[Int32]) -> PlayNode raise UiError {
  let mut cur = node
  for i in path {
    let kids = cur.children
    if i < 0 || i >= kids.length() {
      raise OperationFailed(
        "playground DSL：选中账错位：路径越界（\{i}）",
      )
    }
    cur = kids[i]
  }
  cur
}

///|
/// 按下标路径取控件（选中账的树半——账走错显式报错）。
fn[B] play_widget_by_path(
  root : Widget[B],
  path : Array[Int32],
) -> Widget[B]? raise UiError {
  let mut cur = root
  for i in path {
    let kids = cur.children()
    if i < 0 || i >= kids.length() {
      raise OperationFailed(
        "playground DSL：选中账错位：路径越界（\{i}）",
      )
    }
    cur = kids[i]
  }
  Some(cur)
}

///|
/// 节点上按名找链（面板编辑的落点；缺席合法——读回记 None、编辑显式挡下）。
fn play_chain_at(node : PlayNode, name : String) -> PlayChain? {
  for chain in node.chains {
    if chain.name == name {
      return Some(chain)
    }
  }
  None
}

///|
/// 面板改值 → 值档（按链形状核对文本；形状不对显式缺席——挡下不改账）。
fn play_edit_value(name : String, text : String) -> PlayValue? {
  match play_chain_shape(name) {
    Some(CNum) =>
      match play_num_of(text) {
        Some(d) => Some(PlayValue::Num(d))
        None => None
      }
    Some(CWeight) =>
      match play_weight_of(text) {
        Some(_) => Some(PlayValue::Ident(text))
        None => None
      }
    Some(CColor) =>
      match play_color_parse(text) {
        Some(_) => Some(PlayValue::Color(text))
        None => None
      }
    Some(CInsets) =>
      match play_insets_parse(text) {
        Some(xs) => Some(PlayValue::NumList(xs))
        None => None
      }
    None => None
  }
}

///|
/// Playground 的默认描述（双壳共用：无头壳与真窗壳同一份构树描述——
/// 一份描述换后端就是真窗演示，沿 examples 的既有约定）。11 个种类全齐、
/// 11 条外观链里盖 7 条（font_size/font_weight/foreground/background/
/// radius/opacity/margin）；width/height/min_width/max_width 与判据测试用
/// 专属描述补全覆盖（逐位同值判据在 playground_test.mbt 的链半块）。
pub const PLAYGROUND_DEFAULT_DESC : String = "Column(12, [\n  Text(\"Playground\").font_size(18).font_weight(Bold).foreground(#30343C),\n  Row(8, [Button(\"点我\"), CheckBox(\"启用\", true), ComboBox([\"标准\", \"兼容\"]), RadioButtons([\"渠道一\", \"渠道二\"]), MenuRow(\"原生控件\", false)]),\n  Row(8, [Slider(0, 100), ProgressBar()]),\n  Padding(16, [Text(\"内缩区\").background(#F4F5F7).radius(8).opacity(0.9).margin(8)]),\n])"

///|
/// Playground 双档 Demo：左树右面板。
///
/// 左半是描述构出的真控件树（内容树），右半是属性面板（选中→读回→改值→
/// 重建）。窗内容根是 Row 两格 `[内容树, 面板列]`；每次重建整棵内容根
/// 换新（`set_content` 的既有语义负责旧树回收与新树挂接）——面板行的接线
/// 随重建自挂，所以面板控件在真窗上一直是活的；内容树的选中接线不随重建
/// 幸存（重建钩子等真需求，见头注），第一版选中走 `select_at`。
pub struct PlaygroundDemo[B] {
  backend : B
  window : Window[B]
  /// 当下描述（DSL 文本——面板档与 DSL 档的缝合法：面板改值 = 改描述）
  mut description : String
  /// 当下解析账（选中与面板读回的依据；重建时序列化→再解析——往返闭合）
  mut ast : PlayNode
  /// 选中账：None = 未选中；Some(path) = 内容根到选中叶子的下标路径
  mut selected_path : Array[Int32]?
  /// 状态行（面板显式显示——§33 不静默）
  mut status : String
}

///|
/// 双档 Demo 构造：解析描述（解析失败的描述显式报错——窗口都不建，§33）、
/// 开窗、构窗内容根（左树右面板）。换真后端就是真窗演示（判据全在无头壳）。
pub fn[B : Backend] PlaygroundDemo::demo(
  app : App[B],
  description : String,
) -> PlaygroundDemo[B] raise UiError {
  let b = app.backend()
  let ast = PlayNode::parse(description)
  let win = app.create_window("Playground", LogicalSize(900.0, 640.0))
  let demo : PlaygroundDemo[B] = {
    backend: b,
    window: win,
    description,
    ast,
    selected_path: None,
    status: "点击内容区控件以选中",
  }
  win.set_content(demo.build_root())
  win.show()
  demo
}

///|
pub fn[B] PlaygroundDemo::window(self : PlaygroundDemo[B]) -> Window[B] {
  self.window
}

///|
/// 当下描述（判据读口——面板改值后描述变的形状就在这）。
pub fn[B] PlaygroundDemo::description(self : PlaygroundDemo[B]) -> String {
  self.description
}

///|
/// 状态行（判据读口）。
pub fn[B] PlaygroundDemo::status_line(self : PlaygroundDemo[B]) -> String {
  self.status
}

///|
/// 选中账（判据读口）：None = 未选中；Some(种类名) = 选中账的 AST 半。
pub fn[B] PlaygroundDemo::selected_kind(
  self : PlaygroundDemo[B],
) -> String? raise UiError {
  match self.selected_path {
    None => None
    Some(p) => Some(play_node_at(self.ast, p).kind)
  }
}

///|
/// 选中节点的链值读回（判据读口·面板读回账）：链缺席合法记 None。
pub fn[B] PlaygroundDemo::chain_value(
  self : PlaygroundDemo[B],
  name : String,
) -> String? raise UiError {
  match self.selected_path {
    None => None
    Some(p) =>
      match play_chain_at(play_node_at(self.ast, p), name) {
        Some(chain) => Some(play_render_value(chain.value))
        None => None
      }
  }
}

///|
/// 选中控件（判据读口）：按路径从当下窗内容树取——面板改值重建后按这条
/// 判新参数生效（样式账读回）；未选中记 None。
pub fn[B] PlaygroundDemo::selected_widget(
  self : PlaygroundDemo[B],
) -> Widget[B]? raise UiError {
  match self.selected_path {
    None => None
    Some(p) =>
      match self.window.content() {
        None =>
          raise OperationFailed(
            "playground DSL：选中账错位：窗口没有内容树",
          )
        Some(root) => {
          if root.children.length() == 0 {
            raise OperationFailed(
              "playground DSL：选中账错位：内容分支缺席",
            )
          }
          play_widget_by_path(root.children[0], p)
        }
      }
  }
}

///|
/// 面板行读回（判据读口·面板读回账）：选中节点当下的参数账逐行渲染——
/// 与面板显示共用一套账（值档渲染同一条措辞）。
pub fn[B] PlaygroundDemo::panel_rows(
  self : PlaygroundDemo[B],
) -> Array[String] raise UiError {
  let rows : Array[String] = []
  match self.selected_path {
    None => rows.push("未选中（点击内容区控件以选中）")
    Some(p) => {
      let node = play_node_at(self.ast, p)
      rows.push("选中：" + node.kind)
      if play_kind_has_text(node.kind) {
        rows.push("text=" + play_param_str(node, 0, "text"))
      }
      if play_kind_has_bool(node.kind) {
        rows.push(
          play_bool_param_name(node.kind) +
          "=" +
          (if play_param_bool(node, 1, play_bool_param_name(node.kind)) {
            "true"
          } else {
            "false"
          }),
        )
      }
      for chain in node.chains {
        rows.push(chain.name + "=" + play_render_value(chain.value))
      }
      if node.kind == "ComboBox" || node.kind == "RadioButtons" {
        rows.push(
          "options=" + play_render_value(play_param(node, 0, "options")),
        )
      }
      if node.kind == "Slider" {
        rows.push("min=" + play_render_value(play_param(node, 0, "min")))
        rows.push("max=" + play_render_value(play_param(node, 1, "max")))
      }
    }
  }
  rows.push("状态：" + self.status)
  rows
}

///|
/// 窗内容根：Row 两格 `[内容树, 面板列]`（左树右面板）。每次重建整棵换新。
fn[B : Backend] PlaygroundDemo::build_root(
  self : PlaygroundDemo[B],
) -> Widget[B] raise UiError {
  let b = self.backend
  let content = PlayNode::build(b, self.ast)
  let panel = self.build_panel()
  Widget::row(b, 8.0, [content, panel])
}

///|
/// 属性面板：选中节点当下的可改参数（text 行 / Bool 行 / 链行——控件按值
/// 档定档：TextInput 数值与文本、ComboBox 枚举、CheckBox 布尔）加只读参数
/// 读回（options/min/max——编辑等真需求）加状态行。行接线走同一条编辑账
/// （程序路径与用户路径共账），重建自挂。
fn[B : Backend] PlaygroundDemo::build_panel(
  self : PlaygroundDemo[B],
) -> Widget[B] raise UiError {
  let b = self.backend
  let col = Widget::column(b, 6.0, [])
  match self.selected_path {
    None =>
      col.add_child(
        Widget::label(b, "未选中（点击内容区控件以选中）"),
      )
    Some(p) => {
      let node = play_node_at(self.ast, p)
      col.add_child(Widget::label(b, "选中：" + node.kind))
      // text 行（TextInput 文本半）：text 参数编辑
      if play_kind_has_text(node.kind) {
        let row = Widget::row(b, 4.0, [])
        row.add_child(Widget::label(b, "text"))
        let input = Widget::text_input(b, play_param_str(node, 0, "text"))
        row.add_child(input)
        col.add_child(row)
        let _ = input.on_input(fn(s) raise UiError { self.panel_edit_text(s) })
      }
      // Bool 行（CheckBox 真控件）：checked / selected 参数编辑
      if play_kind_has_bool(node.kind) {
        let pname = play_bool_param_name(node.kind)
        let v = play_param_bool(node, 1, pname)
        let row = Widget::row(b, 4.0, [])
        row.add_child(Widget::label(b, pname))
        let pnl_box = Widget::checkbox(b, pname, v)
        row.add_child(pnl_box)
        col.add_child(row)
        let _ = pnl_box.on_change(fn() raise UiError {
          self.panel_edit_checked(pnl_box.checked())
        })
      }
      // 链行：每条链一列（控件按链形状定档），接线同一条编辑账
      for chain in node.chains {
        let row = Widget::row(b, 4.0, [])
        row.add_child(Widget::label(b, chain.name))
        match play_chain_shape(chain.name) {
          Some(CNum) => {
            let input = Widget::text_input(b, play_render_value(chain.value))
            row.add_child(input)
            col.add_child(row)
            let cname = chain.name
            let _ = input.on_input(fn(s) raise UiError {
              self.panel_edit_chain(cname, s)
            })
          }
          Some(CColor) => {
            let input = Widget::text_input(b, play_render_value(chain.value))
            row.add_child(input)
            col.add_child(row)
            let cname = chain.name
            let _ = input.on_input(fn(s) raise UiError {
              self.panel_edit_chain(cname, s)
            })
          }
          Some(CInsets) => {
            let input = Widget::text_input(b, play_render_value(chain.value))
            row.add_child(input)
            col.add_child(row)
            let cname = chain.name
            let _ = input.on_input(fn(s) raise UiError {
              self.panel_edit_chain(cname, s)
            })
          }
          Some(CWeight) => {
            // 枚举链走 ComboBox（真控件）：初选当下的枚举值，换选派同一条编辑账
            let names : Array[String] = ["Regular", "Medium", "Bold"]
            let combo = Widget::combobox(b, names)
            combo.set_selected(
              play_weight_index(play_render_value(chain.value)),
            )
            row.add_child(combo)
            col.add_child(row)
            let cname = chain.name
            let _ = combo.on_change(fn() raise UiError {
              self.panel_edit_chain(cname, names[combo.selected()])
            })
          }
          None =>
            raise OperationFailed(
              "playground DSL：构树账错位：链 \{chain.name} 不在白名单",
            )
        }
      }
      // 只读参数读回（options/min/max 的编辑等真需求——缺席显式）
      if node.kind == "ComboBox" || node.kind == "RadioButtons" {
        col.add_child(
          Widget::label(
            b,
            "options=" + play_render_value(play_param(node, 0, "options")),
          ),
        )
      }
      if node.kind == "Slider" {
        col.add_child(
          Widget::label(
            b,
            "min=" + play_render_value(play_param(node, 0, "min")),
          ),
        )
        col.add_child(
          Widget::label(
            b,
            "max=" + play_render_value(play_param(node, 1, "max")),
          ),
        )
      }
    }
  }
  col.add_child(Widget::label(b, "状态：" + self.status))
  col
}

///|
/// 重建（面板档缝合法的执行半）：AST 序列化成新描述 → 再解析 → 构树 →
/// `set_content` 整棵换。序列化输出闭合于文法，再解析防炸照显式 raise（§33）；
/// `set_content` 负责旧树整棵回收与新树挂接（§8 的既有语义，零手工回收）。
fn[B : Backend] PlaygroundDemo::rebuild(
  self : PlaygroundDemo[B],
) -> Unit raise UiError {
  let text = self.ast.to_dsl()
  let fresh = PlayNode::parse(text)
  self.description = text
  self.ast = fresh
  self.window.set_content(self.build_root())
}

///|
/// 命中反查选中：窗上点一处 → `Window::widget_at`（`T86①` 右键命中反查同族）
/// → 按句柄 id 反查下标路径记选中账 → 面板重建显示该控件当下的可改参数。
/// 未命中显式记状态（选中不变）；面板区域的点击显式点名不进选中账（面板
/// 不是内容树的一部分）。真窗上的内容点击接线等重建钩子（头注记案）。
pub fn[B : Backend] PlaygroundDemo::select_at(
  self : PlaygroundDemo[B],
  p : LogicalPoint,
) -> Unit raise UiError {
  match self.window.widget_at(p) {
    None => {
      self.status = "未命中：点击没有落进内容树控件（选中不变）"
      self.rebuild()
    }
    Some(w) =>
      match self.window.content() {
        None =>
          raise OperationFailed(
            "playground DSL：选中账错位：窗口没有内容树",
          )
        Some(root) => {
          if root.children.length() == 0 {
            raise OperationFailed(
              "playground DSL：选中账错位：内容分支缺席",
            )
          }
          match w.handle() {
            None =>
              raise OperationFailed(
                "playground DSL：选中账错位：命中控件没有句柄",
              )
            Some(h) =>
              match play_path_of(root.children[0], h.id) {
                None => {
                  self.status = "未命中：面板区域点击不进选中账"
                  self.rebuild()
                }
                Some(path) => {
                  let node = play_node_at(self.ast, path)
                  self.selected_path = Some(path)
                  self.status = "已选中 " + node.kind
                  self.rebuild()
                }
              }
          }
        }
      }
  }
}

///|
/// 面板改链值（程序路径；用户路径 on_input / on_change 共此账）：文本按链
/// 形状核对 → 改 AST 链值 → 重建。核对失败显式挡下（描述不变、状态行点名
/// 收到什么——§33 不静默）。链不在选中节点上显式挡下（点名哪条缺席）。
pub fn[B : Backend] PlaygroundDemo::panel_edit_chain(
  self : PlaygroundDemo[B],
  name : String,
  text : String,
) -> Unit raise UiError {
  match self.selected_path {
    None => {
      self.status = "改值未生效：没有选中控件"
      self.rebuild()
    }
    Some(p) => {
      let node = play_node_at(self.ast, p)
      match play_edit_value(name, text) {
        None => {
          self.status = "改值未生效：" + play_chain_shape_body(name, text)
          self.rebuild()
        }
        Some(v) =>
          match play_chain_at(node, name) {
            None => {
              self.status = "改值未生效：" +
                node.kind +
                " 没有链 " +
                name
              self.rebuild()
            }
            Some(chain) => {
              chain.value = v
              self.status = "已改 " + name + "=" + play_render_value(v)
              self.rebuild()
            }
          }
      }
    }
  }
}

///|
/// 面板改 text 参数（程序路径；用户路径 on_input 共此账）。种类没有 text
/// 参数显式挡下。
pub fn[B : Backend] PlaygroundDemo::panel_edit_text(
  self : PlaygroundDemo[B],
  text : String,
) -> Unit raise UiError {
  match self.selected_path {
    None => {
      self.status = "改值未生效：没有选中控件"
      self.rebuild()
    }
    Some(p) => {
      let node = play_node_at(self.ast, p)
      if play_kind_has_text(node.kind) {
        node.params[0] = PlayValue::Str(text)
        self.status = "已改 text=" + text
        self.rebuild()
      } else {
        self.status = "改值未生效：" + node.kind + " 没有 text 参数"
        self.rebuild()
      }
    }
  }
}

///|
/// 面板改 Bool 参数（checked / selected；程序路径；用户路径 on_change 共此
/// 账）。种类没有 Bool 参数显式挡下。
pub fn[B : Backend] PlaygroundDemo::panel_edit_checked(
  self : PlaygroundDemo[B],
  v : Bool,
) -> Unit raise UiError {
  match self.selected_path {
    None => {
      self.status = "改值未生效：没有选中控件"
      self.rebuild()
    }
    Some(p) => {
      let node = play_node_at(self.ast, p)
      if play_kind_has_bool(node.kind) {
        let pname = play_bool_param_name(node.kind)
        node.params[1] = PlayValue::Bool(v)
        self.status = "已改 " +
          pname +
          "=" +
          (if v { "true" } else { "false" })
        self.rebuild()
      } else {
        self.status = "改值未生效：" +
          node.kind +
          " 没有 " +
          play_bool_param_name(node.kind) +
          " 参数"
        self.rebuild()
      }
    }
  }
}
