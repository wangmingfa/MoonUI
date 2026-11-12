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

**T233 第五刀（2026-11-12）起改成声明/实现两个编译单元**，vendored 本文件一字
未改：v1.22 的 `:420` 本来就有 `STB_VORBIS_HEADER_ONLY` 守卫（`:5541` 收口），
声明段 `:74-414` 在守卫外，可以分离——早期落地注里「无实现分离守卫、要拆就得
动第三方文件」的判断是错的。

- 声明侧：`backends/native-macos/adapter_native.m` 定义
  `STB_VORBIS_HEADER_ONLY` 后 `#include` 本文件，只拿类型与 API 声明；
- 实现侧：`backends/native-common/stb_vorbis_unit.c`（本仓自有包装）整份
  `#include` 本文件，单独编成 `stb_vorbis.o`；
- 两个 .o 一起收进 `libadapter_native.a`，静态库按成员拉取；
- 裁剪宏（`STB_VORBIS_NO_PUSHDATA_API` / `NO_INTEGER_CONVERSION`）统一放在
  `backends/native-common/stb_vorbis_config.h`，两边只 include 它，不许各自
  `#define`（这两个宏在声明段也生效，不一致会让声明集与实现集错位）。

由此有两个后果：

1. **本文件仍不单独参与编译**，但现在被两个编译单元 include。
   `prebuild-link.js` 的两份 mtime 缓存比对都要把本文件算进去，
   `stb_vorbis_config.h` 也要进键；
2. **只有 mac 半引用它**：Windows / Linux 的 adapter 本轮零改动。将来那两半要
   解 Ogg，在各自 `compileAdapter` 分支里加编 `stb_vorbis_unit.c` 并把 .o 收进
   对应静态库即可，不再是「同一个 `#include` 就能用」。

### 上游同步

stb_vorbis 极少动（1.22 是 2021 年的版本）。要同步时**直接替换本文件**即可
（这条约定没变），然后 `moon clean` + 全量门禁（见仓库根 AGENTS.md 的工具一节）。
替换后 `scripts/vorbis-unit-check.sh` 里钉的 sha256 会红，那是提醒复核包装与
裁剪宏是否仍配套，把常量一并更新；别靠改判据蒙过去。
