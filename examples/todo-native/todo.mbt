///|
/// OpenTodo 网页演示（https://demo.open-todo.app/）的**像素级复刻**（`T409`）：
/// 同一份设计 token、同一套演示数据、同一份信息架构，落在 MoonUI 的原生控件上。
///
/// 配色与圆角这类"量出来的数"全部落在 `painter.mbt` 的 `Palette`（从网页的
/// 计算样式换算成 hex），本文件是"数据事实"（任务、项目、标签、侧栏条目、
/// 日期口径），`todo_ui.mbt` 是"摆位与交互"。三块各自的判据都能单独测——
/// 改了配色不该撼动数据，改了数据不该撼动摆位。
///
/// 复刻的口径（与网页逐条对齐，2026-11-26 实测）：
/// - 顶栏 37px（info 浅底 + 底部 1px 边）；侧栏 256px；主卡从 x=256 起、
///   上/右/下各留 8px、圆角 10、1px 边。
/// - 列表行 36/38/46/60 的档位、勾选环 20px + 2px 描边、优先级环的浅底
///   （P1 半透、P2 四分之一透）、悬停才出现的右侧操作簇（白底 + 1px 边 + 圆角 7）。
/// - 提醒 Toast 钉在右下 16px，352px 宽、warning 色 1px 边。

///|
/// 一项任务。字段与网页的 `Task` 对齐到"这一屏画得到"的那些：没有的（评论正文、
/// 附件、参与者）不进模型——画不出来的事实不该占位。
#derive(Eq, Debug)
pub(all) struct Task {
  id : Int32
  title : String
  /// 项目键（`home` / `work` / `launch` / `side`），None = 收件箱里的散任务
  project : String?
  /// 标签键（`errand` / `waiting` / `deep` / `call`）
  labels : Array[String]
  /// 0 = 无优先级，1..<4 = P1..P4
  priority : Int32
  /// 到期日 ISO；None = 无日期
  due : String?
  /// 具体时刻 "09:30"；None = 只到日
  at : String?
  /// 估算分钟数，0 = 未估
  estimate : Int32
  /// 重复标签（"每周一"），None = 不重复
  repeat : String?
  /// 子任务完成数 / 总数（0/0 = 无子任务）
  sub_done : Int32
  sub_total : Int32
  has_notes : Bool
  /// 通过 API 录入的标记（收件箱那两行的 "<> 通过 API 添加 · 2 天前"）
  via_api : Bool
  /// 指派人（`me` / `sam`），行内元信息里画"你"或人名
  assignee : String?
  /// 项目内的分栏键（"Planning" / "In progress" / "Waiting" / "Backlog"…），
  /// 项目视图用它分组；其余视图不读
  section : String?
  /// 评论数（种子给 Get three quotes 造了 3 条）；行尾画 "+ N"
  comments : Int32
  /// 已完成
  done : Bool
}

///|
/// 项目（侧栏"项目"分组与行内的彩色圆点共用）。
#derive(Eq, Debug)
pub(all) struct Project {
  key : String
  name : String
  color : Int32
  count : Int32
  shared : Bool
}

///|
/// 标签（行内 chip 的色号）。
#derive(Eq, Debug)
pub(all) struct Label {
  key : String
  name : String
  color : Int32
}

///|
/// 侧栏一条可点的条目。`count` 为 None 时不画右对齐的数字。
#derive(Eq, Debug)
pub(all) struct Dest {
  key : String
  name : String
  count : Int32?
  /// 图标种类（见 `todo_ui` 的 `icon_of`）
  icon : String
  /// 项目 / 视图 / 标签的色点
  dot : Int32?
  /// 共享项目的那行小字
  note : String?
  /// 是否选中
  selected : Bool
  /// 弱化（子项目 / 折叠态，网页把 Work 画成浅一行 + 前置折叠 chevron）
  dim : Bool
}

///|
/// 一组任务（分组头 + 若干行）。
pub(all) struct Section {
  /// 分组名（"较早" / "今天" / "明天"）；空串 = 不画分组头
  title : String
  count : Int32
  tasks : Array[Task]
  /// 数据版本号：键控列表的键里带上它，任务表一变就整组重建
  /// （`done` 的切换不改这个号——那一档是行内自绘面 `repaint` 的事）。
  rev : Int32
}

