# backends/native-common/third-party

平台 adapter 的第三方纯 C 依赖。这里的代码**不是本仓库的原创工作**，每个子目录
/文件的出处与取用版本记在同目录的说明里——读这份文件的人首先要看到出处。

## stb_vorbis.c

- 出处：**stb** 单头文件库集合，作者 **Sean Barrett（nothings）**
  - 仓库：<https://github.com/nothings/stb>（`stb_vorbis.c`）
  - 主页：<http://nothings.org/stb_vorbis/>
- 取用版本：**v1.22**（2021-07-11，文件头自标），2026-11-05 取自 master raw
- 许可证：**公有领域（MIT 双许可可选，见文件尾 LICENSE 段）**——不需要附带
  许可证副本，但出处与致谢记在本文件。
- 用途：Ogg Vorbis 解码。AVFoundation 不认 Ogg 容器，lunamusic 的扫描白名单
  却收了 `ogg`（TODO `T166`），播放与探针两条路径在 mac 半
  （`backends/native-macos/adapter_native.m`）退到这里：`stb_vorbis_open_filename`
  整文件解成 float32 非交织 PCM 装 `AVAudioPCMBuffer`；探针读 info 与
  Vorbis comment（TITLE/ARTIST/ALBUM）。

### 引入方式（重要，改这块前先读）

不做 `#include <stb_vorbis.h>` / 实现分离的形状，直接在 adapter_native.m 里
`#include "stb_vorbis.c"`（前面定义裁剪宏收敛体积）——stb 的单文件分发本来就是
这么设计的。由此有两个后果：

1. **本文件不参与编译**：仓库唯一的 C 编译通道是 `prebuild-link.js` 的
   `compileAdapter`，它编的是两份平台 adapter，stb_vorbis.c 只是被 `#include`
   进去。所以 mtime 缓存比对（`compileAdapter` 里那段）必须把 stb_vorbis.c
   算进去——已算（与 adapter_native.m、adapter.h 三者取较新）。
2. **只有 mac 半引用它**：Windows 的 adapter_native.c 本轮零改动（T166 是 mac
   侧欠账），但这份文件放在共享半的 third-party/ 里，Windows 半将来要解 Ogg
   时同一个 `#include` 就能用。

### 上游同步

stb_vorbis 极少动（1.22 是 2021 年的版本）。要同步时直接替换本文件，然后
`moon clean` + 全量门禁（见仓库根 AGENTS.md 的工具一节）——`#include` 进 .m
的文件改动不触发重编，不 clean 会跑到旧二进制、假绿。
