///|
/// String → UTF-8 Bytes（extern 的 Bytes lowering 要数据指针）。
/// 放在门控无关的文件里：native 的落盘半消费它，wasm 半也看得见这个消费点
/// （不出现 wasm 侧 unused_package 的假警报，moonui 的 cstr 同款布局）。
fn cm_cstr(text : String) -> Bytes {
  @utf8.encode(text)
}
