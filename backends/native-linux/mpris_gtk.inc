/* =========================================================================
 * MoonUI 原生后端 · Linux / GTK4 · MPRIS 媒体键与「正在播放」——T306。
 *
 * 本文件被 adapter_native_gtk.c 用 #include 收进**同一个翻译单元**（能看见
 * 那边的 static 状态与 prelude 的纯逻辑帮手，也不新增 prebuild 编译单元）。
 * 生成器扫描本文件里非 static 的 moonui_* 定义并从桩里剔除。
 *
 * 契约在 adapter.h 的「媒体键与全局热键」段（T181），本片接三条：
 *   media_keys_set(fn, closure)  装系统媒体键回调（0 / -2 未初始化）
 *   now_playing_set(...)         向系统「正在播放」推当前曲目（0 / -2）
 *   media_probe(code)            探针：直接调已装回调（0 / -1 未装）
 * hotkeys_set / hotkey_probe / hotkey_probe_id 仍显式缺席（-3 / -1）：Wayland
 * 全局热键要走 GlobalShortcuts portal（GNOME 48+），X11 grab 不可移植，另账。
 *
 * 为什么是 MPRIS 而不是另抓按键：Linux 桌面（GNOME / KDE）把耳机 / 键盘的
 * 媒体键**路由给注册了的 MPRIS 播放器**，所以只要占住 org.mpris.MediaPlayer2.*
 * 总线名、实现 Player 接口的 PlayPause / Next / Previous，媒体键自然到账——
 * 与 mac 半 MPRemoteCommandCenter 挂三条命令是同一件事的 Linux 形态。
 * now_playing_set 推的元数据则被桌面读去画顶栏 / 锁屏的媒体控件。
 *
 * 零新依赖：GDBus 住在 gio-2.0 里，而 pkg-config --libs gtk4 已经带 -lgio-2.0
 * （gtk4 依赖 gio），不引 libdbus、不动 prebuild 链接参数。
 *
 * 线程纪律（T85①，与 mac 半 handler 投主队列同一条）：GDBus 的方法 handler
 * 本就在主循环线程派发，但仍经 g_idle_add 投一拍再调 MoonBit 闭包——不在
 * D-Bus 调用帧里碰 MoonBit，方法调用立即返回空元组。
 *
 * 闭包纪律：复用 prelude 的 moonui_closure_id_replace（装时 incref、换 / 撤
 * decref，重复调用只换回调）。terminate 经 moonui_gtk_mpris_clear_hook 收尾。
 *
 * 证据边界（写清楚，别把判据绿当「桌面上一定对」）：
 *   - 无会话总线（headless / 沙箱）时 g_bus_own_name 异步失败，name_acquired
 *     永不来，但 media_keys_set 仍返 0（「收下」，与 mac「装得上」同口径），
 *     系统媒体键永不来；media_probe 仍可验「码能回流」。真跑判据自起一只私有
 *     dbus-daemon 把这条总线补上（canvas-pixel 闸 T306 组）。
 *   - 占名是异步的：media_keys_set 返回 0 只代表「发起占名」，不代表「已占住」。
 *     桌面真正看见播放器要等 name_acquired；判据泵主循环到 NameHasOwner 为真。
 *   - Position 报的是上一次 now_playing_set 推的 elapsed（契约：推送时机归
 *     MoonBit 侧，C 不自己走时钟）；桌面要连续进度条得靠 Rate + 时间戳外推，
 *     本片不实现 Seeked 的连续播报（lunamusic 按签名边沿推，够用）。
 *   - 真机上 GNOME 顶栏媒体控件的观感、真按媒体键的回流，仍要 Linux 真机人工
 *     复验（linux-real-check.sh 清单 T306 项），不在本闸。
 * ========================================================================= */

#ifndef MOONUI_MOCK_GTK /* 假头不带 gio 的 GDBus，见 mock-gtk-check.sh */
#include <gio/gio.h>
#endif