///|
/// 主卡头部：标题档位、副信息、简报两段。
pub(all) struct Head {
  /// "今天" 用大字号，其余用小标题
  big : Bool
  title : String
  meta : String
  /// 简报的第一段（加粗引导 + 可点的逾期提示）
  brief_lead : String
  brief_danger : String
  /// 逾期提示后面接着的同行尾巴（"，今天安排了 9h 的工作…"，warning 色）
  brief_rest : String
  /// 第一行最末的尾巴（"和Sam"，muted 色；网页在这一行自然换行，Sam 留在行尾）
  brief_mid : String
  /// 简报的第二段（谁回复了什么，muted 色）
  brief_tail : String?
  /// 是否显示右侧的"整理"主按钮（收件箱有，今天没有）
  tidy : Bool
}

///|
/// 演示的"今天"。
///
/// 为什么写死：演示数据是**相对**今天排的（`due: "-1"` = 昨天），网页每次打开都
/// 重排。复刻件要把同一屏固定下来才可能逐像素比对，所以钉在实测那天。改这里
/// 就是换一天，日期文案与逾期口径全部随之变。
///
/// 口径（2026-11-27 对网页实测）：网页沙盒在 11-26 种下（种子的"今天" = 11-26），
/// 我 11-27 打开时它的"今天" = 11-27，于是种子 `due:"0"` 的任务落到 11-26（在
/// 今天的视图里算逾期/较早），`due:"1"` 落到 11-27（算今天）。复刻件把这两个
/// 基准都钉死：`DEMO_TODAY` 是**展示**的今天，`SEED_TODAY` 是种子基准。
pub const DEMO_TODAY : String = "2026-11-27"

///|
pub const SEED_TODAY : String = "2026-11-26"

///|
/// 种子日期：`seed.go` 的 `due:"<n>"`（n 天相对种子今天）→ 绝对 ISO。
pub fn seed_date(offset : Int32) -> String {
  add_days(SEED_TODAY, offset)
}

///|
/// ISO 日期 + 天数 → ISO。形态不对原样返回。
pub fn add_days(iso : String, days : Int32) -> String {
  if iso.length() < 10 {
    return iso
  }
  let y = digits(iso, 0, 4)
  let m = digits(iso, 5, 2)
  let d = digits(iso, 8, 2)
  if m < 1 || m > 12 || d < 1 || d > 31 {
    return iso
  }
  let (y2, m2, d2) = civil_from(civil_days(y, m, d) + days)
  let mm = pad2(m2)
  let dd = pad2(d2)
  y2.to_string() + "-" + mm + "-" + dd
}

///|
fn digits(iso : String, from : Int32, n : Int32) -> Int32 {
  let b = @utf8.encode(iso)
  let mut v = 0
  for i = from; i < from + n && i < b.length(); i = i + 1 {
    let c = b[i].to_int()
    if c < 48 || c > 57 {
      return 0
    }
    v = v * 10 + (c - 48)
  }
  v
}

///|
fn pad2(v : Int32) -> String {
  let s = v.to_string()
  if v < 10 {
    "0" + s
  } else {
    s
  }
}

///|
/// 儒略日数换算（Howard Hinnant 的 `civil_from_days`）。
fn civil_days(y : Int32, m : Int32, d : Int32) -> Int32 {
  let yy = if m <= 2 { y - 1 } else { y }
  let era = yy / 400
  let yd = yy - era * 400
  let mp = if m > 2 { m - 3 } else { m + 9 }
  let doy = (153 * mp + 2) / 5 + d - 1
  era * 146097 + yd * 365 + yd / 4 - yd / 100 + doy - 719468
}

///|
fn civil_from(z0 : Int32) -> (Int32, Int32, Int32) {
  let z = z0 + 719468
  let era = z / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  let yy = if m <= 2 { y + 1 } else { y }
  (yy, m, d)
}

///|
/// 中文短日期："2026-11-24" → "11月24日"。
pub fn short_date(iso : String) -> String {
  if iso.length() < 10 {
    return iso
  }
  digits(iso, 5, 2).to_string() + "月" + digits(iso, 8, 2).to_string() + "日"
}

