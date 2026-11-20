/* =========================================================================
 * MoonUI 原生后端 · Linux / GTK4 · 全局热键（GlobalShortcuts portal）——T308。
 *
 * 本文件被 adapter_native_gtk.c 用 #include 收进**同一个翻译单元**（能看见
 * 那边的 static 状态与 prelude 的纯逻辑帮手，也不新增 prebuild 编译单元）。
 * 生成器扫描本文件里非 static 的 moonui_* 定义并从桩里剔除。
 *
 * 契约在 adapter.h 的「媒体键与全局热键」段（T181），本片接三条：
 *   hotkeys_set(fn, closure)  装全局热键回调（0 / -2 未初始化 / -3 portal 不可用）
 *   hotkey_probe(code)        探针：直接调已装回调（0 / -1 未装）
 *   hotkey_probe_id(id)       探针：走「注册号→命令码」映射表再调（0 / -1）
 * 命令码与 mac 半 Carbon RegisterEventHotKey 共用一张：0 播放暂停 / 1 下一首 /
 * 2 上一首；注册号 0(Space)→0、1(Left)→2、2(Right)→1（mac hotkey_handler 的 switch）。
 *
 * 为什么是 portal 而不是 XGrabKey：Wayland 客户端不能像 X11 那样全局抓键
 * （compositor 独占输入），正路是 xdg-desktop-portal 的 GlobalShortcuts 接口
 * （GNOME 48+ / KDE 实现）。零新依赖：GDBus 住在 gio-2.0，gtk4 已链。
 *
 * 协议（本机 GNOME 51.1 / xdg-desktop-portal 1.22.1 实测，接口 version 2）：
 *   ① CreateSession(options{handle_token, session_handle_token}) → Request 路径；
 *      会话句柄经该 Request 的 Response(u, a{sv}) 信号回来（results.session_handle）。
 *      **session_handle_token 必给**——portal 1.22 缺它会断言崩溃（xdp-session.c:296
 *      session->token != NULL），不是回错误码，是把整只 portal 服务打崩。
 *   ② BindShortcuts(session, a(sa{sv}) shortcuts, parent_window, options{handle_token})
 *      → Request 路径；**这一步弹用户授权对话框**，用户同意/改键后 Response(0) 才算绑上。
 *   ③ Activated(session, shortcut_id, timestamp, options) 信号：用户按下绑定的快捷键。
 *   ④ Session.Close：terminate 关会话，portal 释放快捷键。
 *
 * 异步武装语义（owner 拍板，与 mac 静默注册不同，写进契约）：hotkeys_set 同步发
 * CreateSession 验 portal 可用性（不在 → -3，不谎报装上），随后立即返 0 =「已请求」，
 * **不代表已生效**——BindShortcuts 的用户授权对话框同意后快捷键才真 firing。
 * probe / probe_id 不依赖 portal，本地直接回流命令码（验「装得上、码能回来」）。
 *
 * 线程纪律（T85①，与 mac handler 投主队列、MPRIS 投 g_idle_add 同一条）：Activated
 * 信号 handler 本就在主循环线程派发，但仍经 g_idle_add 投一拍再调 MoonBit 闭包。
 * 闭包纪律：复用 prelude 的 moonui_closure_id_replace。terminate 经
 * moonui_gtk_hotkeys_clear_hook 收尾。
 *
 * 证据边界（写清楚，别把判据绿当「桌面上一定对」）：
 *   - CI 跑 xvfb，没有 portal → hotkeys_set 走 -3 那条，真授权流在 CI 上跑不了。
 *     判据只钉「portal 缺席 → -3」「probe/probe_id 本地回流」「纯逻辑映射表」。
 *   - 建会话往返已用独立 C 探针对着真 portal（GNOME 51.1）实测过：CreateSession →
 *     Response(0) → 取出 session_handle 全通。两处坑已修并钉进代码注释：
 *       · CreateSession 参数必须是元组 (a{sv})，裸 a{sv} 会被序列化成空体 ()，
 *         portal 回 InvalidArgs，call_sync 还把错误吞成 NULL/无 err（真机误判 -3）；
 *       · session_handle 在 a{sv} 里是 v(s)，g_variant_lookup("&o") 类型不符取不到，
 *         须 lookup_value(NULL) 拆 v 再 get_string。
 *   - BindShortcuts 会弹对话框，自动化判据**不**真发它（不能在用户桌面上弹窗），
 *     真授权 + 真按快捷键的回流留 Linux 真机人工复验（linux-real-check.sh 清单 E 项）。
 *   - 用户取消授权（Response≠0）时快捷键不 firing，但 probe 仍可验码回流；
 *     会话仍在，不重试绑定（再装一次 hotkeys_set 只换回调，不重弹对话框）。
 * ========================================================================= */

