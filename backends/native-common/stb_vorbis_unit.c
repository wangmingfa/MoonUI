/* vendored stb_vorbis 的独立编译单元（本仓自有包装，不是第三方原件）。
 *
 * T233 第五刀：`adapter_native.m` 原先整份 `#include` vendored 文件，5584 行
 * 第三方实现与平台 C 编在同一个 .o 里。这里改成单独一个 .o，与
 * `adapter_native.o` 一起收进 `libadapter_native.a`；adapter 侧只 include
 * `STB_VORBIS_HEADER_ONLY` 的声明段，由静态库按成员拉取解引用。
 *
 * 为什么可以不改第三方文件：v1.22 的 `:420` 有 `#ifndef STB_VORBIS_HEADER_ONLY`
 * 守卫（`:5541` 收口），声明段 `:74-414` 在守卫外，本来就能声明/实现分离。
 * 所以 third-party/README.md 的「直接替换本文件」同步约定原样保留，本文件也不
 * 放进 third-party/，上游替换时不会顺手覆盖掉它。
 *
 * 裁剪宏统一走 stb_vorbis_config.h，别在这里另写 #define。
 * 上游固有一条 -Wtautological-compare（指针溢出判据，:1404），局部压掉、
 * 不污染其它部分的告警面；非 clang 宿主（将来 Linux 半复用）跳过这组 pragma。
 */
#include "stb_vorbis_config.h"

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-compare"
#endif

#include "third-party/stb_vorbis.c"

#if defined(__clang__)
#pragma clang diagnostic pop
#endif