///|
/// 星期几（中文）：ISO → "星期四"。
pub fn weekday(iso : String) -> String {
  let names = [
    "星期一", "星期二", "星期三", "星期四", "星期五", "星期六",
    "星期日",
  ]
  names[(
    civil_days(digits(iso, 0, 4), digits(iso, 5, 2), digits(iso, 8, 2)) % 7 + 10
  ) %
  7]
}

///|
/// 与今天相差几天（正 = 之后）。
pub fn day_diff(iso : String) -> Int32 {
  let a = civil_days(digits(iso, 0, 4), digits(iso, 5, 2), digits(iso, 8, 2))
  let b = civil_days(
    digits(DEMO_TODAY, 0, 4),
    digits(DEMO_TODAY, 5, 2),
    digits(DEMO_TODAY, 8, 2),
  )
  a - b
}

///|
/// 行内日期的配色口径（网页 `ladderTone`）：逾期红、今天强调、其余弱化。
pub fn due_tone(iso : String, p : Palette) -> Int32 {
  let d = day_diff(iso)
  if d < 0 {
    p.danger
  } else if d == 0 {
    p.accent
  } else if d == 1 {
    p.strong
  } else {
    p.muted
  }
}

///|
/// 行内日期的文案：今天 / 明天 / 后天 用相对词，其余用短日期。
pub fn due_text(iso : String) -> String {
  let d = day_diff(iso)
  if d == 0 {
    "今天"
  } else if d == 1 {
    "明天"
  } else if d == 2 {
    "后天"
  } else {
    short_date(iso)
  }
}

///|
/// 估算文案：分钟 → "45m" / "1h" / "1h 30m"。
pub fn estimate_text(mins : Int32) -> String {
  if mins <= 0 {
    return ""
  }
  let h = mins / 60
  let m = mins % 60
  if h == 0 {
    m.to_string() + "m"
  } else if m == 0 {
    h.to_string() + "h"
  } else {
    h.to_string() + "h " + m.to_string() + "m"
  }
}

///|
pub let projects : Array[Project] = [
  Project::{
    key: "home",
    name: "Home renovation",
    color: 0xF59E0B,
    count: 9,
    shared: true,
  },
  Project::{
    key: "work",
    name: "Work",
    color: 0x38BDF8,
    count: 13,
    shared: false,
  },
  Project::{
    key: "launch",
    name: "Q4 launch",
    color: 0x0EA5E9,
    count: 8,
    shared: false,
  },
  Project::{
    key: "side",
    name: "Side project",
    color: 0xA78BFA,
    count: 4,
    shared: false,
  },
]

///|
pub let labels : Array[Label] = [
  Label::{ key: "errand", name: "errand", color: 0xF59E0B, },
  Label::{ key: "waiting", name: "waiting", color: 0x64748B, },
  Label::{ key: "deep", name: "deep-work", color: 0x8B5CF6, },
  Label::{ key: "call", name: "call", color: 0x0EA5E9, },
]

///|
pub fn project_of(key : String?) -> Project? {
  match key {
    Some(k) => {
      let mut out : Project? = None
      for p in projects {
        if p.key == k {
          out = Some(p)
        }
      }
      out
    }
    None => None
  }
}

///|
pub fn label_of(key : String) -> Label? {
  for l in labels {
    if l.key == key {
      return Some(l)
    }
  }
  None
}