/* ---- 状态（进程级单槽，与 mac 半 media_fn / media_closure 同形）---- */
static moonui_closure_id_fn moonui_mpris_fn = 0;
static void *moonui_mpris_closure = 0;
static GDBusConnection *moonui_mpris_conn = 0;   /* bus_acquired 给的，我们 ref 一份 */
static guint moonui_mpris_owner_id = 0;          /* g_bus_own_name 的把手 */
static guint moonui_mpris_reg_ids[2] = {0, 0};   /* root + player 两个接口的注册 id */
static GDBusNodeInfo *moonui_mpris_node = 0;     /* introspection 解析结果 */
static GVariant *moonui_mpris_metadata = 0;      /* a{sv}，我们持一份引用 */
static int moonui_mpris_playing = 0;
static int moonui_mpris_has_track = 0;
static int64_t moonui_mpris_position_us = 0;
static int64_t moonui_mpris_track_counter = 0;
static char moonui_mpris_busname[160];

#define MOONUI_MPRIS_PATH "/org/mpris/MediaPlayer2"
#define MOONUI_MPRIS_IFACE "org.mpris.MediaPlayer2"
#define MOONUI_MPRIS_PLAYER_IFACE "org.mpris.MediaPlayer2.Player"

/* 标准 MPRIS2 introspection。字段按规范给全——GNOME shell 按这张表读属性，
 * 缺字段会让它把播放器当成不支持某能力。方法里只有 PlayPause / Next /
 * Previous 真派发，其余回 NOT_SUPPORTED（契约只有三命令，不猜第四档）。 */
static const char *moonui_mpris_xml =
  "<node>"
  "  <interface name='org.mpris.MediaPlayer2'>"
  "    <method name='Raise'/>"
  "    <method name='Quit'/>"
  "    <property name='CanQuit' type='b' access='read'/>"
  "    <property name='CanRaise' type='b' access='read'/>"
  "    <property name='HasTrackList' type='b' access='read'/>"
  "    <property name='Identity' type='s' access='read'/>"
  "    <property name='DesktopEntry' type='s' access='read'/>"
  "    <property name='SupportedUriSchemes' type='as' access='read'/>"
  "    <property name='SupportedMimeTypes' type='as' access='read'/>"
  "  </interface>"
  "  <interface name='org.mpris.MediaPlayer2.Player'>"
  "    <method name='Next'/>"
  "    <method name='Previous'/>"
  "    <method name='Pause'/>"
  "    <method name='PlayPause'/>"
  "    <method name='Stop'/>"
  "    <method name='Play'/>"
  "    <method name='Seek'>"
  "      <arg direction='in' name='Offset' type='x'/>"
  "    </method>"
  "    <method name='SetPosition'>"
  "      <arg direction='in' name='TrackId' type='o'/>"
  "      <arg direction='in' name='Position' type='x'/>"
  "    </method>"
  "    <method name='OpenUri'>"
  "      <arg direction='in' name='Uri' type='s'/>"
  "    </method>"
  "    <signal name='Seeked'>"
  "      <arg name='Position' type='x'/>"
  "    </signal>"
  "    <property name='PlaybackStatus' type='s' access='read'/>"
  "    <property name='LoopStatus' type='s' access='readwrite'/>"
  "    <property name='Rate' type='d' access='readwrite'/>"
  "    <property name='Shuffle' type='b' access='readwrite'/>"
  "    <property name='Metadata' type='a{sv}' access='read'/>"
  "    <property name='Volume' type='d' access='readwrite'/>"
  "    <property name='Position' type='x' access='read'/>"
  "    <property name='MinimumRate' type='d' access='read'/>"
  "    <property name='MaximumRate' type='d' access='read'/>"
  "    <property name='CanGoNext' type='b' access='read'/>"
  "    <property name='CanGoPrevious' type='b' access='read'/>"
  "    <property name='CanPlay' type='b' access='read'/>"
  "    <property name='CanPause' type='b' access='read'/>"
  "    <property name='CanSeek' type='b' access='read'/>"
  "    <property name='CanControl' type='b' access='read'/>"
  "  </interface>"
  "</node>";

