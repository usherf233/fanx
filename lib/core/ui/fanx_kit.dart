import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 共享 UI 套件：把"仪表盘"视觉语言固化成可复用组件。
/// 所有页面只组合这里的零件，不再各自手搓边框与字号。

// ---------------------------------------------------------------------------
// 发丝线
// ---------------------------------------------------------------------------

/// 1px 发丝线。比 Divider 更可控，可水平可垂直。
class HairLine extends StatelessWidget {
  const HairLine({super.key, this.vertical = false, this.color});

  final bool vertical;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.tokens.border;
    return vertical
        ? Container(width: 1, height: double.infinity, color: c)
        : Container(height: 1, width: double.infinity, color: c);
  }
}

// ---------------------------------------------------------------------------
// 等宽标签
// ---------------------------------------------------------------------------

/// 全大写等宽小标签，例如 `AGENT / 04`、`RUNNING`。
/// 它是整套界面里出现频率最高的视觉符号，负责"仪器面板"的调性。
class MetaTag extends StatelessWidget {
  const MetaTag(
    this.text, {
    super.key,
    this.color,
    this.size = 10,
    this.tracking = 1.4,
    this.inheritColor = false,
    this.leading,
    this.trailing,
    this.bracket = false,
  });

  final String text;
  final Color? color;
  final double size;

  /// 字距。编号类要拉得更开，标签类可以收一点。
  final double tracking;

  /// 是否跟随外层 DefaultTextStyle 的颜色（Tab 里用，让编号和标签一起变选中色）。
  final bool inheritColor;
  final Widget? leading;
  final Widget? trailing;

  /// 用方括号包裹，强化"读数"感。
  final bool bracket;

  @override
  Widget build(BuildContext context) {
    final fallback = color ?? context.tokens.textFaint;
    // 继承模式下把外层颜色压到 60% 亮度位置，编号比标签弱一档但仍跟随选中态。
    final inherited = DefaultTextStyle.of(context).style.color;
    final c = inheritColor
        ? (inherited ?? fallback).withValues(alpha: 0.6)
        : fallback;
    final label = Text(
      bracket ? '[$text]' : text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.monoLabel(color: c, size: size, tracking: tracking),
    );

    if (leading == null && trailing == null) return label;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[
          leading!,
          const SizedBox(width: FanxSpace.xs + 2),
        ],
        Flexible(child: label),
        if (trailing != null) ...[
          const SizedBox(width: FanxSpace.xs + 2),
          trailing!,
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 状态点
// ---------------------------------------------------------------------------

/// 状态指示灯。运行中带缓慢呼吸动画，静止时是实心圆点。
class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.pulsing = false,
    this.size = 6,
  });

  final Color color;
  final bool pulsing;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  // 必须在 initState 里创建：若用 late 惰性初始化，从未脉动过的圆点在 dispose
  // 时才第一次访问 controller，会在已 deactivate 的 element 上查 TickerMode 而崩溃。
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.pulsing) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );

    if (!widget.pulsing) return dot;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 0.28 * (1 - t),
              child: Container(
                width: widget.size * (2.4 + 1.2 * t),
                height: widget.size * (2.4 + 1.2 * t),
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: dot,
    );
  }
}

// ---------------------------------------------------------------------------
// 加载指示
// ---------------------------------------------------------------------------

/// 12 段刻度环。替代 Material 那个通用圆环：
/// 每一段按"点亮先后"衰减，转起来像仪表盘在扫描，和整套视觉语言一致。
class FanxSpinner extends StatefulWidget {
  const FanxSpinner({super.key, this.size = 16, this.color, this.thickness});

  final double size;
  final Color? color;

  /// 不传则按尺寸自适应。
  final double? thickness;

  @override
  State<FanxSpinner> createState() => _FanxSpinnerState();
}

