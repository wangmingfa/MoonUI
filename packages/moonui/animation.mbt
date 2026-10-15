///|
/// 动画第一版（`T84`，2026-10-15）：插值计算归 Core（"Core 算、后端摆"的分工）。
///
/// 后端驱动（AppKit 隐式动画那套）被否——行为分叉各平台、Mock 无法同值判据，
/// 而"同值"是这个仓库测试文化的地基。本模块因此是**纯 MoonBit**：曲线是纯函数，
/// 插值账不读时钟（时刻由 pump 注入）、不碰任何平台 API，wasm 口径照进。
///
/// 分工：本模块只算"曲线在归一时刻的进度"和"激活期的插值账"（span）；存值时把
/// 变更点记成动画起点（from/to/curve，起跑时刻由 pump 第一圈补记）在 `widget.mbt`，
/// 逐帧推进在 `app.mbt` 的 `pump_animations`。后端只收逐帧推下来的值——
/// bounds 走 `set_widget_bounds`、opacity 走 `set_widget_opacity`（`T84` 破 §32
/// 豁免的那条），中间帧与落点走的是同一条 ABI。
///
/// 动画是糖，落点即真相：Core 的 frame 永远是布局真相（变更点当场落），后端显示
/// 由 pump 逐帧追；退场那一帧推的是**精确的 to**，不做插值——浮点上
/// `lerp(a, b, 1)` 未必逐位等于 b（`(b-a)+a` 会差一个ulp），判据④"落点后与无动画树
/// 逐位同值"靠的就是这条绕行。

///|
/// 曲线库第一版（`T84`）：SwiftUI 惯用的那四条，纯 MoonBit 一行不落平台。
///
/// 三条缓动是 CSS 同名曲线的**三次多项式近似**（easeInCubic / easeOutCubic /
/// easeInOutCubic——第一版不做 cubic-bezier 求根，多项式端点精确、单调、可逐帧
/// 断言；真要逼真的贝塞尔按 `T18` 判据分）。四条在 t=0 处都是 0、t=1 处都是 1，
/// 所以落点精确、起跑无跳。
pub(all) enum AnimationCurve {
  Linear
  EaseIn
  EaseOut
  EaseInOut
} derive(Debug, Eq)

///|
/// 曲线在归一时刻 t（0..1）的归一进度（0..1）。纯函数：同曲线同 t 同值——
/// 判据①"动画是纯函数"的落点。
pub fn AnimationCurve::progress(self : AnimationCurve, t : Double) -> Double {
  match self {
    Linear => t
    EaseIn => t * t * t
    EaseOut => 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
    EaseInOut =>
      if t < 0.5 {
        4.0 * t * t * t
      } else {
        let u = 2.0 - 2.0 * t
        1.0 - u * u * u / 2.0
      }
  }
}

///|
/// 隐式动画的时长（毫秒）。第一版固定 300——SwiftUI 隐式动画的惯用档，
/// `.animation(curve~)` 只收曲线（SwiftUI 形），不收时长；显式控制器
/// （Flutter 形）不做，序列/反向/循环场景将来按 `T18` 判据分。
const ANIMATION_DURATION_MS = 300

///|
/// bounds 的激活期插值账：from 是变更点时后端**当下显示的值**（shown，不是
/// 上一份真相——被中断的动画从显示值续跑才不会跳），to 是新真相（= Core 的
/// frame，变更点当场落）。`start_ms` 是起跑时刻，由 pump 第一圈补记（-1 =
/// 未起跑）——变更点在 `set_bounds` 里没有时刻可读，动画模块一行不读时钟。
struct BoundsSpan {
  curve : AnimationCurve
  mut start_ms : Int32
  from : LogicalRect
  to : LogicalRect
}

///|
/// opacity 的激活期插值账，与 bounds 同一条形状、同一套规则（起跑补记、
/// 逐帧推、退场推精确落点）。
struct OpacitySpan {
  curve : AnimationCurve
  mut start_ms : Int32
  from : Double
  to : Double
}

///|
/// 一帧的插值结果：矩形逐分量线性混合。只用于激活期的**中间帧**——退场帧
/// 推精确 to，不走这里（见模块头注的浮点说明）。
fn anim_lerp_rect(
  from : LogicalRect,
  to : LogicalRect,
  k : Double,
) -> LogicalRect {
  LogicalRect(
    LogicalPoint(
      from.origin.x + (to.origin.x - from.origin.x) * k,
      from.origin.y + (to.origin.y - from.origin.y) * k,
    ),
    LogicalSize(
      from.size.width + (to.size.width - from.size.width) * k,
      from.size.height + (to.size.height - from.size.height) * k,
    ),
  )
}

///|
/// opacity 的线性混合，同上（中间帧专用）。
fn anim_lerp_scalar(from : Double, to : Double, k : Double) -> Double {
  from + (to - from) * k
}

///|
/// opacity 进动画通道前夹到 0..1。样式的语义是"1.0 全显、0.0 全隐"，
/// 写出界的值进通道也按这个语义夹（§33：可疑输入在唯一一处拦住）。
fn anim_clamp01(v : Double) -> Double {
  if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// 纯函数自查（判据①的底座）：四条曲线端点精确、样本值硬断言、逐样本单调。
test "T84 曲线库：四条曲线端点精确、样本值与单调性" {
  let curves = [Linear, EaseIn, EaseOut, EaseInOut]
  for c in curves {
    assert_eq(c.progress(0.0), 0.0)
    assert_eq(c.progress(1.0), 1.0)
  }
  // 样本值：三次多项式近似的硬账（不算浮点侥幸，全是确定的乘法）
  assert_eq(Linear.progress(0.25), 0.25)
  assert_eq(EaseIn.progress(0.5), 0.125)
  assert_eq(EaseOut.progress(0.5), 0.875)
  assert_eq(EaseInOut.progress(0.25), 0.0625)
  assert_eq(EaseInOut.progress(0.5), 0.5)
  assert_eq(EaseInOut.progress(0.75), 0.9375)
  // 单调性：样本网格上逐对不降（动画不该倒着走）
  let grid = [0.0, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.0]
  for c in curves {
    let mut prev = -1.0
    for t in grid {
      let k = c.progress(t)
      assert_true(k >= prev)
      prev = k
    }
  }
}
