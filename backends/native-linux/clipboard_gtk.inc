/*
 * MoonUI 原生后端 · Linux / GTK4 · 剪贴板——T235 P6-2。
 *
 * 本文件被 adapter_native_gtk.c 用 #include 收进**同一个翻译单元**（所以能看见
 * 那边的 static 状态，也不新增 prebuild 的编译单元）。生成器扫描本文件里定义的
 * moonui_* 符号并从"桩"里剔除，两边不会重定义。
 *
 * 契约在 adapter.h 的剪贴板段（§23 / §48-19），两条 ABI：
 *
 *   读 moonui_native_clipboard_text()  → bytes；空 bytes = 现在没有文本（没有
 *        错误码，"打不开"与"空着"对调用方是同一个回答）
 *   写 moonui_native_clipboard_set_text() → 0 成功 / -1 拿不到剪贴板 /
 *        -2 拿住了但没写进去
 *
 * 与 mac（NSPasteboard）和 Windows（OpenClipboard）最大的不同：**GTK4 的剪贴板
 * 读是异步的**。`gdk_clipboard_read_text_async` 交出去之后要等回调，而这份 ABI
 * 是同步返回。所以这里在 C 里开一个临时 `GMainLoop`，泵到回调到账或超时为止
 * （上限 `MOONUI_CLIPBOARD_WAIT_MS`）。
 *
 * 为什么用临时 GMainLoop 而不是手泵 `g_main_context_iteration(TRUE)`：手泵要自己
 * 算 timeout 再 clamp，还要判断"当前没有待处理事件"以免永久阻塞；GMainLoop 加一个
 * timeout 源把这两件事都挂上去，退出条件只有一个（谁先到谁 quit）。
 *
 * 这是**嵌套主循环**：如果调用点本身正在主循环派发里（比如某颗按键回调里读剪贴
 * 板），这里会重入派发。GTK 自己的 `gtk_dialog_run` 是同一形状，安全；本适配器
 * 也没有跨调用的可变全局状态会被它撕开（鼠标那三个 ptr 是只写快照）。
 *
 * 超时按"没有文本"处理，不是当作错误往上报——读路径没有错误通道，往上报也无处
 * 可去；给应用的回答就是"现在读不到文本"。
 *
 * 位图/富文本一律不认（ABI 只有文本这一形）。
 */

#ifndef MOONUI_MOCK_GTK /* 假头（scripts/mock-gtk.h）不带 gdk，见 mock-gtk-check.sh */
#include <gdk/gdk.h>
#endif

/* 等异步回调的上限。mac / Win32 那两条都是同步 API，这里多出来的这个延迟是
 * GTK4 异步模型的代价；250ms 足够宽（本机实测回调在 1ms 内到账，Linux 上要过一次
 * selection owner 交接，实测也在几十毫秒内），又不至于让"剪贴板空着"卡住界面。 */
#define MOONUI_CLIPBOARD_WAIT_MS 250

typedef struct MoonuiClipWait {
  GMainLoop *loop;
  char *text;   /* read_text_finish 给的，调用方 g_free */
  int done;
  int timed_out;
  guint timeout_id;
} MoonuiClipWait;

/* 拿默认剪贴板。没有 display（没 GTK 后端 / 纯 headless）时返回 NULL，调用方按
 * 契约报 -1 或给空 bytes。 */
static GdkClipboard *moonui_gtk_clipboard(void) {
  GdkDisplay *d = gdk_display_get_default();
  if (d == NULL) {
    return NULL;
  }
  return gdk_display_get_clipboard(d);
}

static void moonui_gtk_on_clipboard_read(GObject *src, GAsyncResult *res,
                                         gpointer data) {
  MoonuiClipWait *w = (MoonuiClipWait *)data;
  GError *err = NULL;
  w->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(src), res, &err);
  if (err != NULL) {
    /* "剪贴板里没有文本"在这个 API 里也是一条 error；契约要求它与空着同答，
     * 所以这里只放掉、不外传。 */
    g_error_free(err);
  }
  w->done = 1;
  if (w->loop != NULL) {
    g_main_loop_quit(w->loop);
  }
}

static gboolean moonui_gtk_on_clipboard_timeout(gpointer data) {
  MoonuiClipWait *w = (MoonuiClipWait *)data;
  /* 源自己会销毁，把 id 清掉免得外面按 id 再删一次（那会打 critical）。 */
  w->timeout_id = 0;
  w->timed_out = 1;
  w->done = 1;
  if (w->loop != NULL) {
    g_main_loop_quit(w->loop);
  }
  return G_SOURCE_REMOVE;
}

moonbit_bytes_t moonui_native_clipboard_text(void) {
  GdkClipboard *cb = moonui_gtk_clipboard();
  MoonuiClipWait w;
  moonbit_bytes_t out;
  if (cb == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  memset(&w, 0, sizeof(w));
  w.loop = g_main_loop_new(NULL, FALSE);
  if (w.loop == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  w.timeout_id =
      g_timeout_add(MOONUI_CLIPBOARD_WAIT_MS, moonui_gtk_on_clipboard_timeout, &w);
  gdk_clipboard_read_text_async(cb, NULL, moonui_gtk_on_clipboard_read, &w);
  /* 回调有可能在 read_text_async 返回之前就到账（已完成的 future 走 idle
   * 派发，所以实际不会，但不靠这个假设）。done 已是 1 就别开主循环。 */
  if (!w.done) {
    g_main_loop_run(w.loop);
  }
  if (w.timeout_id != 0) {
    g_source_remove(w.timeout_id);
    w.timeout_id = 0;
  }
  g_main_loop_unref(w.loop);
  /* 超时 / 剪贴板里没有文本时 w.text 是 NULL，得先挡住再调 strlen 那一族。 */
  out = (w.text != NULL) ? moonui_bytes_of(w.text) : moonbit_make_bytes(0, 0);
  if (w.text != NULL) {
    g_free(w.text);
  }
  return out;
}

int moonui_native_clipboard_set_text(const char *text, int text_len) {
  GdkClipboard *cb;
  GdkContentProvider *provider;
  char *s;
  gboolean ok;
  if (text == NULL || text_len < 0) {
    return -2;
  }
  cb = moonui_gtk_clipboard();
  if (cb == NULL) {
    /* 与 mac 的 clearContents 返回 NO 同一档：这次拿不到剪贴板。 */
    return -1;
  }
  /* MoonBit 的 Bytes 不保证 NUL 结尾，G_TYPE_STRING 要 C 串，先拷一份。
   * 放掉时机在 set_content 之后——不依赖 provider 到底持不持有这份指针。 */
  s = (char *)g_malloc((gsize)text_len + 1);
  if (s == NULL) {
    return -2;
  }
  if (text_len > 0) {
    memcpy(s, text, (size_t)text_len);
  }
  s[text_len] = '\0';
  /* 不用 gdk_clipboard_set_text()：它返回 void，拿不到成败，而契约要求 0 / -2
   * 分开。gdk_content_provider_new_typed + gdk_clipboard_set_content 是它的底层
   * 形状，后者返回 gboolean。 */
  provider = gdk_content_provider_new_typed(G_TYPE_STRING, s);
  if (provider == NULL) {
    g_free(s);
    return -2;
  }
  ok = gdk_clipboard_set_content(cb, provider);
  g_object_unref(provider);
  g_free(s);
  return ok ? 0 : -2;
}