/* ---- 投主循环再调闭包（T85①）---- */
typedef struct MoonuiMprisEvent {
  int code;
} MoonuiMprisEvent;

static gboolean moonui_mpris_dispatch_idle(gpointer data) {
  MoonuiMprisEvent *ev = (MoonuiMprisEvent *)data;
  moonui_closure_id_fn fn = moonui_mpris_fn;
  void *cl = moonui_mpris_closure;
  /* 读到的是**当下**的闭包：terminate 若已松掉，这里 fn/cl 为 0，跳过即可，
   * 不会调到已 decref 的对象（与 mac 半 block 里再核一遍同一课）。 */
  if (fn != 0 && cl != 0) {
    fn(cl, ev->code);
  }
  g_free(ev);
  return G_SOURCE_REMOVE;
}

static void moonui_mpris_dispatch(int code) {
  MoonuiMprisEvent *ev;
  if (moonui_mpris_fn == 0 || moonui_mpris_closure == 0) {
    return;
  }
  ev = g_new0(MoonuiMprisEvent, 1);
  ev->code = code;
  g_idle_add(moonui_mpris_dispatch_idle, ev);
}

/* ---- 属性读口（GDBus 的 Get / GetAll 都派到这里）---- */
static GVariant *moonui_mpris_get_property(GDBusConnection *conn,
                                           const gchar *sender,
                                           const gchar *path,
                                           const gchar *iface,
                                           const gchar *prop,
                                           GError **error,
                                           gpointer user_data) {
  (void)conn; (void)sender; (void)path; (void)user_data;
  if (g_strcmp0(iface, MOONUI_MPRIS_IFACE) == 0) {
    if (g_strcmp0(prop, "CanQuit") == 0) return g_variant_new_boolean(FALSE);
    if (g_strcmp0(prop, "CanRaise") == 0) return g_variant_new_boolean(FALSE);
    if (g_strcmp0(prop, "HasTrackList") == 0) return g_variant_new_boolean(FALSE);
    if (g_strcmp0(prop, "Identity") == 0) {
      const char *id = g_get_prgname();
      return g_variant_new_string(id != NULL && id[0] != '\0' ? id : "MoonUI");
    }
    if (g_strcmp0(prop, "DesktopEntry") == 0) return g_variant_new_string("");
    if (g_strcmp0(prop, "SupportedUriSchemes") == 0 ||
        g_strcmp0(prop, "SupportedMimeTypes") == 0) {
      return g_variant_new_strv(NULL, 0);
    }
  } else if (g_strcmp0(iface, MOONUI_MPRIS_PLAYER_IFACE) == 0) {
    int can = (moonui_mpris_fn != 0 && moonui_mpris_closure != 0);
    if (g_strcmp0(prop, "PlaybackStatus") == 0) {
      return g_variant_new_string(
          moonui_mpris_status(moonui_mpris_playing, moonui_mpris_has_track));
    }
    if (g_strcmp0(prop, "Metadata") == 0) {
      if (moonui_mpris_metadata != NULL) {
        return g_variant_ref(moonui_mpris_metadata);
      }
      return g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0);
    }
    if (g_strcmp0(prop, "Position") == 0) {
      return g_variant_new_int64(moonui_mpris_position_us);
    }
    if (g_strcmp0(prop, "Rate") == 0) {
      return g_variant_new_double(moonui_mpris_playing ? 1.0 : 0.0);
    }
    if (g_strcmp0(prop, "Volume") == 0) return g_variant_new_double(1.0);
    if (g_strcmp0(prop, "LoopStatus") == 0) return g_variant_new_string("None");
    if (g_strcmp0(prop, "Shuffle") == 0) return g_variant_new_boolean(FALSE);
    if (g_strcmp0(prop, "MinimumRate") == 0) return g_variant_new_double(1.0);
    if (g_strcmp0(prop, "MaximumRate") == 0) return g_variant_new_double(1.0);
    if (g_strcmp0(prop, "CanGoNext") == 0 ||
        g_strcmp0(prop, "CanGoPrevious") == 0 ||
        g_strcmp0(prop, "CanPlay") == 0 ||
        g_strcmp0(prop, "CanPause") == 0 ||
        g_strcmp0(prop, "CanControl") == 0) {
      return g_variant_new_boolean(can ? TRUE : FALSE);
    }
    if (g_strcmp0(prop, "CanSeek") == 0) return g_variant_new_boolean(FALSE);
  }
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
              "未知属性 %s.%s", iface, prop);
  return NULL;
}