///|
/// 建任务的紧凑写法：种子 39 条里九成字段取默认，只有差异才写。优先级口径与
/// 网页一致（1=高 / 2=中 / 3=低 / 4=无，`seed.go` 的 0 映射到 4）。
fn mk(
  id : Int32,
  title : String,
  priority~ : Int32 = 4,
  due~ : String = "",
  at~ : String = "",
  project~ : String = "",
  labels~ : Array[String] = [],
  estimate~ : Int32 = 0,
  repeat~ : String = "",
  done~ : Bool = false,
  sub_done~ : Int32 = 0,
  sub_total~ : Int32 = 0,
  has_notes~ : Bool = false,
  via_api~ : Bool = false,
  assignee~ : String = "",
  section~ : String = "",
  comments~ : Int32 = 0,
) -> Task {
  Task::{
    id,
    title,
    project: if project == "" {
      None
    } else {
      Some(project)
    },
    labels,
    priority,
    due: if due == "" {
      None
    } else {
      Some(due)
    },
    at: if at == "" {
      None
    } else {
      Some(at)
    },
    estimate,
    repeat: if repeat == "" {
      None
    } else {
      Some(repeat)
    },
    sub_done,
    sub_total,
    has_notes,
    via_api,
    assignee: if assignee == "" {
      None
    } else {
      Some(assignee)
    },
    section: if section == "" {
      None
    } else {
      Some(section)
    },
    comments,
    done,
  }
}

///|
/// 演示任务表（与 `internal/demo/seed.go` 同一份种子，日期按种子基准展开）。
/// 顺序按种子原文（收件箱 / Home renovation / Work / Q4 launch / Side project），
/// 视图分组在 `sections_for` 里做——这里只存事实。已删除的（Old shopping list /
/// Call Northside (duplicate) / Garage sale 两条）不入表。
pub let demo_tasks : Array[Task] = [
  // —— 收件箱 / 个人（无项目）
  mk(1, "Renew passport", priority=1, due=seed_date(-2), labels=["errand"]),
  mk(
    2,
    "Email the landlord about the heating",
    labels=["waiting"],
    via_api=true,
  ),
  mk(3, "Set up backups for the NAS", priority=3, via_api=true),
  mk(4, "Pick up groceries", due=seed_date(0), at="18:00", estimate=30, labels=[
    "errand",
  ]),
  mk(5, "Water the plants", due=seed_date(0), repeat="每 3 天"),
  mk(6, "Pay rent", priority=2, due=seed_date(3), repeat="每月 1 号"),
  mk(7, "Book dentist appointment", priority=3, due=seed_date(4), labels=[
    "call",
  ]),
  mk(8, "Buy a birthday present for Sam", done=true),
  mk(
    9,
    "Run club",
    due=seed_date(-1),
    at="18:00",
    estimate=60,
    repeat="每周一",
  ),
  // —— Home renovation（与沙盒协作者共享）
  mk(
    11,
    "Get three quotes for the kitchen",
    priority=1,
    due=seed_date(0),
    at="10:00",
    estimate=60,
    project="home",
    section="In progress",
    labels=["call"],
    has_notes=true,
    sub_done=1,
    sub_total=3,
    comments=3,
  ),
  mk(
    12,
    "Call Northside Kitchens",
    project="home",
    section="In progress",
    done=true,
  ),
  mk(
    13,
    "Email Brightwood for a site visit",
    project="home",
    section="In progress",
  ),
  mk(14, "Compare payment schedules", project="home", section="In progress"),
  mk(
    15,
    "Pick paint colours",
    priority=2,
    due=seed_date(1),
    project="home",
    section="Planning",
    assignee="me",
  ),
  mk(
    16,
    "Measure the hallway",
    due=seed_date(1),
    at="08:30",
    estimate=15,
    project="home",
    section="Planning",
  ),
  mk(
    17,
    "Order new taps",
    priority=2,
    project="home",
    section="Planning",
    labels=["errand"],
    assignee="sam",
  ),
  mk(
    18,
    "Call the plumber about the leak",
    priority=2,
    due=seed_date(-1),
    at="09:30",
    project="home",
    section="Waiting",
    labels=["call", "waiting"],
  ),
  mk(
    19,
    "Electrician sign-off",
    due=seed_date(5),
    project="home",
    section="Waiting",
    labels=["waiting"],
  ),
  mk(
    20,
    "Remove old wallpaper",
    project="home",
    section="In progress",
    done=true,
  ),
  mk(
    21,
    "Kitchen site visit (Brightwood)",
    due=seed_date(2),
    at="10:00",
    estimate=60,
    project="home",
    section="Planning",
  ),
  // —— Work
  mk(
    23,
    "Review pull request #42",
    priority=2,
    due=seed_date(0),
    at="11:00",
    estimate=45,
    project="work",
    labels=["deep"],
    has_notes=true,
  ),
  mk(
    24,
    "Write release notes for v1.0",
    priority=3,
    due=seed_date(0),
    at="14:00",
    estimate=90,
    project="work",
    labels=["deep"],
  ),
  mk(
    25,
    "1:1 with Chen",
    due=seed_date(0),
    at="16:00",
    estimate=30,
    project="work",
    repeat="每周",
  ),
  mk(26, "Submit expense report", project="work", done=true),
  mk(
    27,
    "Plan the team offsite",
    priority=2,
    due=seed_date(2),
    at="09:00",
    estimate=120,
    project="work",
  ),
  mk(
    28,
    "Draft the conference talk",
    priority=1,
    due=seed_date(1),
    at="13:00",
    estimate=120,
    project="work",
    labels=["deep"],
    has_notes=true,
  ),
  mk(
    29,
    "Prepare demo for the board",
    priority=2,
    due=seed_date(-1),
    at="14:00",
    estimate=90,
    project="work",
    done=true,
  ),
  // —— Q4 launch（Work 的子项目）
  mk(30, "Pricing page copy", priority=3, project="launch", section="Backlog"),
  mk(31, "Customer interviews summary", project="launch", section="Backlog"),
  mk(32, "Migration guide", project="launch", section="Backlog", labels=["deep"]),
  mk(
    33,
    "Landing page hero",
    priority=1,
    due=seed_date(1),
    project="launch",
    section="This week",
  ),
  mk(
    34,
    "Launch email sequence",
    priority=3,
    due=seed_date(1),
    project="launch",
    section="This week",
    estimate=90,
    has_notes=true,
  ),
  mk(35, "Press kit", due=seed_date(3), project="launch", section="This week"),
  mk(
    36,
    "Status page",
    priority=2,
    due=seed_date(0),
    project="launch",
    section="Review",
  ),
  mk(37, "Analytics dashboard", project="launch", section="Review"),
  // —— Side project
  mk(
    38,
    "Sketch the landing page",
    priority=2,
    due=seed_date(2),
    project="side",
  ),
  mk(39, "Plan the weekend hike", due=seed_date(6), project="side"),
  mk(40, "Read the sync protocol doc", project="side", labels=["deep"]),
  mk(41, "Write the README", project="side"),
]

