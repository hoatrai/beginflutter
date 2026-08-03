import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Animated background: a starfield with a slowly drifting black hole
/// (event horizon + photon ring + simple gravitational-lensing effect
/// on nearby stars). Drop this widget behind your UI, e.g.:
///
/// ```dart
/// Stack(
///   children: [
///     const Positioned.fill(child: BlackHoleBackground()),
///     // ... rest of your login form ...
///   ],
/// )
/// ```
class BlackHoleBackground extends StatefulWidget {
  final int starCount;

  const BlackHoleBackground({super.key, this.starCount = 220});

  @override
  State<BlackHoleBackground> createState() => _BlackHoleBackgroundState();
}

class _BlackHoleBackgroundState extends State<BlackHoleBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _elapsed = 0; // seconds
  late List<_Star> _stars;
  bool _starsReady = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() {
        _elapsed = elapsed.inMilliseconds / 1000.0;
      });
    });
    _ticker.start();
  }

  void _ensureStars() {
    if (_starsReady) return;
    final rnd = math.Random();
    _stars = List.generate(widget.starCount, (_) {
      return _Star(
        // normalized position (0..1), scaled to canvas size at paint time
        x: rnd.nextDouble(),
        y: rnd.nextDouble(),
        radius: rnd.nextDouble() * 1.3 + 0.3,
        baseAlpha: rnd.nextDouble() * 0.7 + 0.3,
        twinkleSpeed: rnd.nextDouble() * 1.6 + 0.4,
        phase: rnd.nextDouble() * 2 * math.pi,
      );
    });
    _starsReady = true;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureStars();
    return CustomPaint(
      painter: _BlackHolePainter(time: _elapsed, stars: _stars),
      size: Size.infinite,
    );
  }
}

class _Star {
  final double x, y; // normalized 0..1
  final double radius;
  final double baseAlpha;
  final double twinkleSpeed;
  final double phase;

  _Star({
    required this.x,
    required this.y,
    required this.radius,
    required this.baseAlpha,
    required this.twinkleSpeed,
    required this.phase,
  });
}

class _BlackHolePainter extends CustomPainter {
  final double time; // seconds elapsed
  final List<_Star> stars;

  // Tunable constants
  static const double driftSpeed = 0.045;
  static const double marginX = 0.30;
  static const double marginY = 0.22;

  _BlackHolePainter({required this.time, required this.stars});

  Offset _holeCenter(Size size) {
    final t = time;
    final dx = size.width / 2 +
        math.sin(t * driftSpeed) * size.width * marginX +
        math.sin(t * driftSpeed * 2.1 + 1.1) * size.width * (marginX * 0.3);
    final dy = size.height / 2 +
        math.cos(t * driftSpeed * 0.7) * size.height * marginY +
        math.cos(t * driftSpeed * 1.8 + 0.6) * size.height * (marginY * 0.35);
    return Offset(dx, dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Background
    canvas.drawRect(rect, Paint()..color = Colors.black);

    final holeCenter = _holeCenter(size);
    final eventHorizon = size.shortestSide * 0.045;
    final lensRadius = size.shortestSide * 0.30;
    final ringRadius = eventHorizon * 1.6;

    _drawStars(canvas, size, holeCenter, eventHorizon, lensRadius);
    _drawLensGlow(canvas, holeCenter, eventHorizon, lensRadius);
    _drawPhotonRing(canvas, holeCenter, eventHorizon, ringRadius);
    _drawEventHorizon(canvas, holeCenter, eventHorizon);
  }

  void _drawStars(Canvas canvas, Size size, Offset hole, double eventHorizon,
      double lensRadius) {
    final dotPaint = Paint();
    final linePaint = Paint()..style = PaintingStyle.stroke;

    for (final s in stars) {
      final pos = Offset(s.x * size.width, s.y * size.height);
      final d = pos - hole;
      final dist = d.distance;
      final alpha = s.baseAlpha *
          (0.55 + 0.45 * math.sin(time * s.twinkleSpeed + s.phase));

      if (dist < lensRadius && dist > eventHorizon * 0.9) {
        // Swallowed if too close
        if (dist < eventHorizon * 1.3) continue;

        // Gravitational lensing: bend the star into a curved streak
        final bendStrength = 1 - (dist - eventHorizon) / (lensRadius - eventHorizon);
        final angle = math.atan2(d.dy, d.dx);
        final swirl = angle + bendStrength * 1.4;
        final displaced = eventHorizon + (dist - eventHorizon) * (1 - bendStrength * 0.35);

        final sx = hole.dx + math.cos(swirl) * displaced;
        final sy = hole.dy + math.sin(swirl) * displaced;

        final tailAngle = swirl - 0.25;
        final tx = hole.dx + math.cos(tailAngle) * displaced;
        final ty = hole.dy + math.sin(tailAngle) * displaced;

        linePaint
          ..color = Color.fromRGBO(200, 220, 255, (alpha * bendStrength * 0.8).clamp(0, 1))
          ..strokeWidth = s.radius;
        canvas.drawLine(Offset(tx, ty), Offset(sx, sy), linePaint);
      } else if (dist >= lensRadius) {
        dotPaint.color = Colors.white.withOpacity(alpha.clamp(0, 1));
        canvas.drawCircle(pos, s.radius, dotPaint);
      }
    }
  }

  void _drawLensGlow(Canvas canvas, Offset hole, double eventHorizon, double lensRadius) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withOpacity(0.10),
          const Color(0xFFB4C8FF).withOpacity(0.05),
          Colors.transparent,
        ],
        stops: const [0.0, 0.3, 1.0],
      ).createShader(Rect.fromCircle(center: hole, radius: lensRadius));
    canvas.drawCircle(hole, lensRadius, paint);
  }

  void _drawPhotonRing(Canvas canvas, Offset hole, double eventHorizon, double ringRadius) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFFF0D2).withOpacity(0.9),
          const Color(0xFFFFB478).withOpacity(0.35),
          const Color(0xFFFF8C50).withOpacity(0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: hole, radius: ringRadius * 1.4));
    canvas.drawCircle(hole, ringRadius, paint);
  }

  void _drawEventHorizon(Canvas canvas, Offset hole, double eventHorizon) {
    canvas.drawCircle(hole, eventHorizon, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(covariant _BlackHolePainter oldDelegate) => true;
}