class _FanxSpinnerState extends State<FanxSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _DialPainter(
          animation: _controller,
          color: widget.color ?? t.accent,
          thickness: widget.thickness,
          // 小尺寸下刻度会碎成星芒、看不出旋转方向，改用 270° 弧。
          compact: widget.size < 18,
          segments: 12,
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.animation,
    required this.color,
    required this.segments,
    required this.compact,
    this.thickness,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final int segments;
  final bool compact;
  final double? thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final stroke = thickness ?? math.max(1.1, radius * 0.2);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;

    if (compact) {
      // 两段圆弧：淡底弧定位，亮头弧指示方向。
      final rect = Rect.fromCircle(center: center, radius: radius - stroke / 2);
      final start = animation.value * 2 * math.pi - math.pi / 2;
      const sweep = 4.4;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = color.withValues(alpha: 0.16)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke,
      );
      canvas.drawArc(
        rect,
        start + sweep * 0.58,
        sweep * 0.42,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke,
      );
      return;
    }

    final head = animation.value * segments;
    final inner = radius * 0.44;
    final outer = radius - stroke / 2;

    for (var i = 0; i < segments; i++) {
      // age: 0 表示刚刚点亮，越接近 segments 越旧 → 越暗。
      // 尾段保留 0.2 的基础不透明度，否则远端完全消失，看起来只剩两个亮点。
      final age = (head - i) % segments;
      final weight = 1 - age / segments;
      paint.color = color.withValues(
        alpha: 0.12 + 0.88 * math.pow(weight, 2.4).toDouble(),
      );
      final angle = (i / segments) * 2 * math.pi - math.pi / 2;
      final dx = math.cos(angle);
      final dy = math.sin(angle);
      canvas.drawLine(
        center + Offset(dx * inner, dy * inner),
        center + Offset(dx * outer, dy * outer),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.thickness != thickness ||
      oldDelegate.segments != segments ||
      oldDelegate.compact != compact;
}

/// 骨架块：底块 + 一条琥珀扫光横向掠过。
/// 静态灰块看起来像卡死，扫光才能真正表达"还在动"。
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    required this.height,
    this.width,
    this.radius = FanxRadius.sm,
    this.delay = Duration.zero,
  });

  final double height;
  final double? width;
  final double radius;

  /// 错峰启动，让多个骨架块形成波浪而不是齐刷刷闪烁。
  final Duration delay;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.delay == Duration.zero) {
      _controller.repeat();
    } else {
      // 用 Timer 而不是 Future.delayed：dispose 时能取消，
      // 否则 widget 测试收尾会抱怨还有未完成的定时器。
      _startTimer = Timer(widget.delay, () {
        if (mounted) _controller.repeat();
      });
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(
        painter: _SkeletonPainter(
          animation: _controller,
          base: t.isDark ? t.surfaceRaised : t.surfaceSunken,
          accent: t.accent,
          radius: widget.radius,
          strength: t.isDark ? 0.22 : 0.13,
        ),
      ),
    );
  }
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.animation,
    required this.base,
    required this.accent,
    required this.radius,
    required this.strength,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color base;
  final Color accent;
  final double radius;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    // 底色随同一控制器轻微呼吸：扫光某一帧可能恰好在块外，
    // 有了呼吸，任何时刻都能看出"这块还在加载"。
    final pulse = 0.5 + 0.5 * math.sin(animation.value * 2 * math.pi);
    canvas.drawRRect(
      rrect,
      Paint()..color = Color.lerp(base, accent, 0.012 + 0.03 * pulse)!,
    );

    canvas.save();
    canvas.clipRRect(rrect);

    final band = math.max(size.width * 0.32, 36.0);
    final travel = size.width + band * 2;
    final x = -band + travel * animation.value;
    final rect = Rect.fromLTWH(x, 0, band, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            accent.withValues(alpha: 0),
            accent.withValues(alpha: strength),
            accent.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SkeletonPainter oldDelegate) =>
      oldDelegate.base != base ||
      oldDelegate.accent != accent ||
      oldDelegate.strength != strength ||
      oldDelegate.radius != radius;
}

