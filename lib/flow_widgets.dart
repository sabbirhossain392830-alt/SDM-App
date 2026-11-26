import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Soft waves that flow across the speed card while something is downloading.
/// The animation only runs while [active] is true, so an idle card costs nothing.
class FlowWaves extends StatefulWidget {
  final bool active;

  /// 0..1, how strong the flow is (the faster the download, the livelier).
  final double energy;
  final Color color;
  final Widget child;
  final BorderRadius borderRadius;

  const FlowWaves({
    super.key,
    required this.active,
    required this.energy,
    required this.color,
    required this.borderRadius,
    required this.child,
  });

  @override
  State<FlowWaves> createState() => _FlowWavesState();
}

class _FlowWavesState extends State<FlowWaves>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(FlowWaves old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Stack(children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) => CustomPaint(
                  painter: _WavePainter(
                    t: _c.value,
                    strength: widget.active ? 0.25 + 0.75 * widget.energy : 0,
                    color: widget.color,
                  ),
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ]),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double t;
  final double strength;
  final Color color;
  const _WavePainter(
      {required this.t, required this.strength, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    const layers = [
      (amp: 7.0, len: 1.0, speed: 1.0, alpha: 0.16, base: 0.78),
      (amp: 9.0, len: 0.7, speed: -1.0, alpha: 0.12, base: 0.84),
      (amp: 5.0, len: 1.4, speed: 2.0, alpha: 0.10, base: 0.90),
    ];
    for (final l in layers) {
      final path = Path()..moveTo(0, size.height);
      for (double x = 0; x <= size.width; x += 4) {
        final y = size.height * l.base +
            math.sin((x / size.width) * 2 * math.pi * l.len * 1.6 +
                    t * 2 * math.pi * l.speed) *
                l.amp *
                strength;
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
          path, Paint()..color = color.withValues(alpha: l.alpha));
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) =>
      o.t != t || o.strength != strength || o.color != color;
}

/// Progress line with a light that travels along the filled part while the
/// download is running.
class FlowBar extends StatefulWidget {
  /// 0..1, or null when the size is unknown.
  final double? value;
  final bool running;
  final Color color;
  final double height;

  const FlowBar({
    super.key,
    required this.value,
    required this.running,
    required this.color,
    this.height = 6,
  });

  @override
  State<FlowBar> createState() => _FlowBarState();
}

class _FlowBarState extends State<FlowBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.running) _c.repeat();
  }

  @override
  void didUpdateWidget(FlowBar old) {
    super.didUpdateWidget(old);
    if (widget.running && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.running && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    if (v == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.height),
        child: LinearProgressIndicator(
          minHeight: widget.height,
          color: widget.color,
          backgroundColor: widget.color.withValues(alpha: 0.15),
        ),
      );
    }
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: v.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          builder: (_, value, __) => AnimatedBuilder(
            animation: _c,
            builder: (_, __) => CustomPaint(
              painter: _BarPainter(
                  value: value,
                  t: widget.running ? _c.value : -1,
                  color: widget.color),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  final double value;
  final double t; // -1 = no light
  final Color color;
  const _BarPainter(
      {required this.value, required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r),
        Paint()..color = color.withValues(alpha: 0.15));
    final w = size.width * value;
    if (w <= 0) return;
    final fill = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, size.height), r);
    canvas.drawRRect(fill, Paint()..color = color);
    if (t >= 0 && w > 24) {
      canvas.save();
      canvas.clipRRect(fill);
      final x = -40 + (w + 80) * t;
      final rect = Rect.fromLTWH(x - 36, 0, 72, size.height);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0),
          ]).createShader(rect),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BarPainter o) =>
      o.value != value || o.t != t || o.color != color;
}
