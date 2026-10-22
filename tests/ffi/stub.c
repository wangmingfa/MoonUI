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

/* ---------- 5. worker 跨线程投递（T85①）：闭包跨线程回来仍是活体 ----------
 *
 * 后端 worker 的形状（adapter.h 的 worker 段注）依赖两个前提：平台线程经
 * FuncRef trampoline 调回 MoonBit 闭包是活体（不是尸体），跨界递增递减在本
 * 工具链上可用。store_callback 那格钉的是同线程的延迟回调，这里把另一半钉住：
 * 起跑握手用真同步原语（不许 sleep 赌时序），主线程制造分配压力逼 GC 走动
 * 之后放行 worker。线程原语按宿主分叉（`T112`①，2026-10-22）：POSIX 宿主
 * 走 pthread（mutex + condvar），Windows/MSVC 没有 pthread.h，走 Win32 的
 * 两个 auto-reset 事件（up = worker 喊到了、go = 主线程放行）——握手语义
 * 逐条对齐，两条路都是真同步点。 */

#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

typedef void (*probe_void_cb)(void *closure);

static probe_void_cb probe_w_fn = 0;
static void *probe_w_data = 0;
static int probe_w_started = 0;
static int probe_w_up = 0;
static int probe_w_reclaims = 0;

#ifdef _WIN32

static HANDLE probe_w_up_evt = 0;
static HANDLE probe_w_go_evt = 0;
static HANDLE probe_w_thread = 0;
static int probe_w_created = 0;

static DWORD WINAPI probe_w_worker(LPVOID arg) {
  (void)arg;
  /* 起跑握手的 Windows 半：auto-reset 事件当真同步点，语义与 condvar 版
   * 逐条对齐（喊到 → 等放行）。 */
  SetEvent(probe_w_up_evt);
  WaitForSingleObject(probe_w_go_evt, INFINITE);
  /* 真投递：worker 线程直接调 MoonBit 闭包（分配压力之后的活体检查） */
  if (probe_w_fn != 0 && probe_w_data != 0) {
    probe_w_fn(probe_w_data);
  }
  /* 跨线程回收探针：worker 退场前回收它自己那份引用（reclaims=1 时） */
  if (probe_w_reclaims && probe_w_data != 0) {
    moonbit_decref(probe_w_data);
    probe_w_data = 0;
    probe_w_fn = 0;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_worker_arm(probe_void_cb call_closure, void *closure,
                                 int32_t worker_reclaims) {
  if (probe_w_created) {
    return -1;
  }
  probe_w_fn = call_closure;
  probe_w_data = closure;
  probe_w_reclaims = (int)worker_reclaims;
  if (closure != 0) {
    /* C 侧长期持有，必须 incref，否则 GC 会回收闭包 */
    moonbit_incref(closure);
  }
  if (probe_w_up_evt == 0) {
    probe_w_up_evt = CreateEventW(0, FALSE, FALSE, 0);
    probe_w_go_evt = CreateEventW(0, FALSE, FALSE, 0);
    if (probe_w_up_evt == 0 || probe_w_go_evt == 0) {
      return -2;
    }
  }
  probe_w_thread = CreateThread(0, 0, probe_w_worker, 0, 0, 0);
  if (probe_w_thread == 0) {
    return -2;
  }
  probe_w_created = 1;
  /* 等起跑握手的另一半：真同步点，不 sleep */
  WaitForSingleObject(probe_w_up_evt, INFINITE);
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_worker_go(void) {
  SetEvent(probe_w_go_evt);
  WaitForSingleObject(probe_w_thread, INFINITE);
  CloseHandle(probe_w_thread);
  probe_w_thread = 0;
  probe_w_created = 0;
  return 0;
}

#else

static pthread_mutex_t probe_w_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t probe_w_handoff = PTHREAD_COND_INITIALIZER;
static pthread_cond_t probe_w_go = PTHREAD_COND_INITIALIZER;
static pthread_t probe_w_thread;
static int probe_w_created = 0;

static void *probe_w_worker(void *arg) {
  (void)arg;
  /* 起跑握手：喊"上来了"，等主线程点头——线程起跑本身用真同步点等待 */
  pthread_mutex_lock(&probe_w_lock);
  probe_w_up = 1;
  pthread_cond_signal(&probe_w_handoff);
  while (!probe_w_started) {
    pthread_cond_wait(&probe_w_go, &probe_w_lock);
  }
  pthread_mutex_unlock(&probe_w_lock);
  /* 真投递：worker 线程直接调 MoonBit 闭包（分配压力之后的活体检查） */
  if (probe_w_fn != 0 && probe_w_data != 0) {
    probe_w_fn(probe_w_data);
  }
  /* 跨线程回收探针：worker 退场前回收它自己那份引用（reclaims=1 时） */
  if (probe_w_reclaims && probe_w_data != 0) {
    moonbit_decref(probe_w_data);
    probe_w_data = 0;
    probe_w_fn = 0;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_worker_arm(probe_void_cb call_closure, void *closure,
                                 int32_t worker_reclaims) {
  if (probe_w_created) {
    return -1;
  }
  probe_w_fn = call_closure;
  probe_w_data = closure;
  probe_w_reclaims = (int)worker_reclaims;
  if (closure != 0) {
    /* C 侧长期持有，必须 incref，否则 GC 会回收闭包 */
    moonbit_incref(closure);
  }
  pthread_mutex_lock(&probe_w_lock);
  probe_w_started = 0;
  probe_w_up = 0;
  pthread_mutex_unlock(&probe_w_lock);
  if (pthread_create(&probe_w_thread, 0, probe_w_worker, 0) != 0) {
    return -2;
  }
  probe_w_created = 1;
  /* 等起跑握手的另一半：真同步点，不 sleep */
  pthread_mutex_lock(&probe_w_lock);
  while (!probe_w_up) {
    pthread_cond_wait(&probe_w_handoff, &probe_w_lock);
  }
  pthread_mutex_unlock(&probe_w_lock);
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_probe_worker_go(void) {
  pthread_mutex_lock(&probe_w_lock);
  probe_w_started = 1;
  pthread_cond_signal(&probe_w_go);
  pthread_mutex_unlock(&probe_w_lock);
  void *rc = 0;
  pthread_join(probe_w_thread, &rc);
  probe_w_created = 0;
  return 0;
}

#endif

MOONBIT_FFI_EXPORT
void moonbit_probe_worker_clear(void) {
  if (probe_w_data != 0) {
    moonbit_decref(probe_w_data);
    probe_w_data = 0;
  }
  probe_w_fn = 0;
}