/* 写口：LoopStatus / Rate / Shuffle / Volume 规范上是 readwrite，但本框架的
 * 播放控制只经媒体键三命令，不接受桌面反向写——一律回 NOT_SUPPORTED。 */
static gboolean moonui_mpris_set_property(GDBusConnection *conn,
                                          const gchar *sender,
                                          const gchar *path,
                                          const gchar *iface,
                                          const gchar *prop,
                                          GVariant *value,
                                          GError **error,
                                          gpointer user_data) {
  (void)conn; (void)sender; (void)path; (void)iface; (void)prop;
  (void)value; (void)user_data;
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_NOT_SUPPORTED,
              "MPRIS 属性只读（播放控制走媒体键三命令）");
  return FALSE;
}

/* ---- 方法派发 ---- */
static void moonui_mpris_method_call(GDBusConnection *conn,
                                     const gchar *sender,
                                     const gchar *path,
                                     const gchar *iface,
                                     const gchar *method,
                                     GVariant *params,
                                     GDBusMethodInvocation *invocation,
                                     gpointer user_data) {
  (void)conn; (void)sender; (void)path; (void)params; (void)user_data;
  if (g_strcmp0(iface, MOONUI_MPRIS_PLAYER_IFACE) == 0) {
    int code = moonui_mpris_method_code(method);
    if (code >= 0) {
      moonui_mpris_dispatch(code);
      g_dbus_method_invocation_return_value(invocation, NULL);
      return;
    }
    /* Play / Pause / Stop / Seek / SetPosition / OpenUri：契约只有三命令，
     * 如实报不支持，不拿 toggle 冒充（mac 半也只挂 toggle/next/prev）。 */
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_NOT_SUPPORTED,
                                          "方法 %s 不支持", method);
    return;
  }
  if (g_strcmp0(iface, MOONUI_MPRIS_IFACE) == 0 &&
      (g_strcmp0(method, "Raise") == 0 || g_strcmp0(method, "Quit") == 0)) {
    /* 框架不承诺 Raise/Quit 的窗口语义，收下但不做事（与 mac 半同口径）。 */
    g_dbus_method_invocation_return_value(invocation, NULL);
    return;
  }
  g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                        G_DBUS_ERROR_UNKNOWN_METHOD,
                                        "未知方法 %s.%s", iface, method);
}

static const GDBusInterfaceVTable moonui_mpris_vtable = {
  moonui_mpris_method_call,
  moonui_mpris_get_property,
  moonui_mpris_set_property,
  { NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL } /* padding[8] 显式置零 */
};

