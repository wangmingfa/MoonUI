/*
 * screenshot-window.sh 的 `list <pid> [layer]` 子命令：窗口枚举 helper。
 *
 * 为什么是 C 而不是 FFI：CoreGraphics 是纯 C API（CGWindowListCopyWindowInfo
 * 返回 CFArray of CFDictionary），用 C 调能让 CF 指针 / CFNumberType / CFString
 * 编码这些 ABI 细节由编译器把关；系统自带的 cc + SDK 就够了，不需要 Python
 * ctypes，也不需要给仓库引任何 npm 原生依赖。由 screenshot-window.sh 在首次
 * 调用时现编到 $TMPDIR，之后按 mtime 复用。
 *
 * 与旧 ctypes 版**逐行等价**（A/B 对拍的基线），包括两处已知缺陷也原样保留，
 * 见脚本头注与 TODO 的 `T242`：
 *   ① 第一个参数仍是字面量 2 —— 它其实是 kCGWindowListOptionOnScreenAboveWindow，
 *      不是注释里写的 "all windows（含离屏）"；改成 0 会改变 list 的输出。
 *   ② bounds 的键仍拼成 "kCGWindowBoundsX" 等 —— CoreGraphics 的 bounds 字典
 *      实际用 "X"/"Y"/"Width"/"Height"，所以旧版输出的几何恒为 [0,0 0x0]。
 * 迁移的目的是换语言，不是顺手修 bug；两条都单独挂账。
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
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

/* 见头注 ②：键名故意照抄旧版，取不到就保持 0。 */
static int64_t bounds_of(CFDictionaryRef win, const char *suffix) {
  CFDictionaryRef b;
  CFStringRef key;
  char name[64];
  int64_t v = 0;
  if (win == NULL) return 0;
  b = (CFDictionaryRef)CFDictionaryGetValue(win, kCGWindowBounds);
  if (b == NULL) return 0;
  snprintf(name, sizeof(name), "kCGWindowBounds%s", suffix);
  key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
  if (key != NULL) {
    num_of(b, key, &v);
    CFRelease(key);
  }
  return v;
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
  int64_t bx, by, bw, bh;

  if (argc < 2 || !parse_long(argv[1], &pid)) {
    fprintf(stderr, "用法: window-list <pid> [layer]\n");
    return 2;
  }
  if (argc > 2 && !parse_long(argv[2], &layer)) {
    fprintf(stderr, "layer 不是整数：%s\n", argv[2]);
    return 2;
  }

  /* 2 = kCGWindowListOptionOnScreenAboveWindow（不是 All=0）。见头注 ①。 */
  list_ref = CGWindowListCopyWindowInfo((CGWindowListOption)2, kCGNullWindowID);
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
    bx = bounds_of(d, "X");
    by = bounds_of(d, "Y");
    bw = bounds_of(d, "Width");
    bh = bounds_of(d, "Height");
    printf("id=%s  [%lld,%lld %lldx%lld]  %s\n", idbuf, (long long)bx,
           (long long)by, (long long)bw, (long long)bh, name);
  }
  CFRelease(list_ref);
  return 0;
}