///|
/// 一组任务（计数只算未完成的——网页侧栏与分组头的数字都是"还开着多少"）。
fn sec(title : String, tasks : Array[Task], rev : Int32) -> Section {
  let mut n = 0
  for t in tasks {
    if !t.done {
      n = n + 1
    }
  }
  Section::{ title, count: n, tasks, rev, }
}

///|
/// 开着的（未完成、未删除）任务数。
fn open_count(list : Array[Task]) -> Int32 {
  let mut n = 0
  for t in list {
    if !t.done {
      n = n + 1
    }
  }
  n
}

///|
/// 收件箱：无项目、无日期、未完成。
fn inbox_tasks(all : Array[Task]) -> Array[Task] {
  let out : Array[Task] = []
  for t in all {
    if t.project is None && t.due is None && !t.done {
      out.push(t)
    }
  }
  out
}

///|
/// 逾期（到期日早于"今天"）且未完成。
fn overdue_tasks(all : Array[Task]) -> Array[Task] {
  let out : Array[Task] = []
  for t in all {
    match t.due {
      Some(d) => if day_diff(d) < 0 && !t.done { out.push(t) }
      None => ()
    }
  }
  out
}

///|
/// 今天到期（== DEMO_TODAY）且未完成。
fn today_tasks(all : Array[Task]) -> Array[Task] {
  let out : Array[Task] = []
  for t in all {
    match t.due {
      Some(d) => if day_diff(d) == 0 && !t.done { out.push(t) }
      None => ()
    }
  }
  out
}

///|
/// 未来第 `days` 天到期且未完成。
fn due_on(all : Array[Task], days : Int32) -> Array[Task] {
  let out : Array[Task] = []
  for t in all {
    match t.due {
      Some(d) => {
        let dd = day_diff(d)
        if dd == days && !t.done {
          out.push(t)
        }
      }
      None => ()
    }
  }
  out
}