/// 居中加载块：刻度环 + 一行等宽状态文字。
class LoadingBlock extends StatelessWidget {
  const LoadingBlock({super.key, this.label, this.size = 22});

  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FanxSpinner(size: size),
          if (label != null) ...[
            const SizedBox(height: FanxSpace.md),
            MetaTag(label!.toUpperCase(), size: 9, tracking: 1.8),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 分区卡片
// ---------------------------------------------------------------------------

/// 标准面板：序号 + 标题 + 副标题，下面一条发丝线，再是内容。
/// 序号是"仪表盘"记忆点的一部分，可省略。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.index,
    this.subtitle,
    this.action,
    this.child,
    this.padding = const EdgeInsets.all(FanxSpace.lg),
    this.accent = false,
  });

  final String title;
  final String? index;
  final String? subtitle;
  final Widget? action;
  final Widget? child;
  final EdgeInsets padding;

  /// 标题左侧换成琥珀色方块，用于页面主区块。
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(FanxRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              padding.left,
              padding.top,
              padding.right,
              FanxSpace.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (accent) ...[
                  Container(
                    width: 3,
                    height: 14,
                    margin: const EdgeInsets.only(top: 3, right: FanxSpace.sm),
                    color: t.accent,
                  ),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.titleMedium,
                            ),
                          ),
                          if (index != null) ...[
                            const SizedBox(width: FanxSpace.sm),
                            MetaTag(index!.toUpperCase(), size: 9.5),
                          ],
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: FanxSpace.xs),
                        Text(subtitle!, style: context.texts.bodySmall),
                      ],
                    ],
                  ),
                ),
                if (action != null) ...[
                  const SizedBox(width: FanxSpace.sm),
                  action!,
                ],
              ],
            ),
          ),
          if (child != null) ...[
            HairLine(color: t.border),
            Padding(
              padding: EdgeInsets.fromLTRB(
                padding.left,
                FanxSpace.md,
                padding.right,
                padding.bottom,
              ),
              child: child!,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 页面头
// ---------------------------------------------------------------------------

/// 二级页面的统一页头：编号 + 英文栏目名 + 中文大标题 + 一句说明。
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.index,
    required this.kicker,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String index;
  final String kicker;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.only(bottom: FanxSpace.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      index,
                      style: context.monoLabel(
                        color: t.accent,
                        size: 10,
                        tracking: 2,
                      ),
                    ),
                    const SizedBox(width: FanxSpace.sm),
                    Container(width: 14, height: 1, color: t.borderStrong),
                    const SizedBox(width: FanxSpace.sm),
                    MetaTag(kicker.toUpperCase(), size: 9, tracking: 1.8),
                  ],
                ),
                const SizedBox(height: FanxSpace.sm + 2),
                Text(title, style: context.cnDisplay(size: 24, height: 1.3)),
                if (subtitle != null) ...[
                  const SizedBox(height: FanxSpace.xs + 2),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Text(
                      subtitle!,
                      style: context.texts.bodySmall?.copyWith(
                        color: t.textMuted,
                        height: 1.65,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: FanxSpace.lg), action!],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 空态
// ---------------------------------------------------------------------------

/// 空态：虚线框 + 等宽编号 + 一句提示。避免"一片空白 + 一个灰图标"。
/// 虚线描边容器。用于空态与"可添加的空槽"，视觉上区别于实心的已有项。
class DashedBox extends StatelessWidget {
  const DashedBox({
    super.key,
    required this.child,
    this.color,
    this.radius = FanxRadius.md,
    this.padding = EdgeInsets.zero,
    this.fill,
  });

  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsets padding;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return CustomPaint(
      painter: _DashedRectPainter(color: color ?? t.border, radius: radius),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.hint,
    this.icon,
    this.action,
    this.code,
  });

  final String title;
  final String? hint;
  final IconData? icon;
  final Widget? action;
  final String? code;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Center(
      child: DashedBox(
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FanxSpace.xl,
            vertical: FanxSpace.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 22, color: t.textFaint),
                const SizedBox(height: FanxSpace.md),
              ],
              Text(
                title,
                style: context.texts.titleMedium?.copyWith(color: t.text),
              ),
              if (hint != null) ...[
                const SizedBox(height: FanxSpace.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(
                    hint!,
                    textAlign: TextAlign.center,
                    style: context.texts.bodySmall,
                  ),
                ),
              ],
              if (code != null) ...[
                const SizedBox(height: FanxSpace.md),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FanxSpace.sm,
                    vertical: FanxSpace.xs + 2,
                  ),
                  decoration: BoxDecoration(
                    color: t.surfaceSunken,
                    borderRadius: BorderRadius.circular(FanxRadius.xs),
                    border: Border.all(color: t.border),
                  ),
                  child: SelectableText(
                    code!,
                    style: context.mono(size: 11.5, color: t.textMuted),
                  ),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: FanxSpace.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color, this.radius = FanxRadius.md});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    const dash = 5.0;
    const gap = 5.0;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
          Radius.circular(radius),
        ),
      );

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

