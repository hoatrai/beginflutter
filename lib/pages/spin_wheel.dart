import 'dart:math';
import 'package:flutter/material.dart';

class SpinWheel extends StatefulWidget {
  final List<String> items;
  final Function(int index)? onFinish;

  const SpinWheel({
    super.key,
    required this.items,
    this.onFinish,
  });

  @override
  State<SpinWheel> createState() => SpinWheelState();
}

class SpinWheelState extends State<SpinWheel>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  double currentAngle = 0;
  bool isSpinning = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );

    // 🔥 init animation tránh crash
    _animation = AlwaysStoppedAnimation(0);

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        isSpinning = false;

        // 🔥 giữ góc gọn lại (tránh lệch lần sau)
        currentAngle = currentAngle % (2 * pi);

        widget.onFinish?.call(_lastIndex);
      }
    });
  }

  int _lastIndex = 0;

  // 🎯 CALL FUNCTION NÀY TỪ NGOÀI
  void spinTo(int index) {
    if (isSpinning) return;

    final itemCount = widget.items.length;
    if (itemCount == 0) return;

    isSpinning = true;
    _lastIndex = index;

    _controller.reset();

    final anglePerItem = 2 * pi / itemCount;

    // 🎯 FIX: tính đúng vị trí trúng
    final targetAngle =
        (2 * pi - (index * anglePerItem)) +
            (anglePerItem / 2) -
            (pi / 2);

    // 🎯 random số vòng quay cho tự nhiên
    final extraTurns = (3 + Random().nextInt(3)) * 2 * pi;

    final newAngle = extraTurns + targetAngle;

    _animation = Tween<double>(
      begin: 0,
      end: newAngle,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
      ),
    );

    // bỏ hoặc giữ normalize thôi
    currentAngle = newAngle % (2 * pi);

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(Icons.arrow_drop_down, size: 40, color: Colors.red),

        const SizedBox(height: 10),

        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Transform.rotate(
              angle: _animation.value,
              child: child,
            );
          },
          child: CustomPaint(
            size: const Size(260, 260),
            painter: WheelPainter(widget.items),
          ),
        ),
      ],
    );
  }
}

class WheelPainter extends CustomPainter {
  final List<String> items;

  WheelPainter(this.items);

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final center = Offset(radius, radius);

    final paint = Paint();
    final anglePerItem = 2 * pi / items.length;

    for (int i = 0; i < items.length; i++) {
      paint.color = i % 2 == 0 ? Colors.orange : Colors.deepOrange;

      final startAngle = (i * anglePerItem) - (pi / 2);

      // 🎯 vẽ miếng
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        anglePerItem,
        true,
        paint,
      );

      // 🎯 text
      final textPainter = TextPainter(
        text: TextSpan(
          text: items[i],
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );

      textPainter.layout();

      final textAngle = startAngle + anglePerItem / 2;

      final x = center.dx + cos(textAngle) * radius * 0.6;
      final y = center.dy + sin(textAngle) * radius * 0.6;

      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(textAngle + pi / 2);
      textPainter.paint(
        canvas,
        Offset(-textPainter.width / 2, -textPainter.height / 2),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}