/* ---- PropertiesChanged：推完元数据告诉桌面「变了」（否则它不刷新）---- */
static void moonui_mpris_emit_changed(void) {
  GVariantBuilder top;
  GVariant *sig;
  if (moonui_mpris_conn == NULL) {
    return;
  }
  g_variant_builder_init(&top, G_VARIANT_TYPE("(sa{sv}as)"));
  g_variant_builder_add(&top, "s", MOONUI_MPRIS_PLAYER_IFACE);
  g_variant_builder_open(&top, G_VARIANT_TYPE("a{sv}"));
  /* builder_add 会 ref_sink 收一份引用转给父变体，所以这里直接交存储指针即可：
   * 再 g_variant_ref 会每次发信号漏一份引用（/tmp 探针实证：直接交配平，多 ref
   * 漏 1）。读口 get_property 相反——GDBus 对返回值减一份引用，那边才要 ref。 */
  g_variant_builder_add(&top, "{sv}", "Metadata",
                        moonui_mpris_metadata != NULL
                            ? moonui_mpris_metadata
                            : g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0));
  g_variant_builder_add(&top, "{sv}", "PlaybackStatus",
                        g_variant_new_string(moonui_mpris_status(
                            moonui_mpris_playing, moonui_mpris_has_track)));
  g_variant_builder_add(&top, "{sv}", "Rate",
                        g_variant_new_double(moonui_mpris_playing ? 1.0 : 0.0));
  g_variant_builder_close(&top);
  g_variant_builder_open(&top, G_VARIANT_TYPE("as")); /* invalidated：空 */
  g_variant_builder_close(&top);
  sig = g_variant_builder_end(&top);
  g_dbus_connection_emit_signal(moonui_mpris_conn, NULL, MOONUI_MPRIS_PATH,
                                "org.freedesktop.DBus.Properties",
                                "PropertiesChanged", sig, NULL);
}

/* ---- 占名 / 注册对象 ---- */
static void moonui_mpris_on_bus_acquired(GDBusConnection *conn,
                                         const gchar *name,
                                         gpointer user_data) {
  GError *err = NULL;
  int i;
  (void)name; (void)user_data;
  moonui_mpris_conn = g_object_ref(conn);
  if (moonui_mpris_node == NULL) {
    return;
  }
  for (i = 0; i < 2 && moonui_mpris_node->interfaces[i] != NULL; ++i) {
    moonui_mpris_reg_ids[i] = g_dbus_connection_register_object(
        conn, MOONUI_MPRIS_PATH, moonui_mpris_node->interfaces[i],
        &moonui_mpris_vtable, NULL, NULL, &err);
    if (err != NULL) {
      g_error_free(err);
      err = NULL;
    }
  }
}

static void moonui_mpris_on_name_acquired(GDBusConnection *conn,
                                          const gchar *name,
                                          gpointer user_data) {
  (void)conn; (void)name; (void)user_data;
  /* 占住了。桌面此刻才看得见播放器；判据泵到 NameHasOwner 为真再发调用。 */
}

static void moonui_mpris_on_name_lost(GDBusConnection *conn,
                                      const gchar *name,
                                      gpointer user_data) {
  (void)conn; (void)name; (void)user_data;
  /* 没占住（无会话总线 / 名字被抢）：不报错往上抛——media_keys_set 早已返 0，
   * 系统媒体键这条路静默不通，media_probe 仍可验码回流（证据边界见头注）。 */
}

/* ---- 收尾（terminate 经钩子调）---- */
static void moonui_mpris_clear(void) {
  int i;
  if (moonui_mpris_conn != NULL) {
    for (i = 0; i < 2; ++i) {
      if (moonui_mpris_reg_ids[i] != 0) {
        g_dbus_connection_unregister_object(moonui_mpris_conn,
                                            moonui_mpris_reg_ids[i]);
        moonui_mpris_reg_ids[i] = 0;
      }
    }
  }
  if (moonui_mpris_owner_id != 0) {
    g_bus_unown_name(moonui_mpris_owner_id);
    moonui_mpris_owner_id = 0;
  }
  if (moonui_mpris_conn != NULL) {
    g_object_unref(moonui_mpris_conn);
    moonui_mpris_conn = NULL;
  }
  if (moonui_mpris_node != NULL) {
    g_dbus_node_info_unref(moonui_mpris_node);
    moonui_mpris_node = NULL;
  }
  if (moonui_mpris_metadata != NULL) {
    g_variant_unref(moonui_mpris_metadata);
    moonui_mpris_metadata = NULL;
  }
  if (moonui_mpris_closure != 0) {
    moonbit_decref(moonui_mpris_closure);
    moonui_mpris_closure = 0;
  }
  moonui_mpris_fn = 0;
  moonui_mpris_playing = 0;
  moonui_mpris_has_track = 0;
  moonui_mpris_position_us = 0;
  moonui_mpris_track_counter = 0;
  moonui_gtk_mpris_clear_hook = NULL;
}