// ---------------------------------------------------------------------------
// 提示条
// ---------------------------------------------------------------------------

/// 行内提示：错误 / 成功 / 中性，左侧一条状态色竖线，不用整块高饱和底色。
class InlineNotice extends StatelessWidget {
  const InlineNotice({
    super.key,
    required this.message,
    this.tone = NoticeTone.danger,
    this.onDismiss,
  });

  final String message;
  final NoticeTone tone;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = switch (tone) {
      NoticeTone.danger => t.danger,
      NoticeTone.success => t.success,
      NoticeTone.neutral => t.accent,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        FanxSpace.md,
        FanxSpace.sm + 2,
        FanxSpace.sm,
        FanxSpace.sm + 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: color, width: 2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: context.texts.bodySmall?.copyWith(
                color: t.text,
                height: 1.45,
              ),
            ),
          ),
          if (onDismiss != null)
            InkWell(
              onTap: onDismiss,
              borderRadius: BorderRadius.circular(FanxRadius.xs),
              child: Padding(
                padding: const EdgeInsets.all(FanxSpace.xs),
                child: Icon(Icons.close, size: 13, color: t.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

enum NoticeTone { danger, success, neutral }

// ---------------------------------------------------------------------------
// 键盘提示
// ---------------------------------------------------------------------------

/// 键帽提示，例如 `⏎ 发送`。只在桌面端出现。
class KeyHint extends StatelessWidget {
  const KeyHint({super.key, required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FanxSpace.xs + 1,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: t.surfaceSunken,
        borderRadius: BorderRadius.circular(FanxRadius.xs),
        border: Border.all(color: color ?? t.borderStrong),
      ),
      child: Text(
        label,
        style: context.mono(size: 10, color: color ?? t.textMuted),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 背景
// ---------------------------------------------------------------------------

/// 页面背景：极淡网格 + 左上角琥珀光晕。
/// 让"纯色平铺"消失，但透明度低到不影响文字对比度。
class GridBackdrop extends StatelessWidget {
  const GridBackdrop({super.key, this.child, this.glow = true});

  final Widget? child;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _GridPainter(
              color: t.isDark ? Colors.white : Colors.black,
            ),
          ),
        ),
        if (glow)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.85, -0.95),
                    radius: 1.1,
                    colors: [
                      t.accent.withValues(alpha: t.isDark ? 0.10 : 0.07),
                      t.bg.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const step = 32.0;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.028)
      ..strokeWidth = 1;

    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.color != color;
}

// ---------------------------------------------------------------------------
// 入场动画
// ---------------------------------------------------------------------------

/// 错峰入场：透明度 + 上移。delay 按 70ms 递增，整体控制在 600ms 内。
/// 遵守系统"减少动效"设置（MediaQuery.disableAnimations）。
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = 14,
  });

  final Widget child;
  final int index;
  final double offset;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FanxMotion.slow,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: FanxMotion.out,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: Offset(0, widget.offset / 100),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.status != AnimationStatus.dismissed) return;

    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _controller.value = 1;
      return;
    }

    final delay = (widget.index.clamp(0, 5)) * 70;
    Future<void>.delayed(Duration(milliseconds: delay), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, child) => Opacity(
        opacity: _fade.value.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, _slide.value.dy * 100),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 把 0..1 的进度画成一段等宽刻度，用在页脚的"仪表盘"装饰上。
class TickStrip extends StatelessWidget {
  const TickStrip({super.key, this.count = 40, this.height = 8, this.color});

  final int count;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _TickPainter(color: color ?? t.border, count: count),
      ),
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter({required this.color, required this.count});

  final Color color;
  final int count;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final step = size.width / math.max(count - 1, 1);

    for (var i = 0; i < count; i++) {
      final tall = i % 5 == 0;
      final h = tall ? size.height : size.height * 0.5;
      final x = i * step;
      canvas.drawLine(
        Offset(x, size.height - h),
        Offset(x, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TickPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.count != count;
}
