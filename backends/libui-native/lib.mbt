///|
/// 本包是纯链接挂点（见 moon.pkg 的说明），没有别的公开 API。
///
/// 这条函数的职责有两个：一是让包里有一个可编译的实体——空包会被 moon 拒绝；
/// 二是让示例的 import "真的被用"——示例 main.mbt 的第一行调它一次，锚点包
/// 就不是 unused import，`moon check --deny-warn` 不需要压任何警告。
/// 返回 Unit、无副作用：它不是 API，是链接握手的字面表达。
pub fn native_link_anchor() -> Unit {

}