#ifndef MOONUI_MOCK_GTK /* 假头不带 gio 的 GDBus，见 mock-gtk-check.sh */
#include <gio/gio.h>
#endif

/* ---- 状态（进程级单槽，与 mac 半 hotkey_fn / hotkey_closure 同形）---- */
static moonui_closure_id_fn moonui_hotkey_fn = 0;
static void *moonui_hotkey_closure = 0;
static GDBusConnection *moonui_hotkey_conn = 0;   /* g_bus_get_sync 给的，我们持一份 */
static char *moonui_hotkey_session = 0;           /* 会话对象路径（Response 给的） */
static char *moonui_hotkey_pending_req = 0;       /* 当前待响应的 Request 路径 */
static guint moonui_hotkey_req_sub = 0;           /* Request.Response 订阅 */
static guint moonui_hotkey_activated_sub = 0;     /* Activated 订阅（arg0 过滤本会话） */
static int moonui_hotkey_stage = 0;               /* 0 idle / 1 建会话 / 2 绑定 / 3 已绑 */
static int moonui_hotkey_token = 0;               /* handle_token 计数器，防路径撞 */

#define MOONUI_PORTAL_DEST "org.freedesktop.portal.Desktop"
#define MOONUI_PORTAL_PATH "/org/freedesktop/portal/desktop"
#define MOONUI_GS_IFACE "org.freedesktop.portal.GlobalShortcuts"
#define MOONUI_REQ_IFACE "org.freedesktop.portal.Request"
#define MOONUI_SESS_IFACE "org.freedesktop.portal.Session"

/* ---- 投主循环再调闭包（T85①）---- */
typedef struct MoonuiHotkeyEvent {
  int code;
} MoonuiHotkeyEvent;

static gboolean moonui_hotkey_dispatch_idle(gpointer data) {
  MoonuiHotkeyEvent *ev = (MoonuiHotkeyEvent *)data;
  moonui_closure_id_fn fn = moonui_hotkey_fn;
  void *cl = moonui_hotkey_closure;
  /* 读到的是**当下**的闭包：terminate 若已松掉，fn/cl 为 0，跳过即可。 */
  if (fn != 0 && cl != 0) {
    fn(cl, ev->code);
  }
  g_free(ev);
  return G_SOURCE_REMOVE;
}

static void moonui_hotkey_dispatch(int code) {
  MoonuiHotkeyEvent *ev;
  if (moonui_hotkey_fn == 0 || moonui_hotkey_closure == 0) {
    return;
  }
  ev = g_new0(MoonuiHotkeyEvent, 1);
  ev->code = code;
  g_idle_add(moonui_hotkey_dispatch_idle, ev);
}

/* ---- Activated：用户按下绑定的快捷键 ---- */
static void moonui_hotkey_on_activated(GDBusConnection *conn,
                                       const gchar *sender,
                                       const gchar *path,
                                       const gchar *iface,
                                       const gchar *signal,
                                       GVariant *params,
                                       gpointer user_data) {
  const gchar *sid = NULL;
  int idx;
  (void)conn; (void)sender; (void)path; (void)iface; (void)signal; (void)user_data;
  /* params: (o session_handle, s shortcut_id, t timestamp, a{sv} options) */
  g_variant_get(params, "(&o&s&t@a{sv})", NULL, &sid, NULL, NULL);
  idx = moonui_hotkey_idx_of_shortcut(sid);
  if (idx >= 0) {
    moonui_hotkey_dispatch(moonui_hotkey_id_to_code(idx));
  }
}

