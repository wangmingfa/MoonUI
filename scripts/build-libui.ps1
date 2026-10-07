# 编 MoonUI 真后端（§20，§48-03）需要的 libui-ng 静态库。
#
# 为什么要这个脚本：libui-ng 既不发布预编译包，也没有 CMake 工程，只有 meson，
# 所以真后端的依赖必须"从固定提交现编"。仓库里只存这份脚本和 pin，不存产物。
#
# 产物形态是"静态库 + /MT + release"，三条都是量出来的，改之前先读：
#   - 静态：可执行文件自带全部 UI 代码，moon test / moon run 不需要再把某个
#     含 libui.dll 的目录塞进 PATH（共享库那条路实测过，能跑，但每次测试都要
#     多管一层运行时查找）。
#   - /MT：moon 生成的 native 可执行文件用静态 CRT，两边必须一致，否则链接期
#     报 LNK4098（msvcrt.lib 与 LIBCMT.lib 冲突），运行时是两套堆。
#   - release：libui 的 debug 构建引用 __imp__CrtDbgReport（只有调试 CRT 才有），
#     和 /MT 的可执行文件根本链不上，报 LNK2001。
#
# 静态的代价：Windows 不会把资源链进静态库，所以 libui 自带的 manifest
# （Common Controls v6 + DPI 感知）丢了。这两件事由 adapter.c 自己补：
# #pragma comment(linker, "/manifestdependency:...") 声明 v6 控件，初始化时
# 显式调用 SetProcessDpiAwarenessContext（§30 本来就要按显示器取缩放）。
#
# 用法（仓库根或任意目录都行）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-libui.ps1
#   加 -Force 可以无视缓存重编。

param(
  [switch]$Force
)

$ErrorActionPreference = 'Continue'

# 上游 master 在 2026-10-07 的这个提交；换版本只改这一行，然后跑本脚本。
$Pin = '43ba1ef553c8993a43a67f1ce6e35983a2660d8c'
$Remote = 'https://github.com/libui-ng/libui-ng.git'

$Root = Split-Path -Parent $PSScriptRoot
$TpDir = Join-Path $Root 'third-party/libui'
$SrcDir = Join-Path $TpDir 'src'
$BuildDir = Join-Path $SrcDir 'build'
$LibDir = Join-Path $TpDir 'lib'
$StampFile = Join-Path $LibDir 'pinned-commit.txt'

function Fail([string]$Message) {
  Write-Host "! $Message" -ForegroundColor Red
  exit 1
}

function Run-Step([string]$Name, [scriptblock]$Body) {
  Write-Host "==> $Name"
  & $Body
  if ($LASTEXITCODE -ne 0) { Fail "$Name 失败（退出码 $LASTEXITCODE）" }
}

if ($env:OS -notmatch '^Windows') {
  Fail '本脚本只编 Windows 后端；unix 要 GTK3、macOS 要 Cocoa，都还没接'
}

# meson 从哪来：命令行指定的 MOONUI_MESON > PATH > 便携装的那份。
# 便携装在 D:\Apps\moonui-toolchain（embeddable Python + meson + ninja），
# 没进 PATH，也不写注册表，删目录就算卸载干净。
$Meson = $null
if ($env:MOONUI_MESON -and (Test-Path $env:MOONUI_MESON)) { $Meson = $env:MOONUI_MESON }
if (-not $Meson) {
  $cmd = Get-Command meson -ErrorAction SilentlyContinue
  if ($cmd) { $Meson = $cmd.Source }
}
if (-not $Meson) {
  $portable = 'D:\Apps\moonui-toolchain\py\Scripts\meson.exe'
  if (Test-Path $portable) { $Meson = $portable }
}
if (-not $Meson) {
  Fail '找不到 meson。装一份（pip install meson ninja）或用 MOONUI_MESON 指向 meson.exe'
}
Write-Host "meson: $Meson"

$LibFile = Join-Path $LibDir 'libui.a'
if (-not $Force -and (Test-Path $LibFile) -and (Test-Path $StampFile)) {
  if ((Get-Content $StampFile -Raw).Trim() -eq $Pin) {
    Write-Host "已经是 $Pin 的产物，跳过（-Force 可强制重编）"
    Write-Host "lib: $LibFile"
    exit 0
  }
}

New-Item -ItemType Directory -Force -Path $TpDir | Out-Null
New-Item -ItemType Directory -Force -Path $LibDir | Out-Null

# 源码：只取这一个提交，浅 fetch，不留历史。
if (-not (Test-Path (Join-Path $SrcDir '.git'))) {
  Run-Step 'git init' { git init $SrcDir | Out-Null }
  Run-Step 'git remote add' { git -C $SrcDir remote add origin $Remote | Out-Null }
}
Run-Step "git fetch $Pin" { git -C $SrcDir fetch --depth 1 origin $Pin | Out-Null }
Run-Step 'git checkout' { git -C $SrcDir checkout --detach FETCH_HEAD | Out-Null }
$Head = (git -C $SrcDir rev-parse HEAD | Out-String).Trim()
if ($Head -ne $Pin) { Fail "检出的提交是 $Head，不是 pin 的 $Pin" }

# 已经配好就复用：meson 会自己按 mtime 决定重编哪些对象。
if (-not (Test-Path (Join-Path $BuildDir 'meson-info/intro-projectinfo.json'))) {
  Run-Step 'meson setup' {
    & $Meson setup $BuildDir $SrcDir --buildtype=release -Ddefault_library=static `
      -Dexamples=false -Dtests=false -Db_vscrt=mt
  }
} else {
  Write-Host '==> meson setup（已有配置，跳过）'
}

Run-Step 'meson compile' { & $Meson compile -C $BuildDir }

$Built = Join-Path $BuildDir 'meson-out/libui.a'
if (-not (Test-Path $Built)) { Fail "构建完没找到 $Built" }
Copy-Item $Built $LibFile -Force

# adapter.c 包含的是包目录里那份 ui.h（native-stub 只编译同目录的 C 文件），
# 所以每次构建都从 pin 的检出里原样覆盖它：git diff 于是一次不漏地暴露 ABI 变化。
Copy-Item (Join-Path $SrcDir 'ui.h') (Join-Path $Root 'backends/libui/ui.h') -Force

Set-Content -Path $StampFile -Value $Pin -Encoding ASCII

$Size = [math]::Round((Get-Item $LibFile).Length / 1KB)
Write-Host "OK: $LibFile（$Size KB，pin $Pin）"
Write-Host '下一步：moon test backends/libui'
