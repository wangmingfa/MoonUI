///|
/// §49 五个 Demo 的共用打印（`examples/*` 各是可执行包）。
///
/// 这些包只允许用公开 API：读不到 Core 的私有字段，所以布局只能沿内容树往下走，
/// 无障碍只能读 §32 推导出来的视图。哪一天公开 API 不够用了，就是 API 该补的信号，
/// 而不是在这里开后门。
///
/// 文案在 `App::run` 之后读不到——循环收尾会 `terminate` 后端并回收句柄（§11），
/// 所以只打印 Core 侧仍持有的事实。

///|
/// mock 后端 + 真实事件循环：接上 libui-ng 之后唯一要换的就是这一处。
pub fn new_app() -> @moonui.App[@moonui.MockBackend] raise @moonui.UiError {
  let b = @moonui.MockBackend::new()
  b.init()
  @moonui.App::new(b)
}

///|
pub fn rect_text(r : @moonui.LogicalRect) -> String {
  "x=" +
  r.origin.x.to_string() +
  " y=" +
  r.origin.y.to_string() +
  " w=" +
  r.size.width.to_string() +
  " h=" +
  r.size.height.to_string()
}

///|
pub fn role_text(r : @moonui.AccessRole) -> String {
  match r {
    @moonui.Text => "文本"
    @moonui.Button => "按钮"
    @moonui.CheckBox => "勾选框"
    @moonui.TextBox => "输入框"
    @moonui.Group => "分组"
    @moonui.List => "列表"
    @moonui.ListItem => "条目"
    @moonui.Window => "窗口"
  }
}

///|
pub fn action_text(act : @moonui.AccessAction) -> String {
  match act {
    @moonui.Press => "按下"
    @moonui.Toggle => "切换"
    @moonui.SetValue => "改值"
  }
}

///|
/// 用第一个元素决定要不要加分隔符，避免拼接出开头的空格。
pub fn join(parts : Array[String], sep : String) -> String {
  let mut out = ""
  for p in parts {
    out = out + (if out == "" { "" } else { sep }) + p
  }
  out
}

///|
/// 一个节点的打印形态：角色 + 朗读名称 + 可执行动作 + 勾选态 + 禁用标记。
/// 打印是给人读的，宁可多打一个字，也不要把"读屏器会念什么"猜一遍。
pub fn node_text(a : @moonui.Accessibility) -> String {
  let parts : Array[String] = [role_text(a.role) + "「" + a.label + "」"]
  if a.actions.length() > 0 {
    parts.push("[" + join(a.actions.map(x => action_text(x)), "/") + "]")
  }
  match a.state.checked {
    None => ()
    Some(v) => parts.push(if v { "已勾" } else { "未勾" })
  }
  if !a.state.enabled {
    parts.push("禁用")
  }
  join(parts, " ")
}

///|
pub fn nodes_text(nodes : Array[@moonui.Accessibility]) -> String {
  join(nodes.map(n => node_text(n)), " ｜ ")
}

///|
/// 只打印某个角色的节点，用来把列表条目单独拎出来看。
pub fn nodes_of_role(
  nodes : Array[@moonui.Accessibility],
  role : @moonui.AccessRole,
) -> Array[@moonui.Accessibility] {
  let out : Array[@moonui.Accessibility] = []
  for n in nodes {
    if n.role == role {
      out.push(n)
    }
  }
  out
}