/* ---- BindShortcuts 的异步回调：拿到 Request 路径，等 Response ---- */
static void moonui_hotkey_bind_cb(GObject *src, GAsyncResult *res,
                                  gpointer user_data) {
  GVariant *ret = NULL;
  GError *err = NULL;
  (void)user_data;
  ret = g_dbus_connection_call_finish(G_DBUS_CONNECTION(src), res, &err);
  if (err != NULL) {
    g_error_free(err);
    moonui_hotkey_stage = 0;
    return;
  }
  if (ret != NULL) {
    const gchar *req = NULL;
    g_variant_get(ret, "(&o)", &req);
    g_free(moonui_hotkey_pending_req);
    moonui_hotkey_pending_req = g_strdup(req);
    g_variant_unref(ret);
  }
}

/* ---- 发起 BindShortcuts（弹用户授权对话框；异步，不阻塞主循环）---- */
static void moonui_hotkey_bind(void) {
  GVariantBuilder shortcuts, opts, params;
  GVariant *sc, *op, *args;
  char tok[64];
  int i;
  moonui_hotkey_stage = 2;
  moonui_hotkey_token += 1;
  snprintf(tok, sizeof(tok), "moonui_hk_bind_%d", moonui_hotkey_token);
  /* shortcuts: a(sa{sv})，三条 (id, {description, preferred-trigger})。
   * id 用 "moonui-<idx>"，Activated 回来时按 idx 走 id_to_code 映射表。 */
  g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
  for (i = 0; i < 3; ++i) {
    char id[16];
    GVariantBuilder one;
    GVariant *onev;
    snprintf(id, sizeof(id), "moonui-%d", i);
    g_variant_builder_init(&one, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&one, "{sv}", "description",
                          g_variant_new_string(moonui_hotkey_desc(i)));
    g_variant_builder_add(&one, "{sv}", "preferred-trigger",
                          g_variant_new_string(moonui_hotkey_trigger(i)));
    /* 先 end 成 GVariant 再以 "(s@a{sv})" 加入：格式里裸 "a{sv}" 让 GLib 期望
     * 一个 GVariantBuilder*，嵌在元组格式里会错乱地把外层 shortcuts builder 判
     * 成 invalid（builder_end 返 NULL → g_variant_new 拿 null 数组 abort，真机
     * 启动即崩）。"@a{sv}" 收已构建的 GVariant*，是嵌套容器的正路（/tmp 探针实证）。 */
    onev = g_variant_builder_end(&one);
    g_variant_builder_add(&shortcuts, "(s@a{sv})", id, onev);
  }
  sc = g_variant_builder_end(&shortcuts);
  g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&opts, "{sv}", "handle_token", g_variant_new_string(tok));
  op = g_variant_builder_end(&opts);
  /* params: (o session, a(sa{sv}) shortcuts, s parent_window, a{sv} options)。
   * 用 builder 拼整条，避免 g_variant_new 对嵌套数组的格式歧义。容器参数同样
   * 用 "@" 前缀收已构建的 GVariant*（sc / op），不用裸数组格式（同上一课）。 */
  g_variant_builder_init(&params, G_VARIANT_TYPE("(oa(sa{sv})sa{sv})"));
  g_variant_builder_add(&params, "o", moonui_hotkey_session);
  g_variant_builder_add(&params, "@a(sa{sv})", sc);
  g_variant_builder_add(&params, "s", "");
  g_variant_builder_add(&params, "@a{sv}", op);
  args = g_variant_builder_end(&params);
  g_dbus_connection_call(moonui_hotkey_conn, MOONUI_PORTAL_DEST, MOONUI_PORTAL_PATH,
                         MOONUI_GS_IFACE, "BindShortcuts", args,
                         G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, NULL,
                         moonui_hotkey_bind_cb, NULL);
}