///|
/// 未来 `lo`..=`hi` 天内到期且未完成。
fn due_in(all : Array[Task], lo : Int32, hi : Int32) -> Array[Task] {
  let out : Array[Task] = []
  for t in all {
    match t.due {
      Some(d) => {
        let dd = day_diff(d)
        if dd >= lo && dd <= hi && !t.done {
          out.push(t)
        }
      }
      None => ()
    }
  }
  out
}

///|
fn by_label(all : Array[Task], key : String) -> Array[Task] {
  let out : Array[Task] = []
  for t in all {
    if !t.done {
      for l in t.labels {
        if l == key {
          out.push(t)
        }
      }
    }
  }
  out
}

///|
fn by_project(all : Array[Task], key : String) -> Array[Task] {
  let out : Array[Task] = []
  for t in all {
    match t.project {
      Some(p) => if p == key && !t.done { out.push(t) }
      None => ()
    }
  }
  out
}

///|
/// 行内排序键的时刻分量（"HH:MM" → 分钟；无时刻 = 大数，排在有时刻的后面）。
fn time_key(t : Task) -> Int32 {
  match t.at {
    Some(s) => {
      let hh = digits(s, 0, 2)
      let mm = digits(s, 3, 2)
      hh * 60 + mm
    }
    None => 100000
  }
}

///|
/// 行排序键的到期日分量（无到期日 = 大数，排最后）。
fn due_key(t : Task) -> Int32 {
  match t.due {
    Some(d) => day_diff(d)
    None => 100000
  }
}

///|
/// 行排序：先到期日（早的在前），同日内的有时刻的按时刻升序在前，无时刻的按
/// 优先级（1 高 → 4 低）升序在后。插入排序（行数少，不必上 `sort`）。
fn sort_rows(list : Array[Task]) -> Array[Task] {
  let out : Array[Task] = []
  for t in list {
    let dk = due_key(t)
    let tk = time_key(t)
    let pk = t.priority
    // 找插入点：第一个排在 `t` 后面的位置
    let mut pos = out.length()
    let mut i = 0
    while i < out.length() {
      let ot = out[i]
      let t_before_ot = dk < due_key(ot) ||
        (
          dk == due_key(ot) &&
          (tk < time_key(ot) || (tk == time_key(ot) && pk < ot.priority))
        )
      if t_before_ot {
        pos = i
        break
      }
      i = i + 1
    }
    if pos == out.length() {
      out.push(t)
    } else {
      // 尾部补一格，把 [pos..] 整体右移，再落位
      out.push(out[out.length() - 1])
      let mut j = out.length() - 1
      while j > pos {
        out[j] = out[j - 1]
        j = j - 1
      }
      out[pos] = t
    }
  }
  out
}

///|
/// 项目视图按分栏分组（Planning / In progress / Waiting…），空组不画。
fn by_sections(
  all : Array[Task],
  project : String,
  names : Array[String],
  rev : Int32,
) -> Array[Section] {
  let out : Array[Section] = []
  for name in names {
    let grp : Array[Task] = []
    for t in all {
      match t.project {
        Some(p) =>
          if p == project && t.section == Some(name) && !t.done {
            grp.push(t)
          }
        None => ()
      }
    }
    if grp.length() > 0 {
      out.push(sec(name, sort_rows(grp), rev))
    }
  }
  out
}

///|
/// Work 视图：Work 自己的任务 + 子项目 Q4 launch 的任务。
fn work_sections(all : Array[Task], rev : Int32) -> Array[Section] {
  let grp : Array[Task] = []
  for t in all {
    if !t.done {
      match t.project {
        Some(p) => if p == "work" || p == "launch" { grp.push(t) }
        None => ()
      }
    }
  }
  [sec("", sort_rows(grp), rev)]
}

