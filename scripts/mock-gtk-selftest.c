/* T235 P3/P5/P6-1/P6-3：GTK4 适配器里**纯逻辑**那几块的本地自检（不碰 GTK 运行时）。
 *
 * 分组：①键名词表 ②pack2 / 修饰键 / 鼠标钮号 ③（P3 其余纯函数）④⑤…
 * ⑥音频"显式缺席"的码表（P5）⑦控件登记表 / 命中反查 / 层叠序号（P6-1，用一棵
 * 假 widget 树真跑）⑧对话框 response → 返回码（P6-3，决定"哪些应答算同意"）。
 * 这份文件由 scripts/mock-gtk-check.sh 追加到"把 <gtk/gtk.h> 换成 mock 头"
 * 的那份生成物末尾再编译运行——静态函数（moonui_key_name_store / moonui_pack2
 * / moonui_mods_of / moonui_map_button / moonui_held_button）因此在同一个翻译
 * 单元里可见。
 *
 * 为什么值得单独造这条：这些函数是 Linux 上**唯一能在 macOS 真跑出判据**的
 * 部分——它们不调 GTK，只用整数与字符串。键名词表尤其要紧：拼错一处，Linux
 * 上那类键就静默变成"没有事件"，而那要等用户在真机上按键才发现。mock-gtk.h
 * 里 GDK_*_MASK 的取值按真实 GDK 的位序摆，所以这里的位运算判据与 Linux 同义。
 *
 * 链接用 -Wl,-undefined,dynamic_lookup：moonbit 运行时那几个符号（
 * moonbit_make_bytes / incref / decref）与本文件不调用，留未定义即可，不必为
 * 自检去伪造运行时。
 */

#include <stdio.h>
#include <string.h>

/* mock 的 gdk_keyval_name：只认自检要用的那几个键码，其余回 "unknown"，用来
 * 验证"词表外的键留空串"。键码取真实 GDK 的数值，判据因此与 Linux 同义。 */
const char *gdk_keyval_name(guint keyval) {
  switch (keyval) {
    case 0xFF0D: return "Return";
    case 0xFF08: return "BackSpace";
    case 0xFF55: return "Page_Up";
    case 0xFF56: return "Page_Down";
    case 0x0020: return "space";
    case 0xFF09: return "Tab";
    case 0xFF1B: return "Escape";
    case 0xFFFF: return "Delete";
    case 0xFF51: return "Left";
    case 0xFF53: return "Right";
    case 0xFF52: return "Up";
    case 0xFF54: return "Down";
    case 0xFF50: return "Home";
    case 0xFF57: return "End";
    case 0xFFBE: return "F1";
    case 0xFFE1: return "Shift_L"; /* 修饰键自己：不在词表里 */
    case 0x0061: return "a";
    case 0x0041: return "A";       /* Shift+a 的 keyval：要折成 "a" */
    case 0x0031: return "1";
    default: return "unknown";
  }
}

static int g_fails = 0;
static int g_checks = 0;

/* 自检**不链接 moonbit 运行时**（见文件头：那几个符号留未定义），但第 6 组要调
 * 两条 bytes 出参的音频函数，它们内部会 `moonbit_make_bytes`。这里给一个够用的
 * 小实现：判据只看"非 NULL"与载荷前 8 字节，不关心分配器本身。跟上面
 * gdk_keyval_name 是同一招——补上"声明有、实现不在"的那个符号。 */
static unsigned char g_bytes_pool[64];
moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  if (size < 0) size = 0;
  if (size > (int32_t)sizeof(g_bytes_pool)) size = (int32_t)sizeof(g_bytes_pool);
  memset(g_bytes_pool, value, (size_t)size);
  return (moonbit_bytes_t)g_bytes_pool;
}

