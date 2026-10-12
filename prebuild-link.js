// 模块级 prebuild 配置脚本（TODO `T59`，Windows 半 `T60`）：把两个后端包的
// 链接参数在构建前注入，让它顺 import 传给下游的可执行包（-native-macos /
// -native-windows 各五个壳，及两个后端包自己的测试二进制）。
//
// 为什么存在：`moon.pkg` 的 `link` 只在被链接的可执行包里生效，库包声明的
// 不顺 import 传下来，于是每个壳都得抄一份 `cc-link-flags`。moon 的
// `--moonbit-unstable-prebuild` 机制（moon.mod 的 options 里指到本文件）让
// 脚本在构建前跑一次、往 stdout 吐一份 JSON，其中的 `link_configs` 会挂到
// 指定包上并传播给依赖它的可执行包。机制只在 native/LLVM 后端跑（wasm 与
// `moon check` 都跳过），需要 PATH 里有 node。
//
// 按宿主分支（2026-10-11，借 justjavac/moonbit-dialog 的写法）：只吐当前
// 平台那一份，macOS 挂 libui-macos、Windows 挂 libui-windows。moon 跑本
// 脚本时环境里带 MOON_HOST_OS，兜底再认 process.platform；两边都不是
// darwin/win32 时吐空列表（Linux GTK3 后端 `T2` 落地时在此补一分）。
//
// Windows 那份的 link_flags 逐字抄自原先 backends/libui-windows/moon.pkg
// 里的 cc-link-flags——开头那个 `-link` 是 cl→link.exe 的分隔符，不能少
// （T14 量过：删掉它 /LIBPATH 就落到 cl 头上，LNK1104 打不开 libui.a）。
// 这里**不**借 moon 的 MSVC 自动翻译（`-lfoo`→`foo.lib`）改成通用写法：
// 那套翻译在这台机器上没量过，而这串 MSVC 原样是 T7/T50 真跑验证过的
// 形状，先保形状。
//
// 注意相对路径按当前工作目录（仓库根）展开，与原先 moon.pkg 里的行为一致，
// 所以 moon 命令仍必须在仓库根跑。`libui.a` 是静态归档文件而不是 -l 库名，
// 保持整串写在 link_flags 里。

/// 两个后端的链接参数各一份。macOS 是 clang 写法；Windows 是 MSVC 原样
/// （含 `-link` 分隔符，见上）。宿主不是 darwin/win32 时一份都不挂。
const macosLinkFlags =
  "-lobjc -framework Cocoa third-party/libui/lib/libui.a"
const windowsLinkFlags =
  '-link /LIBPATH:"third-party/libui/lib" libui.a user32.lib kernel32.lib gdi32.lib comctl32.lib uxtheme.lib msimg32.lib comdlg32.lib d2d1.lib dwrite.lib ole32.lib oleaut32.lib oleacc.lib uuid.lib windowscodecs.lib advapi32.lib'

function hostOS() {
  const fromMoon = process.env.MOON_HOST_OS
  if (fromMoon) {
    // moon 若透传 Rust 的 std::env::consts::OS 就是 "macos"/"windows"/"linux"；
    // 兼容 "darwin"，process.platform 兜底时也会出现它
    return fromMoon === "darwin" ? "macos" : fromMoon
  }
  if (process.platform === "darwin") {
    return "macos"
  }
  return process.platform === "win32" ? "windows" : process.platform
}

const linkConfigs = []
const os = hostOS()
if (os === "macos") {
  linkConfigs.push({
    package: "username/MoonUI/backends/libui-macos",
    link_flags: macosLinkFlags,
  })
} else if (os === "windows") {
  linkConfigs.push({
    package: "username/MoonUI/backends/libui-windows",
    link_flags: windowsLinkFlags,
  })
}

console.log(JSON.stringify({ link_configs: linkConfigs }))
