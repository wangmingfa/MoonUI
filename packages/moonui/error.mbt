///|
/// MoonUI 统一错误类型（设计文档 §33）。
///
/// C 层的 `NULL` / `-1` / `false` 必须在 Backend 或 C Adapter 内转换成
/// `UiError`，不允许直接暴露给 MoonBit 用户。`pub(all)` 是因为 backend
/// 位于独立的包中，需要能够构造这些错误值。
pub(all) suberror UiError {
  /// Backend 初始化失败，携带底层给出的原因
  InitializationFailed(String)
  /// 请求的 backend 在当前平台不可用（缺库、缺显示环境等）
  BackendUnavailable(String)
  /// 句柄不存在、已被销毁，或来自另一个 backend
  InvalidHandle
  /// 原生调用失败，携带底层给出的原因
  OperationFailed(String)
  /// 当前 backend 或平台不支持该能力
  Unsupported(String)
  /// 对象已被销毁，仍在被使用
  Destroyed
  /// 所有权冲突：控件已被别的容器持有
  AlreadyOwned
} derive(Debug, Eq)

///|
/// 面向使用者的错误说明。Backend 负责把底层字符串放进 `reason`，
/// 这里只做统一的前缀，保证同一框架下错误可读性一致。
pub fn UiError::message(self : UiError) -> String {
  match self {
    InitializationFailed(reason) => "UI 初始化失败：\{reason}"
    BackendUnavailable(reason) => "Backend 不可用：\{reason}"
    InvalidHandle => "无效的原生句柄"
    OperationFailed(reason) => "操作失败：\{reason}"
    Unsupported(reason) => "不支持的操作：\{reason}"
    Destroyed => "对象已销毁"
    AlreadyOwned => "该控件已被其他容器持有"
  }
}

///|
impl Show for UiError with fn output(self : UiError, logger) {
  logger.write_string(self.message())
}

///|
pub extend UiError with Show::{to_string}

///|
/// 把 C 返回的空指针统一成 `UiError`，避免 `Option` 在各处被忘记处理。
pub fn[T] check_nonnull(ptr : T?, context : String) -> T raise UiError {
  match ptr {
    Some(v) => v
    None => raise OperationFailed("\{context} 返回空指针")
  }
}

///|
test "UiError 把 C 的失败形态翻译成带原因的错误" {
  assert_eq(
    UiError::InitializationFailed("cannot open display").message(),
    "UI 初始化失败：cannot open display",
  )
  assert_eq(
    UiError::BackendUnavailable("libui-ng 未编译").message(),
    "Backend 不可用：libui-ng 未编译",
  )
  assert_eq(UiError::InvalidHandle.message(), "无效的原生句柄")
  assert_eq(
    UiError::Unsupported("无 GL").message(),
    "不支持的操作：无 GL",
  )
  assert_eq(UiError::Destroyed.message(), "对象已销毁")
  assert_eq(
    UiError::AlreadyOwned.message(),
    "该控件已被其他容器持有",
  )
  assert_true(UiError::OperationFailed("x") != UiError::OperationFailed("y"))
  assert_eq(UiError::OperationFailed("x").to_string(), "操作失败：x")
}

///|
test "check_nonnull 在空指针时抛出带上下文的操作失败" {
  let ok : Int? = Some(42)
  assert_eq(check_nonnull(ok, "uiNewButton"), 42)
  let bad : Int? = None
  let caught = try {
    let _ = check_nonnull(bad, "uiNewWindow")
    None
  } catch {
    err => Some(err.message())
  }
  assert_eq(caught, Some("操作失败：uiNewWindow 返回空指针"))
}
