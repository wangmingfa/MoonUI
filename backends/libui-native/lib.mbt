///|
/// 本包是纯链接挂点（见 moon.pkg 的说明），没有公开 API。
/// 这条函数只是让包里有一个可编译的实体——空包会被 moon 拒绝。
/// 示例不调用它；`warnings = "-unused_package"` 已在 moon.pkg 里声明。
pub fn native_link_anchor() -> Int {
  1
}
