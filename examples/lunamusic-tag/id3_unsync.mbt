// id3_unsync.mbt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 id3_unsync.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE。本仓库只做按需裁剪，
// 未改动实现；裁剪清单与上游出处见本目录 README.md。
//
// ID3v2 的 Unsynchronisation（反同步）还原。
//
// 写入侧为了不让标签内出现伪同步信号（%11111111 111xxxxx），会在每个
// $FF 后插入 $00；同时所有 $FF $00 组合都会被写成 $FF $00 $00。
// 因此还原规则只有一条：**遇到 $FF $00 就删掉这个 $00**。
// 注意不要"删掉所有 $00"——$FF 后面跟非零字节时那个 $FF 是原始数据。

///|
/// 还原 unsynchronisation，返回新分配的字节。
///
/// 输入不含伪同步时返回值与输入等值（会拷贝一份，便于上层统一处理）。
pub fn unsynchronise(data : BytesView) -> Bytes {
  let out = @buffer.Buffer()
  let mut i = 0
  while i < data.length() {
    let b = data.at(i)
    out.write_byte(b)
    if b == b'\xFF' && i + 1 < data.length() && data.at(i + 1) == b'\x00' {
      // 跳过插入的 $00
      i += 2
    } else {
      i += 1
    }
  }
  out.to_bytes()
}