///|
/// 按侧栏条目筛出这一屏的分组。
pub fn sections_for(
  dest : String,
  all : Array[Task],
  rev : Int32,
) -> Array[Section] {
  let out : Array[Section] = []
  match dest {
    "today" => {
      out.push(sec("较早", sort_rows(overdue_tasks(all)), rev))
      out.push(sec("今天", sort_rows(today_tasks(all)), rev))
    }
    "inbox" => out.push(sec("", sort_rows(inbox_tasks(all)), rev))
    "upcoming" => {
      out.push(sec("明天", sort_rows(due_on(all, 1)), rev))
      out.push(sec("下周", sort_rows(due_in(all, 2, 7)), rev))
      out.push(sec("之后", sort_rows(due_in(all, 8, 366)), rev))
    }
    "fav-deep" => out.push(sec("", sort_rows(by_label(all, "deep")), rev))
    "fav-waiting" => out.push(sec("", sort_rows(by_label(all, "waiting")), rev))
    "fav-weekly" =>
      // 周报仪表盘：本期先不给分组（空屏）
      ()
    "proj-home" => {
      let s = by_sections(
        all,
        "home",
        ["Planning", "In progress", "Waiting"],
        rev,
      )
      for x in s {
        out.push(x)
      }
    }
    "proj-work" => {
      let s = work_sections(all, rev)
      for x in s {
        out.push(x)
      }
    }
    "proj-launch" => {
      let s = by_sections(
        all,
        "launch",
        ["Backlog", "This week", "Review"],
        rev,
      )
      for x in s {
        out.push(x)
      }
    }
    "proj-side" => out.push(sec("", sort_rows(by_project(all, "side")), rev))
    _ => ()
  }
  out
}

///|
/// "今天"那一屏的计划分钟数（开着的全部估算和——网页"计划 9h"）。
fn plan_minutes(all : Array[Task]) -> Int32 {
  let mut n = 0
  for t in all {
    if !t.done {
      match t.due {
        Some(d) => if day_diff(d) <= 0 { n = n + t.estimate }
        None => ()
      }
    }
  }
  n
}