/* ---- 三条 ABI ---- */
int moonui_native_media_keys_set(moonui_closure_id_fn fn, void *closure) {
  if (!moonui_inited) {
    return -2;
  }
  moonui_closure_id_replace(&moonui_mpris_fn, &moonui_mpris_closure, fn, closure);
  if (moonui_mpris_owner_id == 0) {
    GError *err = NULL;
    moonui_mpris_bus_name(g_get_prgname(), moonui_mpris_busname,
                          sizeof(moonui_mpris_busname));
    moonui_mpris_node = g_dbus_node_info_new_for_xml(moonui_mpris_xml, &err);
    if (err != NULL) {
      g_error_free(err);
      return -3;
    }
    moonui_mpris_owner_id = g_bus_own_name(
        G_BUS_TYPE_SESSION, moonui_mpris_busname, G_BUS_NAME_OWNER_FLAGS_NONE,
        moonui_mpris_on_bus_acquired, moonui_mpris_on_name_acquired,
        moonui_mpris_on_name_lost, NULL, NULL);
    moonui_gtk_mpris_clear_hook = moonui_mpris_clear;
  }
  return 0;
}

int moonui_native_now_playing_set(const char *title, int title_len,
                                  const char *artist, int artist_len,
                                  int64_t elapsed_ms, int64_t duration_ms,
                                  int playing) {
  GVariantBuilder b;
  GVariant *meta;
  char *t;
  char *a;
  int has;
  if (!moonui_inited) {
    return -2;
  }
  t = moonui_dup(title, title_len);
  a = moonui_dup(artist, artist_len);
  has = (t != NULL && t[0] != '\0');
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  if (has) {
    char trackid[96];
    moonui_mpris_track_counter += 1;
    moonui_mpris_trackid(trackid, sizeof(trackid), moonui_mpris_track_counter);
    g_variant_builder_add(&b, "{sv}", "mpris:trackid",
                          g_variant_new_object_path(trackid));
    g_variant_builder_add(&b, "{sv}", "xesam:title", g_variant_new_string(t));
    if (a != NULL && a[0] != '\0') {
      const char *arr[1];
      arr[0] = a;
      g_variant_builder_add(&b, "{sv}", "xesam:artist",
                            g_variant_new_strv(arr, 1));
    }
    if (duration_ms > 0) {
      g_variant_builder_add(&b, "{sv}", "mpris:length",
                            g_variant_new_int64(moonui_mpris_us(duration_ms)));
    }
  }
  meta = g_variant_builder_end(&b);
  if (moonui_mpris_metadata != NULL) {
    g_variant_unref(moonui_mpris_metadata);
  }
  moonui_mpris_metadata = g_variant_ref_sink(meta);
  moonui_mpris_playing = playing ? 1 : 0;
  moonui_mpris_has_track = has;
  moonui_mpris_position_us = moonui_mpris_us(elapsed_ms);
  if (t != NULL) free(t);
  if (a != NULL) free(a);
  moonui_mpris_emit_changed();
  return 0;
}

int moonui_native_media_probe(int code) {
  if (moonui_mpris_fn == 0) {
    return -1;
  }
  moonui_mpris_dispatch(code);
  return 0;
}