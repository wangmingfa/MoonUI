/*
 * MoonUI · Linux/GTK4 画布（P4）——**真跑**的像素判据。
 *
 * 这个文件直接对着 backends/native-linux/adapter_native_gtk.c 里那份**真实现**
 * 链接（不是复制一份代码），所以判据绿 = 发布出去的那份 C 行为正确。
 *
 * 为什么能在 macOS 上跑：画布这一层只用 cairo（软件光栅，pixman）+ pango +
 * gdk-pixbuf，不碰显示服务器；脚本从 brew bottle 拼出的私有 dylib 目录就能跑。
 * 见 scripts/macos-cairo-runtime.js 与 scripts/canvas-pixel-check.sh 的头注。
 *
 * 边界（写清楚，别把这里的绿当"Linux 上一定绿"）：
 *   - 字体：本机 fontconfig 与 Linux 的字体栈不同，所以文本只验"量得出、画得上"，
 *     **不验**具体像素宽度/字形位置；量不出字体时打 SKIP（不是 PASS）。
 *   - 上屏（attach_window / present / present_view）需要真窗口**系统**，这里只验
 *     "挂上了、present 不报错"以及失败路径；真上屏在 Linux 真机 + xvfb。
 *   - P6-1 起还验控件层**结构**（造 / 挂 / 摆 / 层叠 / 摘挂 / 与画布共存）：无显示器
 *     下 gtk_init_check 也成立，所以这一层是真 GTK4 真跑；但"上屏之后的实际分配
 *     尺寸"要排版，留给 P8。
 *   - P6-2 的剪贴板判据**会临时占用系统剪贴板**（每条先备份、出口恢复，实测跑完
 *     不留痕）；原本是图片之类的非文本内容会被清掉，因为 ABI 只有文本这一形。
 *     这里验的是"自己写、自己读回"，**不验跨进程交接**（那是真机上的事）。
 *   - P6-3 的消息框判据是**真跑**（无显示器下也能 present，靠 auto_dismiss 替按
 *     真按钮），代价是**桌面上会闪一下**原生对话框。文件面板那组只在
 *     MOONUI_FILE_PANEL=1 时跑——GtkFileChooserNative 缺 GSettings schema 时是
 *     `g_error()` 直接 abort，那不能让判据来承担。
 *   - P6-4b 的主题判据读真 GtkSettings / 真 GtkCssProvider / GTK 的样式级联，
 *     但**背景色与圆角上屏后的像素**、Label/Button 的前景色与字号要 P6-5 造出
 *     控件叶子之后才验得了（现在只造得出 Panel/Custom 两种控件）。
 *   - 抗锯齿边缘（圆角/弧/斜线）：只断言"该有的地方有色、该空的地方透明"，
 *     不断言边缘像素的具体灰度值——那是渲染器的自由。
 *
 * 用法：bash scripts/canvas-pixel-check.sh
 */
#include "adapter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* P6-4b 起判据要直接读真 GTK 对象（GtkSettings / GtkCssProvider / CSS class），
 * 不再只经 ABI 观察。编译口径由 canvas-pixel-check.sh 给：私有 sysroot 的
 * gtk-4.0 头 + 4.6 最低版本闸，和生成物那份是同一套。 */
#include <gtk/gtk.h>

static int g_pass = 0;
static int g_fail = 0;
static int g_skip = 0;

static void ok(const char *name) {
  g_pass++;
  printf("PASS  %s\n", name);
}

static void bad(const char *name, const char *detail) {
  g_fail++;
  printf("FAIL  %s  (%s)\n", name, detail);
}

/* 一条判据的收尾：中途出过 FAIL 就不再记 PASS（否则日志里同一行既 FAIL 又
 * PASS，"pass 数"还会把红的算成绿的——这正是本仓反复栽过的"判据不可观测"）。 */
static void finish(const char *name, int fail_before) {
  if (g_fail == fail_before) {
    ok(name);
  }
}

static void skip(const char *name, const char *why) {
  g_skip++;
  printf("SKIP  %s  (%s)\n", name, why);
}

/* 造一只 w×h 已开帧的画布。 */
static moonui_ptr canvas_new(int w, int h) {
  moonui_ptr c = moonui_canvas_create();
  if (c == 0) {
    return 0;
  }
  if (moonui_canvas_begin_frame(c, w, h) != 0) {
    moonui_canvas_destroy(c);
    return 0;
  }
  return c;
}

#define RGB(r, g, b) (((int64_t)(r) << 16) | ((int64_t)(g) << 8) | (int64_t)(b))

static int chan(int64_t rgb, int shift) { return (int)((rgb >> shift) & 0xFF); }

/* 颜色近似比较：抗锯齿/预乘取整都会抖动，容差给 3。 */
static int near(int64_t got, int64_t want) {
  if (got < 0) {
    return 0;
  }
  return chan(got, 16) - chan(want, 16) <= 3 && chan(want, 16) - chan(got, 16) <= 3 &&
         chan(got, 8) - chan(want, 8) <= 3 && chan(want, 8) - chan(got, 8) <= 3 &&
         chan(got, 0) - chan(want, 0) <= 3 && chan(want, 0) - chan(got, 0) <= 3;
}

/* 断言某点"是某色"（容差内）。 */
static void expect_rgb(const char *name, const char *what, moonui_ptr c, int x,
                       int y, int64_t want) {
  char detail[160];
  int64_t got = moonui_canvas_read_pixel(c, x, y);
  if (near(got, want)) {
    return;
  }
  snprintf(detail, sizeof(detail), "%s (%d,%d) 期望 %06llx 实际 %s%06llx", what, x,
           y, (unsigned long long)want,
           got < 0 ? "<透明/越界> " : "", (unsigned long long)(got < 0 ? 0 : got));
  bad(name, detail);
}

/* 断言某点"没有像素"（全透明）。 */
static void expect_empty(const char *name, const char *what, moonui_ptr c, int x,
                         int y) {
  char detail[160];
  int64_t got = moonui_canvas_read_pixel(c, x, y);
  if (got < 0) {
    return;
  }
  snprintf(detail, sizeof(detail), "%s (%d,%d) 期望透明，实际 %06llx", what, x, y,
           (unsigned long long)got);
  bad(name, detail);
}

/* 断言返回值。 */
static void expect_rc(const char *name, const char *what, int got, int want) {
  char detail[160];
  if (got == want) {
    return;
  }
  snprintf(detail, sizeof(detail), "%s 期望返回 %d，实际 %d", what, want, got);
  bad(name, detail);
}

