import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Animated background: rising beer-foam bubbles erupting from the bottom
/// over an amber "beer" gradient, with a wavy foam line along the base.
/// Bubbles now react to touch: tapping/dragging near a bubble kicks it
/// away in a random direction, and it springs back to its normal drifting
/// motion afterwards.
/// (Class name kept as `BlackHoleBackground` so existing imports/usages
/// in login_page.dart, register_page.dart, forgot_password_page.dart and
/// profile_page.dart keep working without changes.)
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
  final int bubbleCount;

  const BlackHoleBackground({super.key, this.bubbleCount = 90});

  @override
  State<BlackHoleBackground> createState() => BlackHoleBackgroundState();
}

/// Public State so parent pages (login/register/forgot-password/profile)
/// can hold a `GlobalKey<BlackHoleBackgroundState>` and call [kickAt]
/// directly from a top-level `Listener`. This is necessary because on most
/// of those pages, the login/register form (TextFields, buttons, a
/// full-screen SingleChildScrollView, etc.) is stacked ON TOP of this
/// background and its own gesture handling normally swallows every touch
/// before it ever reaches a GestureDetector living inside this widget.
class BlackHoleBackgroundState extends State<BlackHoleBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _elapsed = 0;
  double _lastElapsed = 0;
  late List<_Bubble> _ambient;
  final List<_Bubble> _bursts = [];
  bool _ready = false;
  final math.Random _rnd = math.Random();
  double _nextBurstAt = 1.2;
  Size _paintSize = Size.zero;
  Offset? _lastTapLocal;
  double _lastTapTime = -10;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final t = elapsed.inMilliseconds / 1000.0;
      final dt = (t - _lastElapsed).clamp(0.0, 0.05);
      _lastElapsed = t;
      setState(() {
        _elapsed = t;
        if (_ready) _update(dt);
      });
    });
    _ticker.start();
  }

  void _ensureBubbles() {
    if (_ready) return;
    _ambient = List.generate(
      widget.bubbleCount,
          (_) => _spawnBubble(randomY: true),
    );
    _ready = true;
  }

  _Bubble _spawnBubble({bool randomY = false, bool burst = false, double burstX = 0.5}) {
    final radius = burst ? _rnd.nextDouble() * 3.5 + 1.5 : _rnd.nextDouble() * 4.5 + 1.5;
    return _Bubble(
      x: burst
          ? (burstX + (_rnd.nextDouble() - 0.5) * 0.14).clamp(0.0, 1.0)
          : _rnd.nextDouble(),
      y: randomY ? _rnd.nextDouble() : 1.05 + _rnd.nextDouble() * 0.1,
      radius: radius,
      speed: burst ? _rnd.nextDouble() * 0.15 + 0.13 : _rnd.nextDouble() * 0.045 + 0.018,
      wobbleAmp: _rnd.nextDouble() * 0.015 + 0.005,
      wobbleSpeed: _rnd.nextDouble() * 0.7 + 0.25,
      phase: _rnd.nextDouble() * 2 * math.pi,
      baseAlpha: _rnd.nextDouble() * 0.5 + 0.35,
    );
  }

  void _update(double dt) {
    // Ambient bubbles: steady stream rising and looping from the bottom
    for (final b in _ambient) {
      b.y -= b.speed * dt;
      if (b.y < -0.05) {
        final fresh = _spawnBubble();
        b.x = fresh.x;
        b.y = 1.05 + _rnd.nextDouble() * 0.1;
        b.radius = fresh.radius;
        b.speed = fresh.speed;
        b.wobbleAmp = fresh.wobbleAmp;
        b.wobbleSpeed = fresh.wobbleSpeed;
        b.phase = fresh.phase;
        b.baseAlpha = fresh.baseAlpha;
        // reset any kick state when the bubble recycles
        b.ox = 0;
        b.oy = 0;
        b.vx = 0;
        b.vy = 0;
      }
    }

    // Burst bubbles: fast eruption that decelerates, then removed at top
    for (var i = _bursts.length - 1; i >= 0; i--) {
      final b = _bursts[i];
      b.y -= b.speed * dt;
      b.speed = math.max(b.speed * 0.975, 0.02);
      if (b.y < -0.05) {
        _bursts.removeAt(i);
      }
    }

    // Periodic foam eruption from a random spot along the bottom
    if (_elapsed > _nextBurstAt) {
      _nextBurstAt = _elapsed + 3.0 + _rnd.nextDouble() * 3.5;
      final burstX = _rnd.nextDouble();
      final count = 14 + _rnd.nextInt(10);
      for (var i = 0; i < count; i++) {
        _bursts.add(_spawnBubble(burst: true, burstX: burstX));
      }
    }

    // Spring-damped "kick" offset for every bubble (ambient + burst).
    // This is what makes a touched bubble fly away and then drift back
    // onto its normal path instead of staying permanently displaced.
    const springK = 90.0;
    const damping = 6.0;
    for (final b in _ambient) {
      _applyKickPhysics(b, dt, springK, damping);
    }
    for (final b in _bursts) {
      _applyKickPhysics(b, dt, springK, damping);
    }
  }

  void _applyKickPhysics(_Bubble b, double dt, double springK, double damping) {
    if (b.ox == 0 && b.oy == 0 && b.vx == 0 && b.vy == 0) return;
    final ax = -springK * b.ox - damping * b.vx;
    final ay = -springK * b.oy - damping * b.vy;
    b.vx += ax * dt;
    b.vy += ay * dt;
    b.ox += b.vx * dt;
    b.oy += b.vy * dt;
    // Snap tiny residual jitter to zero so bubbles fully settle.
    if (b.ox.abs() < 0.05 && b.oy.abs() < 0.05 && b.vx.abs() < 0.5 && b.vy.abs() < 0.5) {
      b.ox = 0;
      b.oy = 0;
      b.vx = 0;
      b.vy = 0;
    }
  }

  /// Kicks any bubble near [localPosition] away in a random-ish direction,
  /// stronger the closer the bubble is to the touch point.
  /// Call this from a parent page (via GlobalKey) with a GLOBAL pointer
  /// position — e.g. from a top-level `Listener(onPointerDown: ...)` that
  /// wraps the whole page. This is the reliable entry point when this
  /// widget is buried under other UI that would otherwise steal the touch.
  void kickAt(Offset globalPosition, {double strength = 1.0}) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final local = renderObject.globalToLocal(globalPosition);
    _kickBubblesNear(local, _paintSize, strength: strength);
  }

  void _kickBubblesNear(Offset localPosition, Size size, {double strength = 1.0}) {
    // Debug ripple marker: shows exactly where a touch was registered,
    // regardless of whether any bubble was close enough to be hit. If you
    // tap and never see this ripple, the touch isn't reaching this widget
    // at all (something else above it is intercepting it).
    _lastTapLocal = localPosition;
    _lastTapTime = _elapsed;

    if (size.width <= 0 || size.height <= 0) return;
    final touchRadius = size.shortestSide * 0.30;
    void kickList(List<_Bubble> list) {
      for (final b in list) {
        final bx = b.x * size.width + b.ox;
        final by = b.y * size.height + b.oy;
        final dx = bx - localPosition.dx;
        final dy = by - localPosition.dy;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < touchRadius) {
          final falloff = 1.0 - (dist / touchRadius);
          // base direction away from touch, with some randomness so it
          // looks like a chaotic little scatter rather than a neat ring
          final baseAngle = math.atan2(dy, dx);
          final angle = baseAngle + (_rnd.nextDouble() - 0.5) * 1.4;
          final power = (420 + _rnd.nextDouble() * 380) * falloff * strength;
          b.vx += math.cos(angle) * power;
          b.vy += math.sin(angle) * power - 60; // slight upward pop
        }
      }
    }

    kickList(_ambient);
    kickList(_bursts);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureBubbles();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (details) => _kickBubblesNear(details.localPosition, _paintSize),
      onPanStart: (details) => _kickBubblesNear(details.localPosition, _paintSize),
      onPanUpdate: (details) =>
          _kickBubblesNear(details.localPosition, _paintSize, strength: 0.5),
      child: CustomPaint(
        painter: _BeerPainter(
          time: _elapsed,
          bubbles: [..._ambient, ..._bursts],
          onSizeKnown: (s) => _paintSize = s,
          tapPos: _lastTapLocal,
          tapTime: _lastTapTime,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _Bubble {
  double x; // normalized 0..1
  double y; // normalized 0 (top) .. ~1.15 (below bottom edge, at spawn)
  double radius;
  double speed; // normalized units per second (rising)
  double wobbleAmp;
  double wobbleSpeed;
  double phase;
  double baseAlpha;

  // Touch-kick state: pixel offset applied on top of (x, y), plus its
  // velocity. Both spring back toward zero over time (see
  // _applyKickPhysics), which produces the "scatter then settle" motion.
  double ox;
  double oy;
  double vx;
  double vy;

  _Bubble({
    required this.x,
    required this.y,
    required this.radius,
    required this.speed,
    required this.wobbleAmp,
    required this.wobbleSpeed,
    required this.phase,
    required this.baseAlpha,
    this.ox = 0,
    this.oy = 0,
    this.vx = 0,
    this.vy = 0,
  });
}

class _BeerPainter extends CustomPainter {
  final double time;
  final List<_Bubble> bubbles;
  final ValueChanged<Size>? onSizeKnown;
  final Offset? tapPos;
  final double tapTime;

  _BeerPainter({
    required this.time,
    required this.bubbles,
    this.onSizeKnown,
    this.tapPos,
    this.tapTime = -10,
  });

  @override
  void paint(Canvas canvas, Size size) {
    onSizeKnown?.call(size);
    final rect = Offset.zero & size;

    // Beer-amber background gradient (dark at top -> golden at bottom)
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF3E2410), Color(0xFF8A4B0F), Color(0xFFC97A1A)],
        stops: [0.0, 0.6, 1.0],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    _drawBubbles(canvas, size);
    _drawFoamLine(canvas, size);
    _drawTapRipple(canvas);
  }

  // TEMPORARY DEBUG VISUAL: draws an expanding, fading ring wherever a
  // tap/drag was registered, for ~0.5s. If you tap the screen and never
  // see this ring appear, the gesture isn't reaching this widget at all —
  // something else drawn on top of it is swallowing the touch. If you DO
  // see the ring but the bubbles don't move, then the touch is fine and
  // the issue is in the bubble-kick physics instead. Remove this method
  // (and its call above) once confirmed working.
  void _drawTapRipple(Canvas canvas) {
    if (tapPos == null) return;
    final age = time - tapTime;
    if (age < 0 || age > 0.5) return;
    final progress = age / 0.5;
    final radius = 10 + progress * 60;
    final opacity = (1.0 - progress).clamp(0.0, 1.0);
    canvas.drawCircle(
      tapPos!,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.redAccent.withOpacity(opacity),
    );
  }

  void _drawBubbles(Canvas canvas, Size size) {
    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    for (final b in bubbles) {
      final wobble = math.sin(time * b.wobbleSpeed + b.phase) * b.wobbleAmp;
      final px = (b.x + wobble) * size.width + b.ox;
      final py = b.y * size.height + b.oy;

      // fade in near the bottom edge, fade out near the very top
      double alpha = b.baseAlpha;
      if (b.y > 0.95) alpha *= (1.0 - b.y) / 0.05;
      if (b.y < 0.08) alpha *= (b.y / 0.08).clamp(0.0, 1.0);
      alpha = alpha.clamp(0.0, 1.0);

      final center = Offset(px, py);

      fill.color = Colors.white.withOpacity(alpha * 0.55);
      canvas.drawCircle(center, b.radius, fill);

      stroke.color = Colors.white.withOpacity(alpha * 0.8);
      canvas.drawCircle(center, b.radius, stroke);

      // tiny highlight for a glossy bubble look
      fill.color = Colors.white.withOpacity(alpha * 0.9);
      canvas.drawCircle(
        Offset(px - b.radius * 0.35, py - b.radius * 0.35),
        b.radius * 0.25,
        fill,
      );
    }
  }

  void _drawFoamLine(Canvas canvas, Size size) {
    final path = Path();
    const waveHeight = 10.0;
    final baseY = size.height * 0.985;
    path.moveTo(0, size.height);
    path.lineTo(0, baseY);
    const step = 18.0;
    for (double x = 0; x <= size.width + step; x += step) {
      final y = baseY +
          math.sin((x / 40) + time * 0.6) * waveHeight * 0.4 +
          math.sin((x / 90) - time * 0.35) * waveHeight * 0.3;
      path.lineTo(x, y);
    }
    path.lineTo(size.width, size.height);
    path.close();

    canvas.drawPath(path, Paint()..color = Colors.white.withOpacity(0.55));
  }

  @override
  bool shouldRepaint(covariant _BeerPainter oldDelegate) => true;
}