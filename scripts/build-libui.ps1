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
#
# 前置：Meson + Ninja 在 PATH 上（上游只给 meson 工程，没有 CMake，也没有预编译包）。
# 最省事的是官方 MSI，它一次把两个都装上：https://github.com/mesonbuild/meson/releases
# 取最新 release 资产里的 .msi。装完要另开一个 PowerShell，PATH 不刷新到已开的窗口。
# 有真 Python 时 pip install meson ninja 也够；或者把 MOONUI_MESON 指到 meson.exe。
# 这一步另外还要 git（取 pin 的提交）和装了 C++ 工作负载的 MSVC。
# 而且**要在 VS 的开发环境里跑**：普通 PowerShell 下 meson 会先撞见 Git for Windows
# 那份 coreutils 的 link.exe，报 "Found GNU link.exe instead of MSVC link.exe"。
# 先进开发环境再跑本脚本（Launch-VsDevShell.ps1 -Arch amd64，或开始菜单里那个
# "x64 Native Tools Command Prompt for VS 2022"）；setup 真失败时脚本会把这段打出来。
# macOS 那半走 scripts/build-libui.sh，它绕开 meson 直接 clang，不需要装任何东西。

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

# meson 从哪来：环境变量指定的 MOONUI_MESON > PATH 上的 meson > 便携装的那份。
# 便携装在 D:\Apps\moonui-toolchain（embeddable Python + meson + ninja），
# 没进 PATH，也不写注册表，删目录就算卸载干净——那一台机器才有，别的 Windows 机器
# 上多半不存在，所以正常路径是前两个：装官方 MSI（带 Ninja，见文件头那条链接），
# 或者把 MOONUI_MESON 指到自己那份 meson.exe。
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
  Fail @'
找不到 meson。上游只有 meson 工程，没有 CMake、也不发预编译包，所以这一步绕不开。
  装官方 MSI（一次带上 Ninja，装进 Program Files 要管理员）：
    https://github.com/mesonbuild/meson/releases  —— 取最新 release 资产里的 .msi
    装完另开一个 PowerShell：PATH 不刷新到已经开着的窗口。
  或者机器上有真 Python 时：pip install meson ninja
    （别用 ...WindowsApps\python.exe，Version 0.0.0.0 那个是 Store 的别名占位，不是 Python）
  已经有了但不想进 PATH：$env:MOONUI_MESON = 'C:\path\to\meson.exe'
  还要检查 ninja：meson setup 需要它，MSI 和 pip 那条都会一起装上。
'@
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
    if ($LASTEXITCODE -ne 0) {
      # Windows 实测：装了 Git for Windows 的机器上，PATH 里排在 MSVC 链接器前面的是
      # coreutils 那份 link.exe（创建硬链接那个），meson 于是报
      #   ERROR: Found GNU link.exe instead of MSVC link.exe ... This link.exe is not a linker.
      # 停下。这不是缺 VS，也不是仓库的问题——而 scripts/test-local.sh 要的 bash 来自同一个
      # Git for Windows，所以普通 PowerShell 里跑本脚本基本都会撞上它。先初始化 VS 的开发环境
      # （PATH 换成 MSVC 那套），再重跑本脚本就行。
      Write-Host '! meson setup 失败。若上面那句是 "Found GNU link.exe instead of MSVC link.exe",' -ForegroundColor Yellow
      Write-Host '  那是 Git for Windows 的 C:\Program Files\Git\usr\bin\link.exe 抢在 MSVC 链接器前面。'
      Write-Host '  在同一个 PowerShell 里先初始化 VS 的开发环境，再重跑本脚本：'
      Write-Host '    & "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation'
      Write-Host '  （Community 那段按你的版本换 Professional / Enterprise / BuildTools；'
      Write-Host '    或者用开始菜单的 "x64 Native Tools Command Prompt for VS 2022"，进来后 cd 到仓库根）'
    }
  }
} else {
  Write-Host '==> meson setup（已有配置，跳过）'
}

Run-Step 'meson compile' { & $Meson compile -C $BuildDir }

$Built = Join-Path $BuildDir 'meson-out/libui.a'
if (-not (Test-Path $Built)) { Fail "构建完没找到 $Built" }
Copy-Item $Built $LibFile -Force

# adapter.c 包含的是包目录里那两份头（native-stub 只编译同目录的 C 文件），
# 所以每次构建都要让它们跟上 pin 的检出：git diff 于是一次不漏地暴露 ABI 变化。
# ui_windows.h 是 libui 的内部声明头，只要其中 uiWindowsControlMinimumSize 一个符号——
# 控件的固有尺寸必须用 libui 自己的量法（label 用文本 extent、button 用 BCM_GETIDEALSIZE
# 否则回落 DLU 换算），自己重算一遍迟早和它不一致。
#
# 比较过再拷，而不是无条件 Copy-Item -Force：那两份头的 git diff 本意是"暴露 ABI 漂移"，
# 可 Windows 上 pin 的检出是 CRLF、入库的是 LF，内容一个字没变也会被重写成新的 mtime，
# 于是这条 diff 暴露的第一层是行尾和 mtime 的噪声。.gitattributes 里
# `backends/*/ui*.h text eol=lf` 已经让"只有行尾不同"不再算改动，但救不了 mtime。
# 归一化只用于**比较**（按 Latin-1 读，字节 1:1，绝不会再写回去）；真的不等时仍然
# Copy-Item 原样覆盖源字节，保留"原样覆盖，git diff 一次不漏地暴露 ABI 变化"那句承诺。
function Copy-HeaderIfChanged {
  param(
    [string]$From,
    [string]$To
  )
  if (Test-Path $To) {
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $src = [System.IO.File]::ReadAllText($From, $latin1) -replace "`r`n", "`n"
    $dst = [System.IO.File]::ReadAllText($To, $latin1) -replace "`r`n", "`n"
    if ($src -ceq $dst) {
      Write-Host "==> 头文件内容一致，不动 mtime：$To"
      return
    }
    Write-Host "==> 头文件变了，覆盖（git diff 会显示 ABI 变化）：$To" -ForegroundColor Yellow
  }
  Copy-Item $From $To -Force
}
Copy-HeaderIfChanged (Join-Path $SrcDir 'ui.h') (Join-Path $Root 'backends/libui/ui.h')
Copy-HeaderIfChanged (Join-Path $SrcDir 'ui_windows.h') (Join-Path $Root 'backends/libui/ui_windows.h')

Set-Content -Path $StampFile -Value $Pin -Encoding ASCII

$Size = [math]::Round((Get-Item $LibFile).Length / 1KB)
Write-Host "OK: $LibFile（$Size KB，pin $Pin）"
Write-Host '下一步：moon test backends/libui'