static void expect_str(const char *what, const char *got, const char *want) {
  ++g_checks;
  if (strcmp(got, want) != 0) {
    printf("  FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
    ++g_fails;
  }
}

static void expect_int(const char *what, long long got, long long want) {
  ++g_checks;
  if (got != want) {
    printf("  FAIL %s: got %lld, want %lld\n", what, got, want);
    ++g_fails;
  }
}

static void check_key_name(guint keyval, const char *want) {
  moonui_key_name_store(keyval);
  expect_str("key_name", moonui_key_name_buf, want);
}

/* ---- 假 GTK 控件树（T235 P6-1）----
 * 控件登记表 / 命中反查 / 层叠序号这三块是**纯指针逻辑**：只问"父是谁、下一个
 * 兄弟是谁、这个点命中谁"。所以给一份够用的假树就能在本机真跑判据——不碰 GTK
 * 运行时，也不需要窗口。补的是"声明有、实现不在"的那四个符号（与上面
 * gdk_keyval_name 同一招）。
 *
 * 假树**故意不模拟 GTK 的坐标/布局**：这几条判据验的是账（谁登记了、谁在里面、
 * 谁在上面），坐标换算要靠真机（P8）。 */
struct _GtkWidget {
  GtkWidget *parent;
  GtkWidget *first_child;
  GtkWidget *next_sibling;
  GtkWidget *pick; /* gtk_widget_pick 的结果：判据直接摆 */
};

GtkWidget *gtk_widget_get_parent(GtkWidget *w) {
  return w == NULL ? NULL : w->parent;
}
GtkWidget *gtk_widget_get_first_child(GtkWidget *w) {
  return w == NULL ? NULL : w->first_child;
}
GtkWidget *gtk_widget_get_next_sibling(GtkWidget *w) {
  return w == NULL ? NULL : w->next_sibling;
}
GtkWidget *gtk_widget_pick(GtkWidget *w, double x, double y, GtkPickFlags flags) {
  (void)x; (void)y; (void)flags;
  return w == NULL ? NULL : w->pick;
}

/* 挂成最后一个孩子（GtkFixed 的绘制顺序 = 子节点顺序 = 后来的在上）。 */
static void mock_add_child(GtkWidget *parent, GtkWidget *child) {
  GtkWidget *it;
  child->parent = parent;
  child->next_sibling = NULL;
  if (parent->first_child == NULL) {
    parent->first_child = child;
    return;
  }
  it = parent->first_child;
  while (it->next_sibling != NULL) it = it->next_sibling;
  it->next_sibling = child;
}

int main(void) {
  /* ---- 1. 键名词表：与 mac 的 moonui_native_key_name_of_code 逐字一致 ---- */
  check_key_name(0xFF0D, "Enter");     /* GTK 叫 Return，词表正本叫 Enter */
  check_key_name(0xFF08, "Backspace"); /* GTK 叫 BackSpace */
  check_key_name(0xFF55, "PageUp");    /* GTK 叫 Page_Up */
  check_key_name(0xFF56, "PageDown");  /* GTK 叫 Page_Down */
  check_key_name(0x0020, "Space");     /* GTK 叫 space */
  check_key_name(0xFF09, "Tab");
  check_key_name(0xFF1B, "Escape");
  check_key_name(0xFFFF, "Delete");    /* GTK 的 Delete 是"向后删"，词表同义 */
  check_key_name(0xFF51, "Left");
  check_key_name(0xFF53, "Right");
  check_key_name(0xFF52, "Up");
  check_key_name(0xFF54, "Down");
  check_key_name(0xFF50, "Home");
  check_key_name(0xFF57, "End");
  check_key_name(0xFFBE, "F1");
  check_key_name(0x0061, "a");
  check_key_name(0x0041, "a"); /* 大写折小写，Shift 由修饰键位表达 */
  check_key_name(0x0031, "1");
  /* 词表外：留空串 → 调用方不产事件（同 mac 的 notify 那一支） */
  check_key_name(0xFFE1, "");
  check_key_name(0x1234, "");

  /* ---- 2. pack2：高 32 位 a、低 32 位 b；负值也要确定（有符号左移是 UB） ---- */
  expect_int("pack2(1,2)", moonui_pack2(1, 2),
             (long long)(((uint64_t)1u << 32) | (uint64_t)2u));
  expect_int("pack2(-5,7)", moonui_pack2(-5, 7),
             (long long)(((uint64_t)0xFFFFFFFBu << 32) | (uint64_t)7u));
  expect_int("pack2(-1,-1)", moonui_pack2(-1, -1),
             (long long)(((uint64_t)0xFFFFFFFFu << 32) | (uint64_t)0xFFFFFFFFu));
  expect_int("pack2(0,0)", moonui_pack2(0, 0), 0);

  /* ---- 3. 修饰键位：ABI 是 bit0 ctrl / bit1 alt / bit2 shift / bit3 meta ---- */
  expect_int("mods(none)", moonui_mods_of((GdkModifierType)0), 0);
  expect_int("mods(ctrl)", moonui_mods_of(GDK_CONTROL_MASK), 1);
  expect_int("mods(alt)", moonui_mods_of(GDK_ALT_MASK), 2);
  expect_int("mods(shift)", moonui_mods_of(GDK_SHIFT_MASK), 4);
  expect_int("mods(super)", moonui_mods_of(GDK_SUPER_MASK), 8);
  expect_int("mods(shift+ctrl)",
             moonui_mods_of((GdkModifierType)(GDK_SHIFT_MASK | GDK_CONTROL_MASK)),
             5);
  /* 鼠标按键位不许串到修饰键里（GDK 的 BUTTON* 从 1<<8 起，两套不重叠） */
  expect_int("mods(button1 only)", moonui_mods_of(GDK_BUTTON1_MASK), 0);

  /* ---- 4. 鼠标钮号映射（ABI：0 Left / 1 Right / 2 Middle / 3 Extra1 / 4 Extra2）---- */
  expect_int("button(gtk 1)", moonui_map_button(1), 0);
  expect_int("button(gtk 2)", moonui_map_button(2), 2);
  expect_int("button(gtk 3)", moonui_map_button(3), 1);
  expect_int("button(gtk 8)", moonui_map_button(8), 3);
  expect_int("button(gtk 9)", moonui_map_button(9), 4);
  expect_int("button(gtk 4)", moonui_map_button(4), -1);
  expect_int("button(gtk 0)", moonui_map_button(0), -1);

  /* ---- 5. kind 2 的 button 位 = 按住哪颗在拖 ---- */
  expect_int("held(none)", moonui_held_button((GdkModifierType)0), 0);
  expect_int("held(left)", moonui_held_button(GDK_BUTTON1_MASK), 0);
  expect_int("held(right)", moonui_held_button(GDK_BUTTON3_MASK), 1);
  expect_int("held(middle)", moonui_held_button(GDK_BUTTON2_MASK), 2);

  /* ---- 6. 本平台未实现（T235 P5）：码必须是 adapter.h 的口径，不是中性桩的 0 ----
   *
   * 这一组验的是"不谎报"：中性桩 return 0，而 0 在 ABI 上多数是「成功」——音频
   * 那批返 0 会让应用壳以为歌装上了、播放器画得出来却永远不出声。所以逐条钉码。
   * 码表与 backends/native-windows/adapter_native.c 的音频段一致（同一契约）。 */
  expect_int("audio_load", moonui_native_audio_load("/x.mp3", 7), -3);
  expect_int("audio_play", moonui_native_audio_play(), -3);
  expect_int("audio_pause", moonui_native_audio_pause(), -3);
  expect_int("audio_stop", moonui_native_audio_stop(), -3);
  /* 位置/时长用 -1 表示"没有"（中性桩的 0 会被当成"播到了开头"） */
  expect_int("audio_position_ms", (long long)moonui_native_audio_position_ms(), -1);
  expect_int("audio_duration_ms", (long long)moonui_native_audio_duration_ms(), -1);
  expect_int("audio_seek_ms", moonui_native_audio_seek_ms(1000), -3);
  expect_int("audio_set_volume", moonui_native_audio_set_volume(500), -3);
  expect_int("audio_is_playing", moonui_native_audio_is_playing(), 0);
  /* 速率读回 1000（原速）：readback 不能用 0，那会被读成"停住了" */
  expect_int("audio_set_rate", moonui_native_audio_set_rate(1500), -3);
  expect_int("audio_rate", moonui_native_audio_rate(), 1000);
  expect_int("audio_on_finished", moonui_native_audio_on_finished(0, 0), -3);
  expect_int("audio_clear_on_finished", moonui_native_audio_clear_on_finished(), -3);
  expect_int("audio_prime", moonui_native_audio_prime("/x.mp3", 7), -3);
  expect_int("audio_prime_clear", moonui_native_audio_prime_clear(), -3);
  expect_int("audio_on_primed", moonui_native_audio_on_primed(0, 0), -3);
  expect_int("audio_clear_on_primed", moonui_native_audio_clear_on_primed(), -3);
  expect_int("audio_loudness_start", moonui_native_audio_loudness_start("/x.mp3", 7), -3);
  expect_int("audio_on_loudness", moonui_native_audio_on_loudness(0, 0), -3);
  expect_int("audio_clear_on_loudness", moonui_native_audio_clear_on_loudness(), -3);
  expect_int("audio_set_track_gain", moonui_native_audio_set_track_gain(300), 0);
  expect_int("audio_track_gain", moonui_native_audio_track_gain(), 0);
  /* EQ/频谱：读回 0 = 这侧没有，UI 据此不画假滑块 */
  expect_int("audio_level", moonui_native_audio_level(3), 0);
  expect_int("audio_eq_band_count", moonui_native_audio_eq_band_count(), 0);
  expect_int("audio_eq_set_band", moonui_native_audio_eq_set_band(0, 300), -3);
  expect_int("audio_eq_band_gain", moonui_native_audio_eq_band_gain(0), 0);
  expect_int("audio_eq_set_enabled", moonui_native_audio_eq_set_enabled(1), -3);
  expect_int("audio_eq_enabled", moonui_native_audio_eq_enabled(), 0);
  expect_int("audio_output_set", moonui_native_audio_output_set(1), -3);
  expect_int("media_keys_set", moonui_native_media_keys_set(0, 0), -3);
  expect_int("hotkeys_set", moonui_native_hotkeys_set(0, 0), -3);
  expect_int("now_playing_set",
             moonui_native_now_playing_set("t", 1, "a", 1, 0, 0, 1), -3);

  /* bytes 出参的两条必须给**空包**而不是 NULL：MoonBit 侧拿返回值直接 .length()，
   * NULL 会在那儿解引用空指针闪退（2026-10-16 选目录闪退案的修法，mac 同契约）。 */
  {
    unsigned char *out = (unsigned char *)moonui_native_audio_output_list();
    g_checks++;
    if (out == NULL) {
      printf("  FAIL audio_output_list: NULL（要空包）\n");
      ++g_fails;
    } else if (!(out[0] == 0 && out[1] == 0 && out[2] == 0 && out[3] == 0 &&
                 out[4] == 0xFF && out[5] == 0xFF && out[6] == 0xFF && out[7] == 0xFF)) {
      printf("  FAIL audio_output_list: 载荷不是 [count=0][current=-1]\n");
      ++g_fails;
    }
  }
  {
    unsigned char *probe = (unsigned char *)moonui_native_audio_probe("/x.mp3", 7);
    g_checks++;
    if (probe == NULL) {
      printf("  FAIL audio_probe: NULL（要空包）\n");
      ++g_fails;
    }
  }

  /* ---- 7. 控件挂载层的身份账（T235 P6-1，真跑）----
   * 三件事：kind 登记表（存 kind+1，0=空槽）、命中反查沿父链、层叠序号从尾数。
   * 全部是纯指针逻辑，所以在这一层能真跑出判据。 */
  {
    GtkWidget win, panel, custom, inner, nd_a, nd_b, label;

    memset(&win, 0, sizeof(win));
    memset(&panel, 0, sizeof(panel));
    memset(&custom, 0, sizeof(custom));
    memset(&inner, 0, sizeof(inner));
    memset(&nd_a, 0, sizeof(nd_a));
    memset(&nd_b, 0, sizeof(nd_b));
    memset(&label, 0, sizeof(label));

    /* kind 登记表：查得到的必须原值返回 */
    expect_int("wslot_alloc(Panel 17)", moonui_wslot_alloc(&panel, 17) != NULL, 1);
    expect_int("wslot_alloc(Custom 18)", moonui_wslot_alloc(&custom, 18) != NULL, 1);
    expect_int("kind_of(Panel)", moonui_widget_kind_of(&panel), 17);
    expect_int("kind_of(Custom)", moonui_widget_kind_of(&custom), 18);
    expect_int("kind_of(未登记控件)", moonui_widget_kind_of(&inner), -1);

    /* kind 0 是 Label：**不能**和"空槽"混成同一个值。
     * 这条正是"存 kind+1"的理由——如果直接存 kind，Label 会被读成没登记。 */
    expect_int("wslot_alloc(Label kind0)", moonui_wslot_alloc(&label, 0) != NULL, 1);
    expect_int("kind_of(Label)=0 不是空槽", moonui_widget_kind_of(&label), 0);
    moonui_wslot_free(&label);
    expect_int("kind_of(销账后)", moonui_widget_kind_of(&label), -1);
    expect_int("kind_of(销账只销自己)", moonui_widget_kind_of(&panel), 17);

    /* 命中反查：pick 命中的就是我们造的控件 → 报它自己 */
    mock_add_child(&win, &panel);
    mock_add_child(&panel, &inner);
    win.pick = &custom;
    expect_int("owner_at(命中 Custom)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == &custom, 1);
    /* 命中的是控件的内部分件（真实 GTK 里 pick 会落到这种节点上）→ 沿父链
     * 找到最近一个登记过的祖先。找不到就直接报内部分件会让 Core 拿到一个
     * 它不认识的句柄。 */
    win.pick = &inner;
    expect_int("owner_at(内部分件→父级 Panel)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == &panel, 1);
    /* 空白：pick 回到窗口自己（窗口不在控件登记表里）→ 0 */
    win.pick = &win;
    expect_int("owner_at(空白=窗口)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == NULL, 1);
    win.pick = NULL;
    expect_int("owner_at(pick=NULL)",
               (GtkWidget *)moonui_owner_at(&win, 1.0, 1.0) == NULL, 1);

    /* 层叠序号：GtkFixed 里后挂的画在上面，所以 0 = 最后一个孩子 */
    mock_add_child(&win, &nd_a);
    mock_add_child(&win, &nd_b); /* win 的子链：[panel, nd_a, nd_b] */
    expect_int("z_index(最后挂的)", moonui_widget_z_index(&nd_b), 0);
    expect_int("z_index(中间的)", moonui_widget_z_index(&nd_a), 1);
    expect_int("z_index(最先挂的)", moonui_widget_z_index(&panel), 2);
    expect_int("z_index(无父=-1)", moonui_widget_z_index(&custom), -1);
    expect_int("z_index(空指针=-1)", moonui_widget_z_index(NULL), -1);

    /* 容器判定：Panel 是容器（也是 GtkFixed），Custom 不是。
     * 这条钉的是"container_attach 只往 GtkFixed 里挂"那道闸。 */
    expect_int("is_container(Panel 17)", moonui_gtk_is_container(&panel), 1);
    expect_int("is_container(Custom 18)", moonui_gtk_is_container(&custom), 0);
    expect_int("is_container(NULL)", moonui_gtk_is_container(NULL), 0);

    /* 不是 window_new 造的窗口：一律不接管（如实 NULL → 调用方拿到 -1）。
     * 这条防的是"随便一个 GtkWidget 当窗口传进来就往上挂"的静默错挂。 */
    expect_int("window_overlay(非我们造的窗)",
               moonui_gtk_window_overlay(&win, 1) == NULL, 1);
    expect_int("window_fixed(非我们造的窗)",
               moonui_gtk_window_fixed(&win, 1) == NULL, 1);

    moonui_wslot_free(&panel);
    moonui_wslot_free(&custom);
  }

  /* ---- 8. 对话框的 response → ABI 返回码（T235 P6-3，纯映射、真跑）----
   * 这一段钉的是"哪些应答算同意"。它比看起来重要：confirm 的返回值直接决定应用
   * 会不会执行那个动作（删文件、覆盖保存），而 GTK 的 response 有八种取值。口径
   * 错成"非 NO 即同意"的话，Esc / 直接关窗 / DELETE_EVENT 都会被当成"用户点了是"
   * ——那是这类代码最危险的一种错，且真窗判据很难覆盖全（Esc 与关窗不好模拟）。
   * message 相反：只有一只按钮，按了确定与面板被关掉对调用方是同一件事。 */
  expect_int("message_result(OK)", moonui_dialog_message_result(GTK_RESPONSE_OK), 0);
  expect_int("message_result(关掉=DELETE)",
             moonui_dialog_message_result(GTK_RESPONSE_DELETE_EVENT), 0);
  expect_int("confirm_result(YES) 算同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_YES), 1);
  expect_int("confirm_result(NO) 算不同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_NO), 0);
  expect_int("confirm_result(CANCEL) 算不同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_CANCEL), 0);
  expect_int("confirm_result(DELETE_EVENT) 算不同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_DELETE_EVENT), 0);
  /* 没有应答（GTK_RESPONSE_NONE）绝不能落成"同意"：那是"没答"，不是"答应了"。 */
  expect_int("confirm_result(NONE) 不算同意",
             moonui_dialog_confirm_result(GTK_RESPONSE_NONE), 0);

  if (g_fails == 0) {
    printf("[selftest] OK：%d 项纯逻辑判据全绿\n", g_checks);
    return 0;
  }
  printf("[selftest] 失败：%d / %d 项判据红\n", g_fails, g_checks);
  return 1;
}
