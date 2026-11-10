/*
 * screenshot-window.sh 的 `list <pid> [layer]` 子命令：窗口枚举 helper。
 *
 * 为什么是 C 而不是 FFI：CoreGraphics 是纯 C API（CGWindowListCopyWindowInfo
 * 返回 CFArray of CFDictionary），用 C 调能让 CF 指针 / CFNumberType / CFString
 * 编码这些 ABI 细节由编译器把关；系统自带的 cc + SDK 就够了，不需要 Python
 * ctypes，也不需要给仓库引任何 npm 原生依赖。由 screenshot-window.sh 在首次
 * 调用时现编到 $TMPDIR，之后按**源码内容哈希**复用（不是 mtime：同一秒内
 * 改写源码时 mtime 判不出脏，会让语义负控制跑旧二进制）。
 *
 * 迁移（T243）时与旧 ctypes 版**逐行等价**，包括两处已知缺陷也原样照抄，
 * 那是 A/B 对拍的基线；T242 起两处都修掉了，已不再等价（见下）。
 *
 * T242（2026-11-10 修掉两处旧缺陷）：
 *   ① 第一个参数从字面量 2（kCGWindowListOptionOnScreenAboveWindow，
 *      会漏掉离屏窗口）改成 kCGWindowListOptionAll；本机真跑 All 列 386 窗、
 *      2 只列 59 窗。
 *   ② bounds 从拼错的 "kCGWindowBoundsX" 等改成官方建议的
 *      CGRectMakeWithDictionaryRepresentation；旧键名根本不存在，
 *      CFDictionaryGetValue 恒 NULL，几何恒 [0,0 0x0]。
 * 判据在 scripts/window-list-check.sh：同刻 A/B（old 由本文件注入两处旧语义
 * 生成），几何非 0 与行数 / id 集合的差异都必须可点名。
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* 旧版 ctypes 用 CFNumberGetValue(v, 4, byref(c_int64))；4 就是
 * kCFNumberSInt64Type（CFNumber.h:36）。 */
static int num_of(CFDictionaryRef d, CFStringRef key, int64_t *out) {
  CFNumberRef v;
  if (d == NULL) return 0;
  v = (CFNumberRef)CFDictionaryGetValue(d, key);
  if (v == NULL) return 0;
  *out = 0;
  return CFNumberGetValue(v, kCFNumberSInt64Type, out) ? 1 : 0;
}

static void str_of(CFDictionaryRef d, CFStringRef key, char *buf, CFIndex n) {
  CFStringRef v;
  buf[0] = '\0';
  if (d == NULL) return;
  v = (CFStringRef)CFDictionaryGetValue(d, key);
  if (v == NULL) return;
  /* 旧版用 256 字节缓冲 + 0x08000100(= kCFStringEncodingUTF8)，失败即空串。 */
  CFStringGetCString(v, buf, n, kCFStringEncodingUTF8);
}

/* T242②：kCGWindowBounds 的值是 CFDictionary，官方读法是
 * CGRectMakeWithDictionaryRepresentation（CGWindow.h:66-72）。旧版拼出
 * "kCGWindowBoundsX" 这种不存在的键，CFDictionaryGetValue 恒 NULL，
 * 于是几何恒 [0,0 0x0]——那一格在 A/B 里根本不可观测。 */
static int bounds_of(CFDictionaryRef win, CGRect *out) {
  CFDictionaryRef b;
  if (win == NULL) return 0;
  b = (CFDictionaryRef)CFDictionaryGetValue(win, kCGWindowBounds);
  if (b == NULL) return 0;
  return CGRectMakeWithDictionaryRepresentation(b, out) ? 1 : 0;
}

static int parse_long(const char *s, int64_t *out) {
  char *end;
  long v;
  if (s == NULL || *s == '\0') return 0;
  v = strtol(s, &end, 10);
  if (*end != '\0') return 0;
  *out = (int64_t)v;
  return 1;
}

int main(int argc, char **argv) {
  int64_t pid, layer = 0, owner, ly, wid;
  CFArrayRef list_ref;
  CFIndex i, n;
  char idbuf[32], name[256];
  CGRect bounds;
  int64_t bx, by, bw, bh;

  if (argc < 2 || !parse_long(argv[1], &pid)) {
    fprintf(stderr, "用法: window-list <pid> [layer]\n");
    return 2;
  }
  if (argc > 2 && !parse_long(argv[2], &layer)) {
    fprintf(stderr, "layer 不是整数：%s\n", argv[2]);
    return 2;
  }

  /* T242①：All 含离屏窗口。2 是 kCGWindowListOptionOnScreenAboveWindow，
   * 只列"某窗口之上且在当前屏"的那些（本机实测 386 → 59）。 */
  list_ref = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  if (list_ref == NULL) return 0;
  n = CFArrayGetCount(list_ref);
  for (i = 0; i < n; i++) {
    CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(list_ref, i);
    if (!num_of(d, kCGWindowOwnerPID, &owner) || owner != pid) continue;
    /* 旧版：layer >= 0 才按 layer 过滤；传 -1 表示不过滤。 */
    if (layer >= 0) {
      if (!num_of(d, kCGWindowLayer, &ly) || ly != layer) continue;
    }
    if (num_of(d, kCGWindowNumber, &wid)) {
      snprintf(idbuf, sizeof(idbuf), "%lld", (long long)wid);
    } else {
      snprintf(idbuf, sizeof(idbuf), "None");
    }
    str_of(d, kCGWindowName, name, (CFIndex)sizeof(name));
    if (bounds_of(d, &bounds)) {
      bx = (int64_t)llround((double)bounds.origin.x);
      by = (int64_t)llround((double)bounds.origin.y);
      bw = (int64_t)llround((double)bounds.size.width);
      bh = (int64_t)llround((double)bounds.size.height);
    } else {
      bx = by = bw = bh = 0;
    }
    printf("id=%s  [%lld,%lld %lldx%lld]  %s\n", idbuf, (long long)bx,
           (long long)by, (long long)bw, (long long)bh, name);
  }
  CFRelease(list_ref);
  return 0;
}
