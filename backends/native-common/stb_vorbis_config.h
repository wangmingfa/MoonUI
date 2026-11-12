/* stb_vorbis 裁剪宏的唯一来源（本仓自有文件，不是 vendored 原件）。
 *
 * T233 第五刀：vendored 的 third-party/stb_vorbis.c 现在同时被两个编译单元
 * include ——
 *   backends/native-macos/adapter_native.m    只取声明（STB_VORBIS_HEADER_ONLY）
 *   backends/native-common/stb_vorbis_unit.c  取声明 + 实现
 * 这两枚裁剪宏在 vendored 文件的**声明段**（:174 / :257 / :324 / :360）也生效，
 * 两边定义不同就会让声明集与实现集错位，而链接期未必报得出来（声明多出来的
 * 那几个 API 只要没人调用就静默）。所以两边都只 include 本文件，禁止各自
 * #define。上游同步替换 stb_vorbis.c 时不用动这里。
 *
 * 出处、取用版本与许可证见同目录 third-party/README.md。
 */
#ifndef MOONUI_STB_VORBIS_CONFIG_H
#define MOONUI_STB_VORBIS_CONFIG_H

/* 只走「文件名打开 + float 输出 + 拉数据」那一路（T166）：pushdata 与整型
 * 转换两块裁掉，收敛体积。 */
#define STB_VORBIS_NO_PUSHDATA_API
#define STB_VORBIS_NO_INTEGER_CONVERSION

#endif /* MOONUI_STB_VORBIS_CONFIG_H */