/* ---- Request.Response：建会话 / 绑定两步都经它（按 pending_req 路径过滤）---- */
static void moonui_hotkey_on_response(GDBusConnection *conn,
                                      const gchar *sender,
                                      const gchar *path,
                                      const gchar *iface,
                                      const gchar *signal,
                                      GVariant *params,
                                      gpointer user_data) {
  guint32 response = 1;
  GVariant *results = NULL;
  (void)conn; (void)sender; (void)iface; (void)signal; (void)user_data;
  if (moonui_hotkey_pending_req == NULL ||
      g_strcmp0(path, moonui_hotkey_pending_req) != 0) {
    return;
  }
  /* params: (u response, a{sv} results) */
  g_variant_get(params, "(u@a{sv})", &response, &results);
  if (moonui_hotkey_stage == 1) {
    /* CreateSession 的响应：results.session_handle 是会话对象路径。
     * 它在 a{sv} 里是 v(s)——portal 发的是字符串 s 而非对象路径 o，故
     * g_variant_lookup("&o") 类型不符取不到。用 lookup_value(NULL) 自动拆 v
     * 拿内层值，再 get_string（s/o 都吃得）。 */
    if (response == 0 && results != NULL) {
      GVariant *sess_val = g_variant_lookup_value(results, "session_handle", NULL);
      if (sess_val != NULL) {
        const gchar *sess = g_variant_get_string(sess_val, NULL);
        if (sess != NULL) {
          moonui_hotkey_session = g_strdup(sess);
          /* 订阅 Activated，arg0 过滤本会话（只收我们这条会话的快捷键）。 */
          moonui_hotkey_activated_sub = g_dbus_connection_signal_subscribe(
              moonui_hotkey_conn, MOONUI_PORTAL_DEST, MOONUI_GS_IFACE, "Activated",
              NULL, moonui_hotkey_session, G_DBUS_SIGNAL_FLAGS_NONE,
              moonui_hotkey_on_activated, NULL, NULL);
          moonui_hotkey_bind();
        }
        g_variant_unref(sess_val);
      }
    }
    if (moonui_hotkey_session == NULL) {
      /* 建会话失败：复位。hotkeys_set 早已返 0，这条路静默不通（证据边界）。 */
      moonui_hotkey_stage = 0;
    }
  } else if (moonui_hotkey_stage == 2) {
    /* 绑定响应：0 = 用户授权成功；非 0 = 取消，快捷键不 firing（probe 仍可验）。 */
    moonui_hotkey_stage = (response == 0) ? 3 : 0;
  }
  if (results != NULL) {
    g_variant_unref(results);
  }
  g_free(moonui_hotkey_pending_req);
  moonui_hotkey_pending_req = NULL;
}

/* ---- 收尾（terminate 经钩子调）---- */
static void moonui_hotkey_clear(void) {
  if (moonui_hotkey_conn != NULL) {
    if (moonui_hotkey_req_sub != 0) {
      g_dbus_connection_signal_unsubscribe(moonui_hotkey_conn,
                                           moonui_hotkey_req_sub);
      moonui_hotkey_req_sub = 0;
    }
    if (moonui_hotkey_activated_sub != 0) {
      g_dbus_connection_signal_unsubscribe(moonui_hotkey_conn,
                                           moonui_hotkey_activated_sub);
      moonui_hotkey_activated_sub = 0;
    }
    if (moonui_hotkey_session != NULL) {
      /* 关会话（异步，不阻塞 terminate）：portal 释放绑定的快捷键。 */
      g_dbus_connection_call(moonui_hotkey_conn, MOONUI_PORTAL_DEST,
                             moonui_hotkey_session, MOONUI_SESS_IFACE, "Close",
                             NULL, NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL,
                             NULL);
    }
    g_object_unref(moonui_hotkey_conn);
    moonui_hotkey_conn = NULL;
  }
  g_free(moonui_hotkey_session);
  moonui_hotkey_session = NULL;
  g_free(moonui_hotkey_pending_req);
  moonui_hotkey_pending_req = NULL;
  if (moonui_hotkey_closure != 0) {
    moonbit_decref(moonui_hotkey_closure);
    moonui_hotkey_closure = 0;
  }
  moonui_hotkey_fn = 0;
  moonui_hotkey_stage = 0;
  moonui_hotkey_token = 0;
  moonui_gtk_hotkeys_clear_hook = NULL;
}

