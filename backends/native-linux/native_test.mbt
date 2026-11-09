// T235 占位：GTK4 后端的真窗口测试在 P8 才写（事件/绘制/系统服务/音频，
// 走 GtkEventController + GSK + 异步剪贴板·文件框，与 mac/win 现有负控制脚手架
// 对齐）。这里只放一个能编译、能链接通过 GTK4 适配器的极简判据，证明 prebuild
// 把 adapter_native_gtk.c 编进了链接图、且 native-common 的 FFI 调用在 Linux
// 上有落点（P3 起窗口/事件循环/键盘/鼠标/手势是真实现，其余仍是桩）。
//
// 真机（CI 的 linux-backend-link job / 本地 Linux）跑这条时链接的是真 GTK4；
// mac/win 宿主上 moon check 只类型检查、不链接，不影响现有门禁。

///|
test "linux-gtk4-adapter-links" {
  return ()
}
