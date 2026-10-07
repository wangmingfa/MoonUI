#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* §48-02/03 的最小验证 stub：不接任何第三方 GUI 库，只把四件事钉死——
   裸指针地址的位宽、C 对象生命周期、UTF-8 往返、C 回调持有 MoonBit 闭包。
   这四项正是设计文档 §47 风险 1/2/4 的落点。 */

/* ---------- 1. C 管理生命周期的裸指针，地址用 int64 往返 ---------- */

typedef struct {
  int32_t value;
} ProbeRaw;

static int32_t probe_raw_live = 0;

MOONBIT_FFI_EXPORT
int64_t moonbit_probe_raw_new(int32_t value) {
  ProbeRaw *p = (ProbeRaw *)malloc(sizeof(ProbeRaw));
  if (p == 0) {
    return 0;
  }
  p->value = value;
  probe_raw_live += 1;
  return (int64_t)(uintptr_t)p;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_raw_get(int64_t addr) {
  if (addr == 0) {
    return -1;
  }
  ProbeRaw *p = (ProbeRaw *)(uintptr_t)addr;
  return p->value;
}

/* 这里刻意不做"重复 free"防护：防护 belongs to HandleTable（Core），
   stub 只负责证明 free 只会被调用一次。 */
MOONBIT_FFI_EXPORT
void moonbit_probe_raw_free(int64_t addr) {
  if (addr == 0) {
    return;
  }
  free((void *)(uintptr_t)addr);
  probe_raw_live -= 1;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_raw_live(void) {
  return probe_raw_live;
}

/* ---------- 2. external object：finalizer 只清 payload ---------- */

typedef struct {
  int32_t value;
  int32_t released;
  char *owned;
} ProbeObj;

static int32_t probe_obj_live = 0;

static void moonbit_probe_obj_finalize(void *self) {
  ProbeObj *o = (ProbeObj *)self;
  if (!o->released) {
    o->released = 1;
    probe_obj_live -= 1;
  }
  if (o->owned != 0) {
    free(o->owned);
    o->owned = 0;
  }
  /* 容器由 GC 释放，这里绝不能 free(self) */
}

MOONBIT_FFI_EXPORT
ProbeObj *moonbit_probe_obj_new(int32_t value) {
  ProbeObj *o = (ProbeObj *)moonbit_make_external_object(
      moonbit_probe_obj_finalize, sizeof(ProbeObj));
  o->value = value;
  o->released = 0;
  o->owned = (char *)malloc(16);
  if (o->owned != 0) {
    memcpy(o->owned, "payload", 8);
  }
  probe_obj_live += 1;
  return o;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_obj_value(ProbeObj *o) {
  if (o == 0 || o->released) {
    return -1;
  }
  return o->value;
}

/* 显式 release 与 finalizer 可能都跑，靠 released 标记保证计数不漂移 */
MOONBIT_FFI_EXPORT
void moonbit_probe_obj_release(ProbeObj *o) {
  if (o == 0 || o->released) {
    return;
  }
  o->released = 1;
  probe_obj_live -= 1;
  if (o->owned != 0) {
    free(o->owned);
    o->owned = 0;
  }
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_obj_live(void) {
  return probe_obj_live;
}

/* ---------- 3. UTF-8 字符串往返（§29） ---------- */

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_utf8_len(const char *s) {
  if (s == 0) {
    return -1;
  }
  return (int32_t)strlen(s);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_probe_append_bang(const char *s) {
  int32_t len = (int32_t)strlen(s);
  moonbit_bytes_t out = moonbit_make_bytes(len + 1, 0);
  memcpy(out, s, (size_t)len);
  out[len] = '!';
  return out;
}

/* ---------- 4. C 回调持有 MoonBit 闭包（§47 风险 1） ---------- */

typedef void (*probe_int_cb)(void *closure, int32_t value);

MOONBIT_FFI_EXPORT
void moonbit_probe_each(int32_t n, probe_int_cb call_closure, void *closure) {
  for (int32_t i = 0; i < n; ++i) {
    call_closure(closure, i);
  }
}

static probe_int_cb probe_cb = 0;
static void *probe_cb_data = 0;

MOONBIT_FFI_EXPORT
void moonbit_probe_store_callback(probe_int_cb cb, void *data) {
  if (probe_cb_data != 0) {
    moonbit_decref(probe_cb_data);
  }
  probe_cb = cb;
  probe_cb_data = data;
  if (data != 0) {
    /* C 侧长期持有，必须 incref，否则 GC 会回收闭包 */
    moonbit_incref(data);
  }
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_fire_callback(int32_t value) {
  if (probe_cb == 0 || probe_cb_data == 0) {
    return -1;
  }
  probe_cb(probe_cb_data, value);
  return 1;
}

MOONBIT_FFI_EXPORT
void moonbit_probe_clear_callback(void) {
  if (probe_cb_data != 0) {
    moonbit_decref(probe_cb_data);
    probe_cb_data = 0;
  }
  probe_cb = 0;
}