///|
/// 这一屏的头部文案。
pub fn head_for(dest : String, all : Array[Task]) -> Head {
  let plan = plan_minutes(all)
  let plan_text = estimate_text(plan)
  let overdue_n = open_count(overdue_tasks(all))
  let open_inbox = open_count(inbox_tasks(all))
  let open_deep = open_count(by_label(all, "deep"))
  let open_waiting = open_count(by_label(all, "waiting"))
  let open_home = open_count(by_project(all, "home"))
  let open_work = work_open(all)
  let open_side = open_count(by_project(all, "side"))
  match dest {
    "today" =>
      Head::{
        big: true,
        title: "今天",
        meta: "\{short_date(DEMO_TODAY)}\{weekday(DEMO_TODAY)} · 计划 \{plan_text} · 已计时 0m",
        brief_lead: "今天有 3 件事最重要。",
        brief_danger: "\{overdue_n} 项任务已逾期",
        brief_rest: "、今天安排了 \{plan_text} 的工作，超出了你每日 8h 的时长",
        brief_mid: "和Sam",
        brief_tail: Some(
          "Rivera 回复了关于 Get three quotes for the kitchen 的问题。",
        ),
        tidy: false,
      }
    "inbox" =>
      Head::{
        big: false,
        title: "收件箱",
        meta: "\{open_inbox} 项待整理",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: true,
      }
    "upcoming" =>
      Head::{
        big: false,
        title: "即将到来",
        meta: "\{open_count(due_in(all, 1, 7))} 项在未来 7 天",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    "fav-deep" =>
      Head::{
        big: false,
        title: "Deep work",
        meta: "\{open_deep} 项未完成",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    "fav-waiting" =>
      Head::{
        big: false,
        title: "Waiting on others",
        meta: "\{open_waiting} 项未完成",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    "fav-weekly" =>
      Head::{
        big: false,
        title: "Weekly review",
        meta: "本周回顾",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    "proj-home" =>
      Head::{
        big: false,
        title: "Home renovation",
        meta: "\{open_home} 项未完成",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    "proj-work" =>
      Head::{
        big: false,
        title: "Work",
        meta: "\{open_work} 项未完成",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    "proj-launch" =>
      Head::{
        big: false,
        title: "Q4 launch",
        meta: "\{open_count(by_project(all, "launch"))} 项未完成",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    "proj-side" =>
      Head::{
        big: false,
        title: "Side project",
        meta: "\{open_side} 项未完成",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
    _ =>
      Head::{
        big: false,
        title: "今天",
        meta: "",
        brief_lead: "",
        brief_danger: "",
        brief_rest: "",
        brief_mid: "",
        brief_tail: None,
        tidy: false,
      }
  }
}

///|
fn work_open(all : Array[Task]) -> Int32 {
  let mut n = 0
  for t in all {
    if !t.done {
      match t.project {
        Some(p) => if p == "work" || p == "launch" { n = n + 1 }
        None => ()
      }
    }
  }
  n
}

///|
/// 侧栏的全部条目（顺序即读序：主导航 → 收藏夹 → 项目）。
pub fn destinations(current : String, all : Array[Task]) -> Array[Dest] {
  let sel = fn(key : String) -> Bool { key == current }
  let n_inbox = open_count(inbox_tasks(all))
  let n_today = open_count(overdue_tasks(all)) + open_count(today_tasks(all))
  let n_home = open_count(by_project(all, "home"))
  let n_work = work_open(all)
  let n_side = open_count(by_project(all, "side"))
  [
    Dest::{
      key: "inbox",
      name: "收件箱",
      count: Some(n_inbox),
      icon: "inbox",
      dot: None,
      note: None,
      selected: sel("inbox"),
      dim: false,
    },
    Dest::{
      key: "today",
      name: "今天",
      count: Some(n_today),
      icon: "today",
      dot: None,
      note: None,
      selected: sel("today"),
      dim: false,
    },
    Dest::{
      key: "upcoming",
      name: "即将到来",
      count: None,
      icon: "upcoming",
      dot: None,
      note: None,
      selected: sel("upcoming"),
      dim: false,
    },
    Dest::{
      key: "calendar",
      name: "日历",
      count: None,
      icon: "calendar",
      dot: None,
      note: None,
      selected: sel("calendar"),
      dim: false,
    },
    Dest::{
      key: "fav-deep",
      name: "Deep work",
      count: None,
      icon: "list",
      dot: Some(0x8B5CF6),
      note: None,
      selected: sel("fav-deep"),
      dim: false,
    },
    Dest::{
      key: "fav-waiting",
      name: "Waiting on others",
      count: None,
      icon: "list",
      dot: Some(0x64748B),
      note: None,
      selected: sel("fav-waiting"),
      dim: false,
    },
    Dest::{
      key: "fav-weekly",
      name: "Weekly review",
      count: None,
      icon: "bars",
      dot: Some(0x10B981),
      note: None,
      selected: sel("fav-weekly"),
      dim: false,
    },
    Dest::{
      key: "proj-home",
      name: "Home renovation",
      count: Some(n_home),
      icon: "project",
      dot: Some(0xF59E0B),
      note: Some("共享项目"),
      selected: sel("proj-home"),
      dim: false,
    },
    Dest::{
      key: "proj-work",
      name: "Work",
      count: Some(n_work),
      icon: "project",
      dot: Some(0x38BDF8),
      note: None,
      selected: sel("proj-work"),
      dim: true,
    },
    Dest::{
      key: "proj-side",
      name: "Side project",
      count: Some(n_side),
      icon: "project",
      dot: Some(0xA78BFA),
      note: None,
      selected: sel("proj-side"),
      dim: false,
    },
  ]
}

///|
/// 侧栏分组的标题行（名称 + 条目数 + "全部" 小按钮）。
pub(all) struct SideGroup {
  name : String
  count : Int32
  /// 该组的条目在 `destinations` 返回数组里的下标（升序）
  rows : Array[Int32]
  /// 组头右侧的"全部"链接文案（收藏夹没有，项目/标签/视图有）
  link : String?
}

///|
pub fn side_groups() -> Array[SideGroup] {
  [
    SideGroup::{ name: "收藏夹", count: 0, rows: [4, 5, 6], link: None, },
    SideGroup::{ name: "项目", count: 4, rows: [7, 8], link: Some("全部"), },
    SideGroup::{ name: "标签", count: 4, rows: [], link: Some("全部"), },
    SideGroup::{ name: "视图", count: 4, rows: [], link: Some("全部"), },
  ]
}