/* ---- 1. 填充与读回 ---- */
static void t_fill_rect_opaque(void) {
  const char *nm = "fill_rect 不透明填充铺满矩形";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "fill_rect", moonui_canvas_fill_rect(c, 0, 0, 10, 10, 0, RGB(255, 0, 0), 255), 0);
  expect_rgb(nm, "左上", c, 0, 0, RGB(255, 0, 0));
  expect_rgb(nm, "中心", c, 5, 5, RGB(255, 0, 0));
  expect_rgb(nm, "右下", c, 9, 9, RGB(255, 0, 0));
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_fill_rect_rounded(void) {
  const char *nm = "fill_rect 圆角把四角裁掉、中心保留";
  int before = g_fail;
  /* 20×20、半径 10000‰ = 10px = 半宽 → 正圆。 */
  moonui_ptr c = canvas_new(20, 20);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(c, 0, 0, 20, 20, 10000, RGB(0, 128, 0), 255);
  expect_rgb(nm, "中心", c, 10, 10, RGB(0, 128, 0));
  expect_empty(nm, "左上角外侧", c, 0, 0);
  expect_empty(nm, "右下角外侧", c, 19, 19);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_fill_rect_alpha(void) {
  const char *nm = "fill_rect 半透明叠加按预乘混色";
  int before = g_fail;
  moonui_ptr c = canvas_new(4, 4);
  int64_t px;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(c, 0, 0, 4, 4, 0, RGB(255, 255, 255), 255);
  moonui_canvas_fill_rect(c, 0, 0, 4, 4, 0, RGB(255, 0, 0), 128);
  /* 白底 + 50% 红：R 仍是 255，G/B 落在中间带（取整会有 ±2 抖动）。 */
  px = moonui_canvas_read_pixel(c, 2, 2);
  if (px < 0) {
    bad(nm, "叠完变透明了");
  } else if (chan(px, 16) < 250) {
    bad(nm, "R 通道被压低了（半透明混色不对）");
  } else if (chan(px, 8) < 100 || chan(px, 8) > 160) {
    bad(nm, "G 通道不在 100..160（预乘展开算错）");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

static void t_read_pixel_bounds(void) {
  const char *nm = "read_pixel 越界与全透明都返回 -1";
  int before = g_fail;
  moonui_ptr c = canvas_new(4, 4);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  if (moonui_canvas_read_pixel(c, -1, 0) != -1 || moonui_canvas_read_pixel(c, 4, 0) != -1 ||
      moonui_canvas_read_pixel(c, 0, 4) != -1) {
    bad(nm, "越界没有返回 -1");
  } else if (moonui_canvas_read_pixel(c, 1, 1) != -1) {
    bad(nm, "空画布中心不是 -1（开帧没清成透明）");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

/* ---- 2. 状态栈 ---- */
static void t_clip_rect(void) {
  const char *nm = "clip_rect 之后画到界外的部分被裁掉";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_clip_rect(c, 0, 0, 5, 5);
  moonui_canvas_fill_rect(c, 0, 0, 10, 10, 0, RGB(0, 0, 255), 255);
  expect_rgb(nm, "裁剪区内", c, 2, 2, RGB(0, 0, 255));
  expect_empty(nm, "裁剪区外", c, 7, 7);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_translate_save_restore(void) {
  const char *nm = "translate 累积、save/restore 能撤回";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_save(c);
  moonui_canvas_translate(c, 5, 5);
  moonui_canvas_fill_rect(c, 0, 0, 2, 2, 0, RGB(255, 0, 0), 255);
  expect_rgb(nm, "平移后落点", c, 5, 5, RGB(255, 0, 0));
  expect_empty(nm, "原点上没东西", c, 0, 0);
  moonui_canvas_restore(c);
  moonui_canvas_fill_rect(c, 0, 0, 2, 2, 0, RGB(0, 255, 0), 255);
  expect_rgb(nm, "restore 后落回原点", c, 0, 0, RGB(0, 255, 0));
  moonui_canvas_destroy(c);
  finish(nm, before);
}

/* ---- 3. 线 / 弧 / 多边形 ---- */
static void t_line(void) {
  const char *nm = "line 画在两点之间、外侧不染";
  int before = g_fail;
  moonui_ptr c = canvas_new(10, 10);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_line(c, 0, 5, 9, 5, RGB(255, 0, 0), 1000);
  expect_rgb(nm, "线上", c, 5, 5, RGB(255, 0, 0));
  expect_empty(nm, "线外", c, 5, 2);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_arc_full(void) {
  const char *nm = "stroke_arc 整圈画出圆环（中间是空的）";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  /* 圆心 (20,20) 半径 10、线宽 1、扫过 360°。 */
  expect_rc(nm, "stroke_arc", moonui_canvas_stroke_arc(c, 20, 20, 10, 0, 360000, RGB(255, 0, 0), 1000), 0);
  expect_rgb(nm, "顶部环上", c, 20, 10, RGB(255, 0, 0));
  expect_rgb(nm, "底部环上", c, 20, 30, RGB(255, 0, 0));
  expect_rgb(nm, "右侧环上", c, 30, 20, RGB(255, 0, 0));
  expect_empty(nm, "圆心是空的", c, 20, 20);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_arc_half_direction(void) {
  const char *nm = "stroke_arc 从 0° 顺时针扫 180°：下半圈有、上半圈没有";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  /* ABI：0° = 三点钟、顺时针为正，位图 y 向下 → 扫过的正是下半圈。 */
  moonui_canvas_stroke_arc(c, 20, 20, 10, 0, 180000, RGB(0, 0, 255), 1000);
  expect_rgb(nm, "六点钟方向", c, 20, 30, RGB(0, 0, 255));
  expect_empty(nm, "十二点钟方向", c, 20, 10);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_arc_zero_sweep(void) {
  const char *nm = "stroke_arc 扫过角为 0 是正常状态（不画、返回 0）";
  int before = g_fail;
  moonui_ptr c = canvas_new(20, 20);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "sweep=0", moonui_canvas_stroke_arc(c, 10, 10, 5, 0, 0, RGB(255, 0, 0), 1000), 0);
  expect_empty(nm, "什么都没画", c, 10, 15);
  expect_rc(nm, "半径非正", moonui_canvas_stroke_arc(c, 10, 10, 0, 0, 90000, RGB(255, 0, 0), 1000), -1);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_fill_polygon(void) {
  const char *nm = "fill_polygon 填充闭合三角形、少于 3 点报错";
  int before = g_fail;
  int32_t pts[6] = {5, 5, 15, 5, 10, 15};
  moonui_ptr c = canvas_new(20, 20);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "三角形", moonui_canvas_fill_polygon(c, (moonui_ptr)(uintptr_t)pts, 3, RGB(255, 0, 0), 255), 0);
  expect_rgb(nm, "形内", c, 10, 8, RGB(255, 0, 0));
  expect_empty(nm, "形外", c, 2, 2);
  expect_rc(nm, "只有 2 点", moonui_canvas_fill_polygon(c, (moonui_ptr)(uintptr_t)pts, 2, RGB(255, 0, 0), 255), -1);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

/* ---- 4. 渐变 / 模糊 / 投影 ---- */
static void t_fill_linear(void) {
  const char *nm = "fill_linear 上→下渐变、stops 乱序也按 pos 排";
  int before = g_fail;
  /* 端点故意反着给（先 1000 再 0），验实现自己排序。 */
  int64_t stops[4] = {1000, RGB(0, 0, 255), 0, RGB(255, 0, 0)};
  moonui_ptr c = canvas_new(10, 100);
  int64_t top, bottom;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "fill_linear", moonui_canvas_fill_linear(c, 0, 0, 10, 100, (moonui_ptr)(uintptr_t)stops, 2), 0);
  top = moonui_canvas_read_pixel(c, 5, 2);
  bottom = moonui_canvas_read_pixel(c, 5, 97);
  if (top < 0 || bottom < 0) {
    bad(nm, "渐变没铺满");
  } else if (chan(top, 16) < 200 || chan(top, 0) > 60) {
    bad(nm, "顶端不是起点色（红）—— 起点/终点定义反了？");
  } else if (chan(bottom, 0) < 200 || chan(bottom, 16) > 60) {
    bad(nm, "底端不是终点色（蓝）");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

static void t_blur_region(void) {
  const char *nm = "blur_region 把区域内 1px 红线糊开、区域外不动";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  int64_t center, neighbor;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  /* **白底** + 一条 1px 竖红线。白底不是为了好看：read_pixel 会把颜色按 alpha
   * 反预乘回来，所以"很淡的红"照样读成 0xFF0000 —— 只看 R 通道永远看不出模糊
   * 有没有发生。糊开之后红被摊薄，G 通道从 0 抬起来，那才是可观测的量。 */
  moonui_canvas_fill_rect(c, 0, 0, 40, 40, 0, RGB(255, 255, 255), 255);
  /* 线宽 2px：1px 的线画在整数坐标上只覆盖半个像素，抗锯齿后读回来是 ff7f7f，
   * 那是**正确**行为，不该拿来当"纯红"的基准（第一版判据就栽在这）。 */
  moonui_canvas_line(c, 20, 0, 20, 39, RGB(255, 0, 0), 2000);
  expect_rgb(nm, "模糊前中心是纯红", c, 20, 20, RGB(255, 0, 0));
  expect_rgb(nm, "模糊前邻点是纯白", c, 22, 20, RGB(255, 255, 255));
  expect_rc(nm, "blur_region", moonui_canvas_blur_region(c, 10, 0, 20, 40, 3000), 0);
  center = moonui_canvas_read_pixel(c, 20, 20);
  neighbor = moonui_canvas_read_pixel(c, 22, 20);
  if (center < 0 || neighbor < 0) {
    bad(nm, "模糊之后读了透明（白底不该透明）");
  } else if (chan(center, 8) < 20) {
    bad(nm, "中心仍是纯红：模糊没把强度摊开");
  } else if (chan(neighbor, 8) > 250) {
    bad(nm, "邻点仍是纯白：模糊没把颜色铺出去");
  }
  /* 区域外（x=37 离模糊域 7px 以上）仍应是纯白。 */
  expect_rgb(nm, "区域外未被波及", c, 37, 20, RGB(255, 255, 255));
  expect_rc(nm, "半径 0 是恒等", moonui_canvas_blur_region(c, 10, 0, 20, 40, 0), 0);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

static void t_shadow(void) {
  const char *nm = "shadow 是状态：设了有影、blur=0 清零后无影";
  int before = g_fail;
  moonui_ptr c = canvas_new(40, 40);
  moonui_ptr d;
  int64_t px;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(c, 0, 0, 40, 40, 0, RGB(255, 255, 255), 255);
  expect_rc(nm, "shadow", moonui_canvas_shadow(c, 4, 4, 4000, RGB(0, 0, 0)), 0);
  moonui_canvas_fill_rect(c, 10, 10, 10, 10, 0, RGB(255, 255, 255), 255);
  /* 阴影往右下偏 4px，所以右边外侧 (24,24) 应该被压暗一点。 */
  px = moonui_canvas_read_pixel(c, 24, 24);
  if (px < 0) {
    bad(nm, "阴影位置读了透明（白底不该透明）");
  } else if (chan(px, 16) > 250 && chan(px, 8) > 250) {
    bad(nm, "偏移方向上没有阴影");
  }
  moonui_canvas_destroy(c);

  /* 清零口：同一个渲染流程、不设影 → 同一位置必须纯白。 */
  d = canvas_new(40, 40);
  if (d == 0) {
    bad(nm, "第二只画布造不出来");
    return;
  }
  moonui_canvas_fill_rect(d, 0, 0, 40, 40, 0, RGB(255, 255, 255), 255);
  moonui_canvas_shadow(d, 4, 4, 4000, RGB(0, 0, 0));
  expect_rc(nm, "shadow 清零", moonui_canvas_shadow(d, 0, 0, 0, RGB(0, 0, 0)), 0);
  moonui_canvas_fill_rect(d, 10, 10, 10, 10, 0, RGB(255, 255, 255), 255);
  expect_rgb(nm, "清零后该处纯白", d, 24, 24, RGB(255, 255, 255));
  moonui_canvas_destroy(d);
  finish(nm, before);
}

/* ---- 5. 文本 ---- */
static void t_measure_text(void) {
  const char *nm = "measure_text 量得出宽高、空串报错";
  int before = g_fail;
  int64_t packed = moonui_canvas_measure_text("Hello", 5, 13000, 0);
  int64_t w = packed >> 32;
  int64_t h = packed & 0xFFFFFFFF;
  if (packed < 0) {
    bad(nm, "测量返回负数");
  } else if (w <= 0 || h <= 0) {
    bad(nm, "宽或高是 0（字体没装上？）");
  } else if (h < 8 || h > 40) {
    bad(nm, "行高不在 8..40（13px 字号的行高应该在这个带里）");
  } else if (moonui_canvas_measure_text("", 0, 13000, 0) != -1) {
    bad(nm, "空串没有返回 -1");
  } else {
    finish(nm, before);
    return;
  }
}

static void t_draw_text(void) {
  const char *nm = "draw_text 真的把像素染上";
  int before = g_fail;
  moonui_ptr c;
  int x, y;
  int inked = 0;
  /* 先确认字体栈可用：测不出宽度就说明这台机器没字体，判据不可观测 → SKIP。 */
  if (moonui_canvas_measure_text("W", 1, 16000, 0) <= 0) {
    skip(nm, "这台机器量不出字宽（无字体栈），文本像素判据不可观测");
    return;
  }
  c = canvas_new(80, 30);
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  expect_rc(nm, "draw_text", moonui_canvas_draw_text(c, "Wg", 2, 2, 2, 16000, 0, RGB(0, 0, 0)), 0);
  for (y = 0; y < 30; y++) {
    for (x = 0; x < 80; x++) {
      if (moonui_canvas_read_pixel(c, x, y) >= 0) {
        inked++;
      }
    }
  }
  if (inked < 20) {
    bad(nm, "画了字但几乎没有染上的像素");
  } else {
    finish(nm, before);
  }
  moonui_canvas_destroy(c);
}

/* ---- 6. 位图 ---- */
/* 2×2 纯红 PPM（P6）。用 PPM 而不是 PNG：gdk-pixbuf 的 pnm 解码器不依赖外部
 * 库，判据本身不必背一份 PNG 字节流。 */
static const char kPpm[] = "P6\n2 2\n255\n\xff\x00\x00\xff\x00\x00\xff\x00\x00\xff\x00\x00";

static void t_draw_image(void) {
  const char *nm = "draw_image 解码并缩放贴到指定矩形";
  int before = g_fail;
  moonui_ptr c = canvas_new(8, 8);
  int rc;
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  rc = moonui_canvas_draw_image(c, kPpm, (int)sizeof(kPpm) - 1, 0, 0, 4, 4);
  if (rc != 0) {
    skip(nm, "本机 gdk-pixbuf 解不出 PPM（解码器模块没装）——真机/CI 上验");
    moonui_canvas_destroy(c);
    return;
  }
  expect_rgb(nm, "贴图区中心", c, 2, 2, RGB(255, 0, 0));
  expect_empty(nm, "矩形外", c, 6, 6);
  moonui_canvas_destroy(c);
  finish(nm, before);
}

/* ---- 7. 失败路径（上屏类只能验这些，真窗在 Linux 真机）---- */
static void t_error_paths(void) {
  const char *nm = "参数错 / 没开帧 / 没挂窗 都返回 -1";
  int before = g_fail;
  moonui_ptr c = moonui_canvas_create();
  if (c == 0) {
    bad(nm, "画布造不出来");
    return;
  }
  if (moonui_canvas_begin_frame(c, 0, 10) != -1) {
    bad(nm, "0 宽的帧没有被拒");
  } else if (moonui_canvas_fill_rect(c, 0, 0, 1, 1, 0, RGB(255, 0, 0), 255) != -1) {
    bad(nm, "没开帧就画没报错");
  } else if (moonui_canvas_end_frame(c) != -1) {
    bad(nm, "没开帧就收帧没报错");
  } else if (moonui_canvas_present(c) != -1) {
    bad(nm, "没挂窗就 present 没报错");
  } else if (moonui_canvas_attach_window(c, 0) != -1) {
    bad(nm, "挂空窗口没报错");
  } else if (moonui_canvas_present_view(c, 0) != -1) {
    bad(nm, "贴空视图没报错");
  } else if (moonui_canvas_backend_of(c) != 0) {
    bad(nm, "backend_of 不是 AUTO(0)");
  } else if (moonui_canvas_destroy(0) != -1) {
    bad(nm, "销毁空画布没报错");
  } else {
    moonui_canvas_destroy(c);
    finish(nm, before);
    return;
  }
  moonui_canvas_destroy(c);
}

/* ---- P6-1 控件挂载层：真 GTK4 的结构判据 ----
 *
 * 2026-11-08 实测：`gtk_init_check()` 在 macOS **没有显示器**时也返回 1，
 * `gtk_fixed_new` / `gtk_drawing_area_new` / `gtk_overlay_new` 都造得出来。所以
 * 控件这一层的**结构**（造得出来、挂得上、摆得进、层叠顺序、摘得下、画布与控件
 * 共存）能在本机真跑——不是靠假 widget 树（那是 scripts/mock-gtk-selftest.c 第
 * 7 组的做法，只验纯指针逻辑）。
 *
 * 仍然证不了的：真上屏之后的分配尺寸、命中反查（要先排版）、坐标在 HiDPI 下的
 * 实际观感——那些留给 Linux 真机（P8）。
 */
static int64_t px_pack(int a, int b) {
  return (int64_t)(((uint64_t)(uint32_t)a << 32) | (uint64_t)(uint32_t)b);
}

static void t_widget_new_kinds(void) {
  const char *nm = "widget_new：Panel(17)/Custom(18) 造得出，未接的 kind 如实返回 0";
  int before = g_fail;
  moonui_ptr panel, custom, label, webview;
  if (moonui_native_init() != 0) {
    skip(nm, "gtk_init 失败（无显示器）");
    return;
  }
  panel = moonui_native_widget_new(17, "", 0);
  custom = moonui_native_widget_new(18, "", 0);
  label = moonui_native_widget_new(0, "x", 1);    /* Label：P6-5 才接 */
  webview = moonui_native_widget_new(19, "", 0);  /* WebView：同 mac 的缺席姿态 */
  if (panel == 0) {
    bad(nm, "Panel(17) 造不出来");
  } else if (custom == 0) {
    bad(nm, "Custom(18) 造不出来");
  } else if (label != 0 || webview != 0) {
    bad(nm, "未接的 kind 没有如实返回 0（会被当成造出来了）");
  } else {
    finish(nm, before);
  }
  /* 销毁路径不走判据（自由后使用查不出来），只保证不崩。 */
  moonui_native_widget_destroy(label);
  moonui_native_widget_destroy(webview);
  moonui_native_widget_destroy(custom);
  moonui_native_widget_destroy(panel);
}

static void t_widget_props(void) {
  const char *nm = "widget 的可见/可用往返（真 GTK4 的 visible/sensitive）";
  int before = g_fail;
  moonui_ptr w = moonui_native_widget_new(18, "", 0);
  if (w == 0) {
    bad(nm, "Custom 造不出来");
    return;
  }
  if (moonui_native_widget_visible(w) != 1) {
    /* GTK4 的控件**默认可见**（4.0 起没有 gtk_widget_show，visible 的默认值就是
     * TRUE），与 mac 的 NSView（hidden=NO）同义。这条钉的是那个默认值——写成
     * 0 的话每个新控件都得靠 Core 先 show 一次才画得出来。 */
    bad(nm, "新控件初始不是「可见」（GTK4 的 visible 默认 TRUE，与 NSView 同义）");
  } else if (moonui_native_widget_set_visible(w, 0),
             moonui_native_widget_visible(w) != 0) {
    bad(nm, "set_visible(0) 之后读回不是 0");
  } else if (moonui_native_widget_set_visible(w, 1),
             moonui_native_widget_visible(w) != 1) {
    bad(nm, "set_visible(1) 之后读回不是 1");
  } else if (moonui_native_widget_enabled(w) != 1) {
    bad(nm, "新控件初始不是「可用」（GTK 的 sensitive 默认 TRUE）");
  } else if (moonui_native_widget_set_enabled(w, 0),
             moonui_native_widget_enabled(w) != 0) {
    bad(nm, "set_enabled(0) 之后读回不是 0");
  } else {
    moonui_native_widget_set_opacity(w, 2000); /* 越界要夹，不该崩 */
    moonui_native_widget_set_opacity(w, -5);
    finish(nm, before);
  }
  moonui_native_widget_destroy(w);
}

static void t_widget_attach_z(void) {
  const char *nm = "control_attach / z 序 / raise / detach（真 GtkFixed 的子节点顺序）";
  int before = g_fail;
  moonui_ptr win = moonui_native_window_new("w", 1, 320, 240);
  moonui_ptr a = moonui_native_widget_new(17, "", 0);
  moonui_ptr b = moonui_native_widget_new(18, "", 0);
  if (win == 0 || a == 0 || b == 0) {
    bad(nm, "窗口或控件造不出来");
    return;
  }
  if (moonui_native_control_z_index(a) != -1) {
    bad(nm, "还没挂的控件 z 序不是 -1");
  } else {
    moonui_native_control_attach(win, a);
    moonui_native_control_attach(win, b);
    /* 后挂的在上：ABI 的 0 = 最上层 */
    if (moonui_native_control_z_index(b) != 0 ||
        moonui_native_control_z_index(a) != 1) {
      bad(nm, "attach 之后的层叠不是「后挂的在上」");
    } else {
      /* raise 是"摘下来再放回去"（GtkFixed 没有重排 API），要真把顺序换过来 */
      moonui_native_control_raise(a);
      if (moonui_native_control_z_index(a) != 0 ||
          moonui_native_control_z_index(b) != 1) {
        bad(nm, "raise 之后顺序没换过来");
      } else if (moonui_native_control_detach(b),
                 moonui_native_control_z_index(b) != -1) {
        bad(nm, "detach 之后 z 序不是 -1");
      } else if (moonui_native_control_attach(win, b),
                 moonui_native_control_z_index(b) != 0) {
        /* 这一条同时验了「detach 不销毁」：被摘下来的控件还能挂回去。
         * 若 detach 顺手把对象释放了，这里就是一次自由后使用。 */
        bad(nm, "detach 之后重新 attach 挂不回去（控件被提前销毁了？）");
      } else {
        finish(nm, before);
      }
    }
  }
  moonui_native_widget_destroy(a);
  moonui_native_widget_destroy(b);
  moonui_native_window_destroy(win);
}

static void t_widget_bounds_origin(void) {
  const char *nm = "control_set_bounds → widget_origin 读回（物理像素 ↔ 逻辑单位换算）";
  int before = g_fail;
  moonui_ptr win = moonui_native_window_new("w", 1, 320, 240);
  moonui_ptr w = moonui_native_widget_new(18, "", 0);
  int scale, ex, ey;
  int64_t org;
  if (win == 0 || w == 0) {
    bad(nm, "窗口或控件造不出来");
    return;
  }
  moonui_native_control_attach(win, w);
  scale = moonui_native_widget_dpi(w) / 96;
  if (scale <= 0) scale = 1;
  moonui_native_control_set_bounds(w, 20, 10, 100, 50);
  org = moonui_native_widget_origin(w);
  /* 进参是物理像素，落地时除以缩放因子换成 GTK 的逻辑单位；读回再乘回去。
   * 20 与 10 都能被常见的 scale（1/2/3）整除，所以期望值是精确的。 */
  ex = (20 / scale) * scale;
  ey = (10 / scale) * scale;
  if ((int)((org >> 32) & 0x7FFFFFFF) != ex || (int)(org & 0x7FFFFFFF) != ey) {
    bad(nm, "origin 读回与 set_bounds 的进参对不上（scale 换算错）");
  } else {
    /* origin 读的是我们自己摆的那份账（见 widgets_gtk.inc 的注释：GTK 4.24 的
     * gtk_fixed_get_child_position 布局前恒报 0,0）。所以这里再验一条**真 GTK 的
     * 事实**：尺寸请求有没有真落进控件——minimum_size 走 gtk_widget_measure，
     * 数不对就说明 set_size_request 根本没执行到。 */
    int64_t mn = moonui_native_widget_minimum_size(w);
    if ((int)((mn >> 32) & 0x7FFFFFFF) != (100 / scale) * scale ||
        (int)(mn & 0x7FFFFFFF) != (50 / scale) * scale) {
      bad(nm, "minimum_size 没跟着 set_bounds 的尺寸走（GTK 没收到 set_size_request）");
    } else {
      finish(nm, before);
    }
  }
  moonui_native_widget_destroy(w);
  moonui_native_window_destroy(win);
}

static void t_canvas_on_widget_window(void) {
  const char *nm = "画布与控件共存（P4 缺口）：先挂控件再 attach_window 也成功";
  int before = g_fail;
  moonui_ptr win = moonui_native_window_new("w", 1, 320, 240);
  moonui_ptr panel = moonui_native_widget_new(17, "", 0);
  moonui_ptr custom = moonui_native_widget_new(18, "", 0);
  moonui_ptr c = canvas_new(64, 64);
  moonui_ptr c2;
  if (win == 0 || panel == 0 || custom == 0 || c == 0) {
    bad(nm, "窗口 / 控件 / 画布有一个造不出来");
    return;
  }
  moonui_native_control_attach(win, panel); /* 控件先挂：窗口内容容器此刻才建出来 */
  if (moonui_canvas_attach_window(c, win) != 0) {
    bad(nm, "窗口已有控件时 attach_window 仍然失败（P4 那条缺口又回来了）");
  } else if (moonui_canvas_present(c) != 0) {
    bad(nm, "挂上之后 present 报错");
  } else if ((c2 = canvas_new(8, 8)) != 0 &&
             moonui_canvas_attach_window(c2, win) != -1) {
    bad(nm, "同一扇窗挂第二张整窗画布没被拒（会互相盖住）");
    moonui_canvas_destroy(c2);
  } else {
    if (c2 != 0) moonui_canvas_destroy(c2);
    /* present_view：自绘面（kind 18）能当上屏目标，Panel（kind 17）不能 */
    if (moonui_canvas_present_view(c, custom) != 0) {
      bad(nm, "present_view 认不出 Custom 自绘面");
    } else if (moonui_canvas_present_view(c, panel) != -1) {
      bad(nm, "present_view 把 Panel 也当成自绘面了");
    } else {
      finish(nm, before);
    }
  }
  moonui_canvas_destroy(c);
  moonui_native_widget_destroy(panel);
  moonui_native_widget_destroy(custom);
  moonui_native_window_destroy(win);
}

/* ---- P6-2：剪贴板（真 GTK4 真跑）----
 *
 * 本自检只链 libmoonbitrun.o，里面**没有** `moonbit_make_bytes`，而剪贴板那条 ABI
 * 的返回值要造 bytes。同 `gdk_keyval_name` / `moonbit_make_bytes` 那招：补一个
 * "声明有、实现不在"的符号。
 *
 * 但这一条比前面几个替身严格——**布局必须与真运行时逐字节一致**：对象头是
 * `{ int32_t rc; uint32_t meta; }` 紧贴在 payload 之前，all-scalar array（bytes 就是）
 * 的 meta 就是元素个数。判据靠 `Moonbit_array_length` 读长度，所以这里写错的话
 * 长度判据会直接红（那不是"判据错"，是这个替身错——两条都得对）。 */
moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  struct moonbit_object *hdr;
  uint8_t *payload;
  if (size < 0) {
    size = 0;
  }
  hdr = (struct moonbit_object *)malloc(sizeof(struct moonbit_object) + (size_t)size);
  if (hdr == NULL) {
    abort();
  }
  hdr->rc = (int32_t)(((uint32_t)1 << MOONBIT_RC_COUNT_SHIFT) |
                      (uint32_t)moonbit_BLOCK_KIND_VAL_ARRAY);
  hdr->meta = (uint32_t)size;
  payload = (uint8_t *)(hdr + 1);
  memset(payload, value, (size_t)size);
  return payload;
}

/* 把 ABI 返回的 bytes 拷成可 strcmp 的 C 串。Bytes 不保证 NUL 结尾，长度只能从
 * 对象头拿（见上面那个替身的注释）。 */
static char *clip_text_dup(void) {
  moonbit_bytes_t b = moonui_native_clipboard_text();
  int32_t n;
  char *s;
  if (b == NULL) {
    return NULL;
  }
  n = (int32_t)Moonbit_array_length(b);
  s = (char *)malloc((size_t)n + 1);
  if (s == NULL) {
    return NULL;
  }
  if (n > 0) {
    memcpy(s, (const void *)b, (size_t)n);
  }
  s[n] = '\0';
  return s;
}

/* 往剪贴板写一段 C 串，长度按 UTF-8 字节数给（ABI 要的是字节数，不是字符数）。 */
static int clip_put(const char *s) {
  return moonui_native_clipboard_set_text(s, (int)strlen(s));
}

/* 写 → 读回 → 恢复。**这个判据会临时占用系统剪贴板**，所以进了就先备份、
 * 每条出口都恢复。原本是图片之类的非文本内容会被清掉——ABI 只有文本这一形，
 * 保不真（证据边界写在 TODO）。 */
static void t_clipboard_roundtrip(void) {
  const char *name = "clipboard 写读往返（UTF-8 中文）";
  const char *want = "moonui-剪贴板-42";
  int before = g_fail;
  char *old = clip_text_dup();
  char *got;
  int rc;
  if (old == NULL) {
    skip(name, "读剪贴板返回 NULL（不该发生：空也应是空 bytes）");
    return;
  }
  rc = clip_put(want);
  if (rc == -1) {
    free(old);
    skip(name, "没有可用的剪贴板（没有 GDK 后端 / 无 display）");
    return;
  }
  if (rc != 0) {
    bad(name, "set_text 返回了 0/-1 之外的码");
  } else {
    got = clip_text_dup();
    if (got == NULL || strcmp(got, want) != 0) {
      bad(name, "读回与写入不一致（写进去了但读出来不是那段）");
    }
    free(got);
  }
  /* 恢复：顺带验"写空串"这条不崩（原剪贴板为空时就是它）。 */
  if (clip_put(old) != 0) {
    bad(name, "恢复原剪贴板失败——本机剪贴板已被这次测试改掉");
  }
  free(old);
  finish(name, before);
}

/* 覆盖语义 + 长度维度。长度这一维必须单独钉：只比内容的话，返回多带/少带几个
 * 字节的实现在 strcmp 上照样绿（"判据不可观测"那个坑）。 */
static void t_clipboard_overwrite(void) {
  const char *name = "clipboard 覆盖不追加 + 长度是 UTF-8 字节数";
  const char *cn = "中文测试"; /* 4 个汉字，UTF-8 12 字节 */
  int before = g_fail;
  char *old = clip_text_dup();
  char *got;
  moonbit_bytes_t b;
  if (old == NULL) {
    skip(name, "读剪贴板返回 NULL");
    return;
  }
  if (clip_put("a") == -1) {
    free(old);
    skip(name, "没有可用的剪贴板");
    return;
  }
  if (clip_put(cn) != 0) {
    bad(name, "第二次写返回非 0");
  } else {
    b = moonui_native_clipboard_text();
    if (b == NULL || (int32_t)Moonbit_array_length(b) != 12) {
      bad(name, "读回长度不是 12（按字节数算；“中文测试”=4 汉字×3 字节）");
    } else if (memcmp((const void *)b, cn, 12) != 0) {
      bad(name, "读回内容不是第二段（覆盖变成追加了？）");
    }
  }
  got = clip_text_dup();
  if (got != NULL && strcmp(got, "a") == 0) {
    bad(name, "读回还是第一段（没覆盖成功）");
  }
  free(got);
  if (clip_put(old) != 0) {
    bad(name, "恢复原剪贴板失败");
  }
  free(old);
  finish(name, before);
}

/* 参数错必须报 -2（"拿住了但没写进去"这一档），不能悄悄当成功。
 * 这条不改剪贴板内容，所以不备份。 */
static void t_clipboard_bad_args(void) {
  const char *name = "clipboard 参数错误报 -2，不谎报成功";
  int before = g_fail;
  if (moonui_native_clipboard_set_text(NULL, 0) != -2) {
    bad(name, "text=NULL 没有报 -2");
  }
  if (moonui_native_clipboard_set_text("x", -1) != -2) {
    bad(name, "text_len<0 没有报 -2");
  }
  finish(name, before);
}

/* ---- P6-3 对话框与文件面板（真 GtkMessageDialog / 真 GtkFileChooserNative）----
 *
 * 消息框这组是**真跑**的：2026-11-08 探针实测，无显示器下 `gtk_window_present`
 * 照样能 present，我们自己的 GMainLoop 收到 response（点是 -8、点否 -9、确定 -5），
 * 所以"点了按钮之后 ABI 返回什么"这条能在本机验。注意这会**在桌面上闪一下**原生
 * 对话框（0ms 后就被替按掉），这是真跑的代价，不是故障。
 *
 * 文件面板那组默认 SKIP：GtkFileChooserNative 一 show 就去读
 * `org.gtk.Settings.FileChooser`，schema 不可用时 GTK 是 `g_error()`（直接把进程
 * 带走，不是返回错误码）。所以由 check 脚本先编译 schema 并导出
 * MOONUI_FILE_PANEL=1，只有这时候才跑——"判据把测试进程干掉"不能当成一条红。
 *
 * 仍然证不了的：真机上"用户真按了按钮"的完整路径（这里只证明应答通路与码表）、
 * portal 下的面板（本机走的是内置 GtkFileChooserDialog）。 */

/* ABI 返回的 bytes → 可 strcmp 的 C 串（长度只能从对象头拿，见 moonbit_make_bytes
 * 替身的注释）。空包返回空串而不是 NULL，判据里就能直接比 ""。 */
static char *dlg_bytes_dup(moonbit_bytes_t b) {
  int32_t n;
  char *s;
  if (b == NULL) {
    return NULL;
  }
  n = (int32_t)Moonbit_array_length(b);
  s = (char *)malloc((size_t)n + 1);
  if (s == NULL) {
    return NULL;
  }
  if (n > 0) {
    memcpy(s, b, (size_t)n);
  }
  s[n] = '\0';
  return s;
}

static int file_panel_ready(void) {
  const char *v = getenv("MOONUI_FILE_PANEL");
  return v != NULL && strcmp(v, "1") == 0;
}

/* message：只有一只按钮，"按了确定"与"面板被关掉"对调用方是同一件事，都返回 0。 */
static void t_dialog_message(void) {
  const char *name =
      "dialog_message：点确定返回 0（真 GtkMessageDialog + 自动应答）";
  int before = g_fail;
  int rc;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_dismiss_dialog(0, 0) != 0) {
    bad(name, "装自动应答失败（index=0 是合法值）");
  } else {
    rc = moonui_native_dialog_message("title", 5, "body", 4);
    if (rc != 0) {
      bad(name, "返回码不是 0");
    }
  }
  finish(name, before);
}

/* confirm：GTK_RESPONSE_YES 才算同意。两条分开验——只验一条的话，"非 NO 即同意"
 * 那种写法（把 CANCEL/DELETE 也算成是）照样绿。 */
static void t_dialog_confirm_yes(void) {
  const char *name =
      "dialog_confirm：选「是」返回 1（只有 YES 算同意）";
  int before = g_fail;
  int rc;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_dismiss_dialog(0, 0) != 0) {
    bad(name, "装自动应答失败（index=0 是合法值）");
  } else {
    rc = moonui_native_dialog_confirm("title", 5, "sure?", 5);
    if (rc != 1) {
      bad(name, "返回码不是 1（选了「是」却不算同意）");
    }
  }
  finish(name, before);
}

static void t_dialog_confirm_no(void) {
  const char *name = "dialog_confirm：选「否」返回 0（不是 -1，取消与失败要分开）";
  int before = g_fail;
  int rc;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_dismiss_dialog(0, 1) != 0) {
    bad(name, "装自动应答失败（index=1 是 confirm 的合法值）");
  } else {
    rc = moonui_native_dialog_confirm("title", 5, "sure?", 5);
    if (rc != 0) {
      bad(name, "返回码不是 0（把「否」报成了失败或同意）");
    }
  }
  finish(name, before);
}

/* 文案不是合法 UTF-8 → -1（"文案没能交给系统"），不许弹一个空对话框冒充成功。
 * 这条不弹窗，所以不需要自动应答。 */
static void t_dialog_bad_utf8(void) {
  const char *name = "dialog 文案不是合法 UTF-8 时报 -1（不谎报成功）";
  int before = g_fail;
  /* 0xFF 在 UTF-8 里是非法起始字节。 */
  if (moonui_native_dialog_message("t", 1, "\xff", 1) != -1) {
    bad(name, "message 没有报 -1");
  }
  if (moonui_native_dialog_confirm("t", 1, "\xff", 1) != -1) {
    bad(name, "confirm 没有报 -1");
  }
  if (moonui_native_open_file("\xff", 1) != -1) {
    bad(name, "open_file 的标题不是合法 UTF-8 时没有报 -1");
  }
  finish(name, before);
}

/* 越界的按钮序号在**装的那一步**就报回去：留到运行时"什么也没按下"是一条挂住的
 * 测试，不是一条红的。 */
static void t_dialog_dismiss_bounds(void) {
  const char *name = "auto_dismiss_dialog：越界 index 当场报 -1";
  int before = g_fail;
  if (moonui_native_auto_dismiss_dialog(10, 2) != -1) {
    bad(name, "index=2 没有报 -1");
  }
  if (moonui_native_auto_dismiss_dialog(10, -1) != -1) {
    bad(name, "index=-1 没有报 -1");
  }
  finish(name, before);
}

/* 文件面板取消：auto_answer 替按取消之后，open_file 返回 0（取消），file_dialog_path
 * 取到空 bytes。
 *
 * **这里只验取消侧**，不验"取走即清"：取走语义只有在 accept 之后（result 里真放了
 * 一条路径）才有东西可取，而 accept 在本平台的 public API 上做不到（见
 * dialogs_gtk.inc 的 auto_answer_file_dialog）。取消路径上 result 恒为 NULL，所以
 * "第二次取走是否为空"这条判据在这条路上**不可观测**——改坏取走逻辑它照样绿。
 * 与其留一条假装在验的判据，不如把边界写在这里：取走即清由代码与 Linux 真机的
 * accept 路径（P8，走真实用户操作）保证。 */
static void t_file_dialog_cancel(void) {
  const char *name =
      "open_file：自动应答取消返回 0、路径为空（真 GtkFileChooserNative）";
  int before = g_fail;
  char *p;
  if (!file_panel_ready()) {
    skip(name, "缺 GSettings schema（内置文件面板一 show 就 g_error，见本组头注）");
    return;
  }
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_answer_file_dialog(0, NULL, 0, 0) != 0) {
    bad(name, "装自动取消失败");
  } else if (moonui_native_open_file("title", 5) != 0) {
    bad(name, "取消没有返回 0（取消与失败必须分开）");
  } else {
    p = dlg_bytes_dup(moonui_native_file_dialog_path());
    if (p == NULL || p[0] != '\0') {
      bad(name, "取消之后路径不是空包");
    }
    free(p);
  }
  finish(name, before);
}

/* 三种形态都要能开、能取消——save 带默认名（走 set_current_name 那一支），
 * select_folder 走 SELECT_FOLDER 动作。只验 open 的话，"save 拼错 action 导致面板
 * 以打开文件的形态弹出"这类错就漏了。 */
static void t_file_dialog_save_folder(void) {
  const char *name = "save_file（带默认名）/ select_folder 也能开、能取消";
  int before = g_fail;
  if (!file_panel_ready()) {
    skip(name, "缺 GSettings schema（内置文件面板一 show 就 g_error，见本组头注）");
    return;
  }
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_auto_answer_file_dialog(0, NULL, 0, 0) != 0) {
    bad(name, "装自动取消失败（save）");
  } else if (moonui_native_save_file("t", 1, "out.txt", 7) != 0) {
    bad(name, "save_file 取消没有返回 0");
  }
  if (moonui_native_auto_answer_file_dialog(0, NULL, 0, 0) != 0) {
    bad(name, "装自动取消失败（folder）");
  } else if (moonui_native_select_folder("t", 1) != 0) {
    bad(name, "select_folder 取消没有返回 0");
  }
  finish(name, before);
}

/* auto_answer 的合法/非法形态：接受这一支在 4.24 的 public API 上做不到，如实报 -2
 * （与 mac 那半结论相同、理由不同）；接受但没给路径报 -1；取消报 0。 */
static void t_auto_answer_codes(void) {
  const char *name = "auto_answer_file_dialog：接受报 -2、空路径报 -1、取消报 0";
  int before = g_fail;
  if (moonui_native_auto_answer_file_dialog(10, "/tmp/x", 6, 0) != 0) {
    bad(name, "取消形态没有返回 0");
  }
  if (moonui_native_auto_answer_file_dialog(10, NULL, 0, 1) != -1) {
    bad(name, "接受但 path 为空没有报 -1");
  }
  if (moonui_native_auto_answer_file_dialog(10, "/tmp/x", 6, 1) != -2) {
    bad(name, "接受形态没有如实报 -2（本平台替按不到接受）");
  }
  finish(name, before);
}

/* ---- P6-4：菜单栏与上下文菜单（真 GTK4 真跑）----
 *
 * 这一组的判据读的都是**原生侧**，不是我们自己的账：
 *   - menu_dump 从 gtk_popover_menu_bar_get_menu_model 读，也就是真正挂在窗口上
 *     那个模型（只抄自己那份名字的话，"addItem 那一步整段删掉"照样能绿）；
 *   - 点击走 GActionGroup 的 activate_action，与用户点菜单项同一条派发；
 *   - 窗口结构用 gtk_window_get_child / first_child / next_sibling 真读。
 *
 * 菜单栏的容器结构（GtkBox[bar, overlay]）也在这组钉住：它是"客户区少一行"这件事
 * 的落点，结构一歪，content_size 的补偿就跟着歪。
 */

typedef struct {
  unsigned char buf[1024];
  int len;
} MenuBlob;

static void mb_u8(MenuBlob *b, int v) {
  if (b->len < (int)sizeof(b->buf)) b->buf[b->len] = (unsigned char)(v & 0xFF);
  b->len++;
}
static void mb_i32(MenuBlob *b, int v) {
  mb_u8(b, v);
  mb_u8(b, v >> 8);
  mb_u8(b, v >> 16);
  mb_u8(b, v >> 24);
}
static void mb_str(MenuBlob *b, const char *s) {
  int n = (int)strlen(s);
  int i;
  mb_i32(b, n);
  for (i = 0; i < n; ++i) mb_u8(b, (unsigned char)s[i]);
}
static void mb_item(MenuBlob *b, const char *label, int id, int role, int checked,
                    int enabled, int has_sc, int mods, const char *key) {
  mb_u8(b, 0);
  mb_str(b, label);
  mb_i32(b, id);
  mb_u8(b, role);
  mb_u8(b, checked);
  mb_u8(b, enabled);
  mb_u8(b, has_sc);
  if (has_sc) {
    mb_u8(b, mods);
    mb_str(b, key);
  }
}

/* File{New(Ctrl+Q), Auto(勾着), —, Off(禁用), More{Sub}}; Edit{A(单选勾着)} */
static void build_menu_tree(MenuBlob *b) {
  b->len = 0;
  mb_u8(b, 1);
  mb_i32(b, 2);
  /* menu 0：File */
  mb_str(b, "File");
  mb_i32(b, 5);
  mb_item(b, "New", 10, 0, 0, 1, 1, 1, "q");
  mb_item(b, "Auto", 11, 1, 1, 1, 0, 0, NULL);
  mb_u8(b, 1); /* 分隔线 */
  mb_item(b, "Off", 12, 0, 0, 0, 0, 0, NULL);
  mb_u8(b, 2); /* 子菜单 */
  mb_str(b, "More");
  mb_i32(b, 1);
  mb_item(b, "Sub", 13, 0, 0, 1, 0, 0, NULL);
  /* menu 1：Edit */
  mb_str(b, "Edit");
  mb_i32(b, 1);
  mb_item(b, "A", 20, 2, 1, 1, 0, 0, NULL);
}

/* 上下文菜单：Ctx{One(30), Two(31)}（一行两条，方便按 index 选）。 */
static void build_ctx_tree(MenuBlob *b) {
  b->len = 0;
  mb_u8(b, 1);
  mb_i32(b, 1);
  mb_str(b, "Ctx");
  mb_i32(b, 2);
  mb_item(b, "One", 30, 0, 0, 1, 0, 0, NULL);
  mb_item(b, "Two", 31, 0, 0, 1, 0, 0, NULL);
}

static int g_menu_click_id;
static int g_menu_click_count;

/* 客户区高度（ABI 回报值，pack2 的低 32 位）。
 *
 * 菜单栏那一行在 ABI 上有**两个**可观测口径：设尺寸时补进窗口请求值（+h），读回时
 * 从请求值里减出来（-h）。所以这条判据能从外面看见结构，不必去摸 GtkWidget——
 * 这个文件只 include adapter.h，没有 GTK 头（P6-1 那几条控件判据同理，全走 ABI）。
 * 两个口径合起来也正好把"量出来的高度"与"补进去的值必须是同一个数"钉住。 */
static int content_h(moonui_ptr win) {
  return (int)(moonui_native_window_content_size(win) & 0xFFFFFFFF);
}

static void on_menu_click(void *closure, int id) {
  (void)closure;
  g_menu_click_id = id;
  ++g_menu_click_count;
}

static const char *menu_dump_str(void) {
  return dlg_bytes_dup(moonui_native_menu_dump());
}

static void t_menu_install_dump(void) {
  const char *name =
      "set_menu_bar：装进真窗口，menu_dump 与树一致（勾选/禁用/组合/子菜单/分隔）";
  const char *want =
      "File{#10:n.e:New:Cq,#11:c+e:Auto:.,-,#12:n.d:Off:.,+More{#13:n.e:Sub:.}};"
      "Edit{#20:r+e:A:.}";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  char *got;
  char *tops;
  int h0;
  int h_bar;
  int h_set;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  /* 先把请求值定下来再量基准。**不能直接量 window_new 之后的客户区**：
   * window_new 用 `scale_of(NULL)`（未上屏时是 1）去除，而 set_content_size /
   * content_size 用 `scale_of(win)`（这台机器上 2），两边单位不同——实测 2x 屏上
   * window_new(320,240) 报回 480。走一次 set_content_size 之后同口径。 */
  moonui_native_window_set_content_size(win, 320, 240);
  h0 = content_h(win);
  g_menu_click_count = 0;
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else {
    got = (char *)menu_dump_str();
    if (got == NULL || strcmp(got, want) != 0) {
      printf("       got  = %s\n       want = %s\n", got ? got : "(null)", want);
      bad(name, "menu_dump 与树不一致");
    }
    free(got);
    tops = dlg_bytes_dup(moonui_native_menu_tops_dump());
    if (tops == NULL || tops[0] != '\0') {
      bad(name, "menu_tops_dump 在 Linux 上应当是空（没有应用菜单这个概念）");
    }
    free(tops);
    /* 客户区真的让出了一行（菜单栏挂在窗口上，高度是 gtk_widget_measure 量的
     * 真值）：回报值于是比请求值少那一行。 */
    h_bar = content_h(win);
    if (h0 - h_bar <= 0) {
      printf("       h0 = %d  h_bar = %d\n", h0, h_bar);
      bad(name, "装上菜单栏之后客户区没有变矮（bar 没挂上，或高度被量成 0）");
    }
    /* 再设一次内容尺寸：补进去的与减出来的必须是同一个数，所以回报值要回到 h0。
     * 少了"补"那一步就是 h0 - 一行（= h_bar），少了"减"那一步就是 h0 + 一行。 */
    moonui_native_window_set_content_size(win, 320, 240);
    h_set = content_h(win);
    if (h_set != h0) {
      printf("       h0 = %d  h_bar = %d  h_set = %d\n", h0, h_bar, h_set);
      bad(name, "设了内容尺寸 240 之后回报的不是 240（菜单栏那一行没补进窗口请求值）");
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_set_checked(void) {
  const char *name = "menu_item_set_checked：推勾选真的落到原生动作上（unknown 报 -1）";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  char *got;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else if (moonui_native_menu_item_set_checked(11, 0) != 0) {
    bad(name, "推 check 项的新状态失败");
  } else {
    got = (char *)menu_dump_str();
    if (got == NULL || strstr(got, "#11:c-e:Auto") == NULL) {
      bad(name, "dump 里 Auto 没有变成没勾（c-）");
    }
    free(got);
    if (moonui_native_menu_item_set_checked(999, 1) != -1) {
      bad(name, "不存在的 id 没有报 -1");
    }
    /* Normal 项没有状态：允许推、报"找到了"（与 mac 半同一口径），不改任何东西。 */
    if (moonui_native_menu_item_set_checked(10, 1) != 0) {
      bad(name, "Normal 项推勾选没有报 0");
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_click(void) {
  const char *name = "menu_click_item：走真 GAction（禁用项 -2、不存在的 -1）";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else {
    g_menu_click_id = -1;
    g_menu_click_count = 0;
    if (moonui_native_menu_click_item(10) != 0) {
      bad(name, "点正常项没有返回 0");
    } else if (g_menu_click_count != 1 || g_menu_click_id != 10) {
      bad(name, "点击回调没有带回正确的 id");
    }
    if (moonui_native_menu_click_item(12) != -2) {
      bad(name, "禁用项没有报 -2（那就等于绕过置灰真派发了）");
    }
    if (moonui_native_menu_click_item(999) != -1) {
      bad(name, "不存在的 id 没有报 -1");
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_uninstall(void) {
  const char *name = "拆菜单（空树）：菜单栏真的摘掉，客户区回到整窗";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  moonui_ptr base; /* 基准：装菜单之前建的、尺寸相同的窗口 */
  moonui_ptr win2;
  char *got;
  int h_base;
  int h_win0;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  /* 菜单栏是**进程全局**的：上一组装过的那一棵到现在还挂在所有窗口上，连新窗口
   * 都被钩子补了一行。所以先把基准恢复成"没有菜单"，否则下面两个基准值都偏一行
   * （实测 h_win0 读到 432 而不是 480）。 */
  b.len = 0;
  mb_u8(&b, 1);
  mb_i32(&b, 0);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "清空残留菜单失败");
    moonui_native_window_destroy(win);
    finish(name, before);
    return;
  }
  h_win0 = content_h(win);
  /* 基准窗口要在**装菜单之前**建：它的客户区就是"没有菜单栏"那个数。拿它跟后来
   * 新建的窗口比，比的是同一个代码路径，缩放因子的差别（window_new 与
   * content_size 各按自己的口径除/乘）不会混进来。 */
  base = moonui_native_window_new("b", 1, 200, 160);
  if (base == 0) {
    bad(name, "基准窗口造不出来");
    moonui_native_window_destroy(win);
    return;
  }
  h_base = content_h(base);
  moonui_native_window_destroy(base);
  build_menu_tree(&b);
  if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                 NULL) != 0) {
    bad(name, "set_menu_bar 返回非 0");
  } else {
    /* 装过菜单之后新建的窗口要自动补上（钩子那条路）：同样 200x160，客户区比
     * 基准少一行，就是"补上了"的铁证。 */
    win2 = moonui_native_window_new("w2", 2, 200, 160);
    if (win2 == 0) {
      bad(name, "第二个窗口造不出来");
    } else {
      if (content_h(win2) >= h_base) {
        printf("       base = %d  win2 = %d\n", h_base, content_h(win2));
        bad(name, "装过菜单之后新建的窗口没有补上菜单栏（客户区没让出一行）");
      }
      moonui_native_window_destroy(win2);
    }
    b.len = 0;
    mb_u8(&b, 1);
    mb_i32(&b, 0);
    if (moonui_native_set_menu_bar((const char *)b.buf, b.len, on_menu_click,
                                   NULL) != 0) {
      bad(name, "拆菜单（menu_count=0）返回非 0");
    } else {
      /* 空树 = 没有菜单栏：客户区回到建窗口时那个数，dump 也变空。
       *
       * 这条钉的是"空树真的把旧菜单换下去了"（旧树留着的话两个都红）。它**不**
       * 钉"空 bar 没有挂上去"：一只没有条目的 GtkPopoverMenuBar 高度实测是 0，
       * 挂不挂客户区都一样（负控制验过），所以别在这条上加那个说法。 */
      if (content_h(win) != h_win0) {
        printf("       h_win0 = %d  now = %d\n", h_win0, content_h(win));
        bad(name, "拆掉菜单之后客户区没回到整窗（旧菜单还挂着？）");
      }
      got = (char *)menu_dump_str();
      if (got == NULL || got[0] != '\0') {
        bad(name, "拆掉菜单之后 dump 不是空");
      }
      free(got);
    }
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

static void t_menu_context(void) {
  const char *name = "上下文菜单：替按第 2 项派发真回调；index=-1 只关不派发";
  int before = g_fail;
  MenuBlob b;
  moonui_ptr win;
  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  win = moonui_native_window_new("w", 1, 320, 240);
  if (win == 0) {
    bad(name, "窗口造不出来");
    return;
  }
  build_ctx_tree(&b);
  g_menu_click_id = -1;
  g_menu_click_count = 0;
  if (moonui_native_auto_pick_context_menu(0, 1) != 0) {
    bad(name, "装替按失败");
  } else if (moonui_native_show_context_menu((const char *)b.buf, b.len,
                                             on_menu_click, NULL) != 0) {
    bad(name, "show_context_menu 返回非 0");
  } else if (g_menu_click_count != 1 || g_menu_click_id != 31) {
    bad(name, "替按第 2 项没有派发 id 31（回调没跑到或跑错项）");
  }
  /* -1 = 点空白关掉：必须不派发。 */
  g_menu_click_count = 0;
  if (moonui_native_auto_pick_context_menu(0, -1) != 0) {
    bad(name, "装\"点空白\"失败");
  } else if (moonui_native_show_context_menu((const char *)b.buf, b.len,
                                             on_menu_click, NULL) != 0) {
    bad(name, "点空白那一次 show_context_menu 返回非 0");
  } else if (g_menu_click_count != 0) {
    bad(name, "点空白也派发了回调");
  }
  if (moonui_native_auto_pick_context_menu(0, -2) != -1) {
    bad(name, "越界 index（-2）没有当场报 -1");
  }
  if (moonui_native_show_context_menu("abc", 3, on_menu_click, NULL) != -1) {
    bad(name, "树太短没有报 -1");
  }
  moonui_native_window_destroy(win);
  finish(name, before);
}

/* ==================== P6-4b：系统外观 + 样式下发（真 GTK4 对象层） ====================
 * 这一层读的是 GTK 自己的对象：
 *   - system_theme 的输入由 g_object_set 改真 GtkSettings，期望值是硬编码的 1/0；
 *   - CSS 读 gtk_css_provider_to_string，那是 GTK 的 CSS 解析器**规范化后**的文本
 *     （我们写 12.000px，它输出 12px），不是实现自己那份待办账；
 *   - class 挂载读 gtk_widget_get_css_classes；provider 有没有真挂到 display 由
 *     **样式级联**验（往实现那只 provider 追加 color 规则，读同款 class 的
 *     GtkLabel 算出来的颜色；只看 provider 自己的 CSS 文本会漏掉这一层）。
 * 证不了的：背景/圆角**上屏后的像素**（要排版+渲染，只有 Linux 真机 + xvfb），
 * 以及 Label/Button 的前景色与字号（P6-5 才造得出这两类控件，见 TODO）。
 * ==================================================================================== */

typedef struct {
  gboolean prefer_dark;
  char *theme_name;
  int scheme;
  int has_scheme;
} ThemeSettingsBackup;

/* 枚举值按 **nick** 查（实现按 name 查），两套查法互为对拍；不硬编码 2/3。 */
static int theme_enum_by_nick(GObject *obj, const char *prop, const char *nick) {
  GParamSpec *ps = g_object_class_find_property(G_OBJECT_GET_CLASS(obj), prop);
  GEnumClass *ec;
  GEnumValue *v;
  int out = -1;
  if (ps == NULL || !G_IS_PARAM_SPEC_ENUM(ps)) return -1;
  ec = (GEnumClass *)g_type_class_ref(G_PARAM_SPEC_VALUE_TYPE(ps));
  if (ec != NULL) {
    v = g_enum_get_value_by_nick(ec, nick);
    if (v != NULL) out = v->value;
    g_type_class_unref(ec);
  }
  return out;
}

static void theme_settings_save(ThemeSettingsBackup *b) {
  GtkSettings *s = gtk_settings_get_default();
  memset(b, 0, sizeof(*b));
  if (s == NULL) return;
  g_object_get(s, "gtk-application-prefer-dark-theme", &b->prefer_dark,
               "gtk-theme-name", &b->theme_name, NULL);
  b->has_scheme = g_object_class_find_property(
      G_OBJECT_GET_CLASS(s), "gtk-interface-color-scheme") != NULL;
  if (b->has_scheme)
    g_object_get(s, "gtk-interface-color-scheme", &b->scheme, NULL);
}

static void theme_settings_restore(const ThemeSettingsBackup *b) {
  GtkSettings *s = gtk_settings_get_default();
  if (s == NULL) return;
  if (b->has_scheme)
    g_object_set(s, "gtk-interface-color-scheme", b->scheme, NULL);
  g_object_set(s, "gtk-application-prefer-dark-theme", b->prefer_dark,
               "gtk-theme-name", b->theme_name, NULL);
  g_free(b->theme_name);
}

static void t_theme_system_dark(void) {
  const char *name = "system_theme：读真 GtkSettings，两代属性与主题名都可 A/B";
  int before = g_fail;
  ThemeSettingsBackup b;
  GtkSettings *s;
  int dark_v = -1, light_v = -1, default_v = -1;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  s = gtk_settings_get_default();
  if (s == NULL) {
    skip(name, "拿不到 GtkSettings");
    return;
  }
  theme_settings_save(&b);
  if (b.has_scheme) {
    dark_v = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-color-scheme", "dark");
    light_v = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-color-scheme", "light");
    default_v = theme_enum_by_nick(G_OBJECT(s), "gtk-interface-color-scheme", "default");
    if (dark_v < 0 || light_v < 0 || default_v < 0) {
      bad(name, "枚举 nick 查不到 dark/light/default");
      theme_settings_restore(&b);
      return;
    }
  }

  /* GTK 4.24 会把两代属性**联动**：设 prefer-dark=TRUE → scheme=DARK，
   * FALSE → scheme=LIGHT（2026-11-09 探针实测）。而实现按"新属性明确
   * DARK/LIGHT 优先"处理，所以每次改完老属性/主题名之后都要把 scheme 显式
   * 复位成 default，才能测到 4.6 那条**回落**分支；探针另证"先设 pref、再设
   * scheme=default"两者可以共存。不复位的话，theme-name 那两条会被 LIGHT
   * 抢先返回 0，看起来像实现漏读 theme-name。 */
  g_object_set(s, "gtk-application-prefer-dark-theme", FALSE,
               "gtk-theme-name", "Adwaita", NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 0) bad(name, "全浅却报深色");

  /* 4.6 真机唯一的读口：prefer-dark */
  g_object_set(s, "gtk-application-prefer-dark-theme", TRUE, NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 1)
    bad(name, "prefer-dark=TRUE 没读到深色（4.6 真机走这条）");

  /* theme-name 的 :dark：探针实测它不会联动 prefer-dark，必须单独读 */
  g_object_set(s, "gtk-application-prefer-dark-theme", FALSE,
               "gtk-theme-name", "Adwaita:dark", NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 1)
    bad(name, "theme-name 的 :dark 漏报");
  g_object_set(s, "gtk-theme-name", "ADWAITA-Dark", NULL);
  if (b.has_scheme) g_object_set(s, "gtk-interface-color-scheme", default_v, NULL);
  if (moonui_native_system_theme() != 1)
    bad(name, "theme-name 的 DARK 大小写没归一");

  if (b.has_scheme) {
    /* 4.20+ 明确 DARK（scheme 最后设，别被联动覆盖） */
    g_object_set(s, "gtk-application-prefer-dark-theme", FALSE, NULL);
    g_object_set(s, "gtk-interface-color-scheme", dark_v, NULL);
    if (moonui_native_system_theme() != 1)
      bad(name, "color-scheme=DARK 没读到深色");
    /* 明确 LIGHT 时不能被老属性盖掉（优先级的钉子） */
    g_object_set(s, "gtk-application-prefer-dark-theme", TRUE, NULL);
    g_object_set(s, "gtk-interface-color-scheme", light_v, NULL);
    if (moonui_native_system_theme() != 0)
      bad(name, "color-scheme=LIGHT 被 prefer-dark 盖掉了");
  }
  theme_settings_restore(&b);
  finish(name, before);
}

static int has_style_class(GtkWidget *w) {
  char **classes = gtk_widget_get_css_classes(w);
  int i, found = 0;
  for (i = 0; classes != NULL && classes[i] != NULL; ++i) {
    if (strncmp(classes[i], "moonui-w-", 9) == 0) found = 1;
  }
  g_strfreev(classes);
  return found;
}

static void t_theme_panel_css(void) {
  const char *name = "widget_set_style：Panel 的 CSS 真挂上 GTK，-1 哨兵不动旧值";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w;
  GtkCssProvider *prov;
  char *css;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(17, "", 0);
  if (c == 0) {
    bad(name, "Panel 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  if (moonui_native_widget_set_style(c, RGB(10, 20, 30), -1, 7250, -1, -1) != 0)
    bad(name, "set_style 返回非 0");
  if (!has_style_class(w))
    bad(name, "widget 上找不到 moonui-w-* CSS class");

  /* 拿到的是实现借出的真 GtkCssProvider；to_string 是 GTK 解析器规范化后的文本。 */
  prov = (GtkCssProvider *)g_object_get_data(G_OBJECT(w),
                                             "moonui-gtk-css-provider");
  if (prov == NULL) {
    bad(name, "拿不到 provider（样式没落到 GTK 对象上）");
  } else {
    css = gtk_css_provider_to_string(prov);
    if (css == NULL || strstr(css, "background-color: rgb(10,20,30)") == NULL)
      bad(name, "GTK 解析后没有背景色 rgb(10,20,30)");
    if (css == NULL || strstr(css, "7.25px") == NULL)
      bad(name, "GTK 解析后没有 7.25px 圆角（7250 permille）");
    if (css != NULL && strstr(css, "\n  color:") != NULL)
      bad(name, "Panel 不该消费 fg 通道");
    if (css != NULL && strstr(css, "font-size") != NULL)
      bad(name, "Panel 不该消费 font 通道");
    g_free(css);

    /* 增量下发：只改 radius，其余全 -1，bg 必须还在（"这一项不动"的钉子）。 */
    if (moonui_native_widget_set_style(c, -1, -1, 12000, -1, -1) != 0)
      bad(name, "增量 set_style 返回非 0");
    css = gtk_css_provider_to_string(prov);
    if (css == NULL || strstr(css, "background-color: rgb(10,20,30)") == NULL)
      bad(name, "-1 哨兵把旧背景色弄丢了");
    if (css == NULL || strstr(css, "12px") == NULL)
      bad(name, "新的 12000 permille 没落到 12px 圆角");
    g_free(css);
  }
  moonui_native_widget_destroy(c);
  finish(name, before);
}

/* P6-4b：provider 是否**真挂到 display**。
 * 上面那条读的是 provider 自己的 CSS 文本（是原生 GTK 对象，但没证"挂上了"）：
 * 若有人把 add_provider_for_display 删掉，to_string 与 css class 两条照样绿。
 * 这里改用 GTK 的样式**级联**观察：往实现那只 provider 里追加一条 color 规则，
 * 再新建一只带同款 class 的 GtkLabel，读它 style context 算出来的颜色。
 * 没挂到 display 就永远走默认色——这条会红，而且红在真实 GTK 对象上。
 * 探针（/tmp/p64b-probe.c）实测：无显示器、未排版时 get_color 也能读到
 * display 级 provider 的级联结果，plain label 是 1,1,1。 */
static void t_theme_provider_on_display(void) {
  const char *name = "widget_set_style：provider 真挂到 display（样式级联读得到）";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w, *probe, *plain;
  GtkCssProvider *prov;
  char cls[64] = "";
  char **classes;
  char *orig, *patched;
  GdkRGBA got_probe, got_plain;
  int i;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  c = moonui_native_widget_new(17, "", 0);
  if (c == 0) {
    bad(name, "Panel 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  if (moonui_native_widget_set_style(c, RGB(1, 2, 3), -1, 1000, -1, -1) != 0)
    bad(name, "set_style 返回非 0");
  prov = (GtkCssProvider *)g_object_get_data(G_OBJECT(w),
                                             "moonui-gtk-css-provider");
  classes = gtk_widget_get_css_classes(w);
  for (i = 0; classes != NULL && classes[i] != NULL; ++i) {
    if (strncmp(classes[i], "moonui-w-", 9) == 0) {
      snprintf(cls, sizeof(cls), "%s", classes[i]);
      break;
    }
  }
  g_strfreev(classes);
  if (prov == NULL || cls[0] == '\0') {
    bad(name, "拿不到 provider 或 class（样式根本没落到 GTK 对象上）");
  } else {
    orig = gtk_css_provider_to_string(prov);
    patched = g_strconcat(orig != NULL ? orig : "", ".", cls,
                          " { color: rgb(11,22,33); }\n", NULL);
    gtk_css_provider_load_from_data(prov, patched, -1);

    probe = gtk_label_new("probe");
    plain = gtk_label_new("probe");
    g_object_ref_sink(probe);
    g_object_ref_sink(plain);
    gtk_widget_add_css_class(probe, cls);
    gtk_style_context_get_color(gtk_widget_get_style_context(probe), &got_probe);
    gtk_style_context_get_color(gtk_widget_get_style_context(plain), &got_plain);

    /* rgb(11,22,33) → 0.043 / 0.086 / 0.129，误差带各 ±0.01。 */
    if (got_probe.red < 0.035 || got_probe.red > 0.055 ||
        got_probe.green < 0.078 || got_probe.green > 0.098 ||
        got_probe.blue < 0.121 || got_probe.blue > 0.141) {
      char d[160];
      snprintf(d, sizeof(d),
               "级联读到的不是 rgb(11,22,33)：实际 %.3f,%.3f,%.3f",
               got_probe.red, got_probe.green, got_probe.blue);
      bad(name, d);
    }
    /* 对照组：没挂 class 的 label 不该被这条规则染到；否则我们读到的可能
     * 只是全局默认色恰好撞上，判据就又变成"看不出差别"了。 */
    if (got_plain.red > 0.035 && got_plain.red < 0.055 &&
        got_plain.green > 0.078 && got_plain.green < 0.098 &&
        got_plain.blue > 0.121 && got_plain.blue < 0.141)
      bad(name, "没挂 class 的对照 label 也被染成同一个颜色");

    g_object_unref(probe);
    g_object_unref(plain);
    /* 复原：让实现自己重灌一次 CSS，别把探针追加的颜色留给后续判据。 */
    moonui_native_widget_set_style(c, -1, -1, -1, -1, -1);
    g_free(patched);
    g_free(orig);
  }
  moonui_native_widget_destroy(c);
  finish(name, before);
}

static void t_theme_kind_guard(void) {
  const char *name = "widget_set_style：不认识的 kind 静默忽略，空句柄报 -1";
  int before = g_fail;
  moonui_ptr c;
  GtkWidget *w;

  if (moonui_native_init() != 0) {
    skip(name, "gtk_init 失败（无显示器）");
    return;
  }
  if (moonui_native_widget_set_style(0, RGB(1, 2, 3), RGB(4, 5, 6),
                                    1000, 14000, 2) != -1)
    bad(name, "空句柄没报 -1");
  c = moonui_native_widget_new(18, "", 0); /* Custom：不在三处消费面里 */
  if (c == 0) {
    bad(name, "Custom 造不出来");
    return;
  }
  w = (GtkWidget *)(uintptr_t)c;
  if (moonui_native_widget_set_style(c, RGB(1, 2, 3), RGB(4, 5, 6),
                                    1000, 14000, 2) != 0)
    bad(name, "Custom 不该返回非 0");
  if (has_style_class(w))
    bad(name, "Custom 被偷偷挂了 CSS class");
  if (g_object_get_data(G_OBJECT(w), "moonui-gtk-css-provider") != NULL)
    bad(name, "Custom 被偷偷建了 provider");
  moonui_native_widget_destroy(c);
  finish(name, before);
}

int main(void) {
  t_fill_rect_opaque();
  t_fill_rect_rounded();
  t_fill_rect_alpha();
  t_read_pixel_bounds();
  t_clip_rect();
  t_translate_save_restore();
  t_line();
  t_arc_full();
  t_arc_half_direction();
  t_arc_zero_sweep();
  t_fill_polygon();
  t_fill_linear();
  t_blur_region();
  t_shadow();
  t_measure_text();
  t_draw_text();
  t_draw_image();
  t_error_paths();

  /* P6-1：控件挂载层（真 GTK4 结构，不需要显示器） */
  t_widget_new_kinds();
  t_widget_props();
  t_widget_attach_z();
  t_widget_bounds_origin();
  t_canvas_on_widget_window();

  /* P6-2：剪贴板（真 GDK；会临时占用系统剪贴板，每条自己恢复） */
  t_clipboard_roundtrip();
  t_clipboard_overwrite();
  t_clipboard_bad_args();

  /* P6-4：菜单栏与上下文菜单（真 GTK4；不碰显示服务器） */
  t_menu_install_dump();
  t_menu_set_checked();
  t_menu_click();
  t_menu_uninstall();
  t_menu_context();

  /* P6-4b：系统外观读数 + CSS 样式下发（真 GTK4 对象层） */
  t_theme_system_dark();
  t_theme_panel_css();
  t_theme_provider_on_display();
  t_theme_kind_guard();

  /* P6-3：对话框与文件面板（消息框真跑，会在桌面上闪一下；文件面板要 schema） */
  t_dialog_message();
  t_dialog_confirm_yes();
  t_dialog_confirm_no();
  t_dialog_bad_utf8();
  t_dialog_dismiss_bounds();
  t_file_dialog_cancel();
  t_file_dialog_save_folder();
  t_auto_answer_codes();

  printf("\n[canvas-pixel] pass=%d fail=%d skip=%d\n", g_pass, g_fail, g_skip);
  if (g_fail > 0) {
    printf("[canvas-pixel] 有判据红——上面每行 FAIL 都点明了期望值与实际值\n");
    return 1;
  }
  if (g_skip > 0) {
    printf("[canvas-pixel] 有判据被跳过（SKIP ≠ PASS）：%d 条，原因见上\n", g_skip);
  }
  return 0;
}
