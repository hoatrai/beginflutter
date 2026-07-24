import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:audioplayers/audioplayers.dart';

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

  // 🔊 đếm số "vạch chia ô" đã đi qua kể từ lúc bắt đầu quay, để biết khi
  // nào cần phát tiếng "tách" — mỗi lần bánh xe quay thêm đúng 1
  // anglePerItem là băng qua 1 vạch chia, bất kể lệch pha bao nhiêu.
  int _ticksPlayed = 0;

  // 🔊 AudioPool: API chuyên dụng của audioplayers để phát 1 âm rất ngắn
  // LẶP LẠI LIÊN TỤC với độ trễ thấp (game sound: tick, coin, click...).
  // Trước đây dùng AudioPlayer.seek()+resume() thủ công trên
  // PlayerMode.lowLatency (SoundPool bên dưới) -> SoundPool không hỗ trợ
  // seek() tốt, nên chỉ phát được tiếng đầu rồi im. AudioPool tự quản lý
  // nhiều player con bên dưới để tránh đúng vấn đề này.
  AudioPool? _tickPool;
  bool _tickReady = false;

  // 🎉 âm thanh "chuông thắng" phát 1 lần duy nhất khi bánh xe dừng hẳn.
  // Dùng AudioPlayer thường (không cần AudioPool vì chỉ phát 1 lần/lượt
  // quay, không cần lặp lại nhanh như tick).
  final AudioPlayer _winPlayer = AudioPlayer(playerId: 'spin_wheel_win');
  bool _winReady = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );

    // 🔥 init animation tránh crash
    _animation = AlwaysStoppedAnimation(0);

    // 🔊 mỗi frame kiểm tra xem đã băng qua thêm vạch chia ô nào chưa,
    // nếu có thì "tách" — vì animation dùng easeOutCubic (chậm dần), tick
    // sẽ tự nhiên dày lúc đầu và thưa dần lúc cuối, đúng cảm giác thật.
    AudioPool.create(
      source: AssetSource('sounds/tick.wav'),
      maxPlayers: 4, // cho phép vài tick chồng nhau mà không bị cắt tiếng
    ).then((pool) {
      _tickPool = pool;
      _tickReady = true;
      debugPrint('[SpinWheel] ✅ đã load tick.wav thành công');
    }).catchError((e) {
      _tickReady = false;
      debugPrint('[SpinWheel] ❌ LOAD tick.wav THẤT BẠI: $e');
    });

    _winPlayer.setReleaseMode(ReleaseMode.stop);
    _winPlayer.setVolume(1.0);
    _winPlayer
        .setSource(AssetSource('sounds/win.wav'))
        .then((_) {
      _winReady = true;
      debugPrint('[SpinWheel] ✅ đã load win.wav thành công');
    })
        .catchError((e) {
      _winReady = false;
      debugPrint('[SpinWheel] ❌ LOAD win.wav THẤT BẠI: $e');
    });

    _controller.addListener(_playTickIfCrossedSegment);

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        isSpinning = false;

        // 🔥 giữ góc gọn lại (tránh lệch lần sau)
        currentAngle = currentAngle % (2 * pi);

        // 🎉 tèn ten khi có kết quả
        if (_winReady) {
          _winPlayer.seek(Duration.zero);
          _winPlayer.resume().catchError((e) {
            debugPrint('[SpinWheel] ❌ phát win.wav lỗi: $e');
          });
        }

        widget.onFinish?.call(_lastIndex);
      }
    });
  }

  int _lastIndex = 0;

  void _playTickIfCrossedSegment() {
    final itemCount = widget.items.length;
    if (itemCount == 0) return;

    final anglePerItem = 2 * pi / itemCount;
    // Tổng số vạch đã đi qua tính từ góc 0 tới thời điểm hiện tại của
    // animation (không phải currentAngle, vì đó là số đã bị mod 2π).
    final crossed = (_animation.value / anglePerItem).floor();

    if (crossed > _ticksPlayed) {
      _ticksPlayed = crossed;
      debugPrint('[SpinWheel] 🔔 tick #$crossed (tickReady=$_tickReady)');
      if (_tickReady && _tickPool != null) {
        _tickPool!.start().catchError((e) {
          debugPrint('[SpinWheel] ❌ pool.start() lỗi: $e');
        });
      }
    }
  }

  // 🎯 CALL FUNCTION NÀY TỪ NGOÀI
  void spinTo(int index) {
    if (isSpinning) return;

    final itemCount = widget.items.length;
    if (itemCount == 0) return;

    isSpinning = true;
    _lastIndex = index;
    _ticksPlayed = 0;

    _controller.reset();

    final anglePerItem = 2 * pi / itemCount;

    // 🎯 FIX: tính đúng vị trí trúng.
    // Mũi tên đứng yên ở góc -pi/2 (đỉnh vòng tròn). WheelPainter vẽ ô i
    // với tâm ô nằm ở góc (-pi/2 + i*anglePerItem + anglePerItem/2) khi
    // CHƯA quay. Muốn tâm ô "index" trùng với mũi tên sau khi quay thêm
    // "targetAngle", ta cần:
    //   (tâm ô index) + targetAngle ≡ -pi/2 (mod 2π)
    // => targetAngle ≡ -pi/2 - (tâm ô index) = -(index*anglePerItem) - anglePerItem/2
    //
    // Công thức cũ còn dư một số hạng "-pi/2" (đã tự triệt tiêu bởi -pi/2
    // gốc trong WheelPainter) và ĐỔI DẤU anglePerItem/2, nên nó chỉ tình
    // cờ đúng khi anglePerItem == pi/2 (tức đúng 4 ô). Với 3, 5, 6, 8...
    // ô thì bánh xe sẽ dừng lệch sang ô bên cạnh trong khi code vẫn báo
    // "index" là ô thắng -> "quay 1 đằng báo 1 nẻo".
    final targetAngle =
        2 * pi - (index * anglePerItem) - (anglePerItem / 2);

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
    _controller.removeListener(_playTickIfCrossedSegment);
    _tickPool?.dispose();
    _winPlayer.dispose();
    _controller.dispose();
    super.dispose();
  }

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