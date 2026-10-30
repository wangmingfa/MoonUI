// tag_error.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 tag_error.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// 音频文件是外部不可信输入：截断、非法字段、超界尺寸都必须落到结构化
// 错误上，绝不能 panic。所有解析入口返回 Result 或 raise TagError。

///|
/// 标签解析与写入过程中可能出现的错误。
pub suberror TagError {
  /// 数据长度不足（文件被截断）。
  Truncated(offset~ : Int32, need~ : Int32, actual~ : Int32)
  /// 数据开头不是本格式的魔数。
  NotTagged(format~ : String)
  /// 标签头字段非法（版本、flags、尺寸等）。
  BadHeader(reason~ : String)
  /// 帧头字段非法。
  BadFrameHeader(reason~ : String)
  /// 帧声明尺寸超出标签或文件边界。
  FrameOutOfBounds(frame_id~ : String, size~ : Int32, available~ : Int32)
  /// 帧载荷内容非法（编码字节、终止符、字段长度等）。
  BadFrameData(frame_id~ : String, reason~ : String)
  /// 合法但当前版本尚未实现（加密帧、压缩帧等）。
  Unsupported(what~ : String)
  /// 不支持的版本号（如 ID3v2.5 或更高）。
  UnsupportedVersion(version~ : Int32)
}

///|
/// 把错误渲染为一句中文说明（CLI 与日志用；不含隐藏内部量）。
pub fn TagError::message(self : TagError) -> String {
  match self {
    Truncated(offset~, need~, actual~) =>
      "数据被截断：偏移 \{offset} 处需要 \{need} 字节，实际只有 \{actual} 字节"
    NotTagged(format~) => "文件不是 \{format} 标签"
    BadHeader(reason~) => "标签头非法：\{reason}"
    BadFrameHeader(reason~) => "帧头非法：\{reason}"
    FrameOutOfBounds(frame_id~, size~, available~) =>
      "帧 \{frame_id} 声明 \{size} 字节，但标签内只剩 \{available} 字节"
    BadFrameData(frame_id~, reason~) =>
      "帧 \{frame_id} 载荷非法：\{reason}"
    Unsupported(what~) => "暂不支持：\{what}"
    UnsupportedVersion(version~) => "不支持的标签版本：\{version}"
  }
}