/* ---- 三条 ABI ---- */
int moonui_native_hotkeys_set(moonui_closure_id_fn fn, void *closure) {
  GError *err = NULL;
  GVariant *ret = NULL;
  GVariantBuilder opts;
  char sess_tok[64], req_tok[64];
  const gchar *req = NULL;
  if (!moonui_inited) {
    return -2;
  }
  moonui_closure_id_replace(&moonui_hotkey_fn, &moonui_hotkey_closure, fn, closure);
  /* 无论 portal 成败，terminate 都要松这份闭包：钩子先挂上。portal 缺席返 -3 时
   * 闭包已装（probe / probe_id 仍可验码回流），但 stage 留 0、不挂会话，terminate
   * 经钩子只松闭包——不泄引用（与 MPRIS「收下回调、总线另算」同一口径）。 */
  moonui_gtk_hotkeys_clear_hook = moonui_hotkey_clear;
  if (moonui_hotkey_stage != 0) {
    return 0; /* 已武装：只换回调，不重弹对话框（mac 半重复调用同口径）。 */
  }
  moonui_hotkey_conn = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
  if (err != NULL || moonui_hotkey_conn == NULL) {
    if (err != NULL) g_error_free(err);
    return -3; /* 无会话总线 / portal 不可用：诚实报缺席，不谎报装上。 */
  }
  /* 先订阅 Request.Response（按 pending_req 路径过滤），再发 CreateSession，
   * 免得响应先到、订阅在后漏掉。 */
  moonui_hotkey_req_sub = g_dbus_connection_signal_subscribe(
      moonui_hotkey_conn, MOONUI_PORTAL_DEST, MOONUI_REQ_IFACE, "Response",
      NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE, moonui_hotkey_on_response, NULL, NULL);
  moonui_hotkey_token += 1;
  snprintf(sess_tok, sizeof(sess_tok), "moonui_hk_sess_%d", moonui_hotkey_token);
  snprintf(req_tok, sizeof(req_tok), "moonui_hk_req_%d", moonui_hotkey_token);
  g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&opts, "{sv}", "handle_token",
                        g_variant_new_string(req_tok));
  g_variant_builder_add(&opts, "{sv}", "session_handle_token",
                        g_variant_new_string(sess_tok));
  /* CreateSession 同步发：portal 不在（xvfb / 非 GNOME）这里就报错 → -3。
   * session_handle_token 必给——portal 1.22 缺它会断言崩溃（见头注）。
   * 参数必须是元组 (a{sv})，不能是裸 a{sv}：裸字典会被序列化成空体 ()，portal
   * 回 InvalidArgs，而 call_sync 把这条错误吞成 NULL/无 err——真机上会误判 -3。
   * 用 g_variant_new_tuple 包一层（BindShortcuts 的 builder 本就是元组，无此坑）。 */
  GVariant *dict = g_variant_builder_end(&opts);
  ret = g_dbus_connection_call_sync(moonui_hotkey_conn, MOONUI_PORTAL_DEST,
                                    MOONUI_PORTAL_PATH, MOONUI_GS_IFACE,
                                    "CreateSession", g_variant_new_tuple(&dict, 1),
                                    G_VARIANT_TYPE("(o)"),
                                    G_DBUS_CALL_FLAGS_NONE, -1, NULL, &err);
  if (err != NULL || ret == NULL) {
    if (err != NULL) g_error_free(err);
    g_dbus_connection_signal_unsubscribe(moonui_hotkey_conn, moonui_hotkey_req_sub);
    moonui_hotkey_req_sub = 0;
    g_object_unref(moonui_hotkey_conn);
    moonui_hotkey_conn = NULL;
    return -3;
  }
  g_variant_get(ret, "(&o)", &req);
  moonui_hotkey_pending_req = g_strdup(req);
  g_variant_unref(ret);
  moonui_hotkey_stage = 1;
  return 0; /* 异步武装：会话已请求，绑定授权后才 firing（证据边界见头注）。 */
}

int moonui_native_hotkey_probe(int code) {
  if (moonui_hotkey_fn == 0 || moonui_hotkey_closure == 0) {
    return -1;
  }
  moonui_hotkey_dispatch(code);
  return 0;
}

/* 探针第二枚：走「注册号→命令码」映射表（与 mac 半 probe_id 灌 handler 同义），
 * 钉的是 id_to_code 那张表，probe 直灌命令码够不着它。 */
int moonui_native_hotkey_probe_id(int id) {
  if (moonui_hotkey_fn == 0 || moonui_hotkey_closure == 0) {
    return -1;
  }
  moonui_hotkey_dispatch(moonui_hotkey_id_to_code(id));
  return 0;
}