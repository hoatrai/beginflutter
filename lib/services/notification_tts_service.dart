import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tts/flutter_tts.dart';

/// 🔊 Đọc to (text-to-speech) nội dung tin nhắn/thông báo push khi có tin
/// mới tới, kể cả khi app đang mở ở bất kỳ trang nào (không phụ thuộc vào
/// 1 State cụ thể) — vì FirebaseMessaging.onMessage được đăng ký ở
/// main.dart, ngoài mọi widget tree.
///
/// Singleton dùng chung toàn app: gọi `NotificationTts.instance.init()` một
/// lần lúc khởi động (trong main() hoặc setupFirebaseMessaging()), sau đó
/// gọi `NotificationTts.instance.speak(text)` ở bất cứ đâu cần đọc to.
class NotificationTts {
  NotificationTts._();
  static final NotificationTts instance = NotificationTts._();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool _initStarted = false;

  Future<void> init() async {
    if (_initStarted) return; // tránh init 2 lần nếu bị gọi từ nhiều nơi
    _initStarted = true;

    try {
      final engines = await _tts.getEngines.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[NotificationTts] ⏱️ getEngines() timeout — có thể máy không có engine TTS nào');
          return [];
        },
      );
      debugPrint('[NotificationTts] Engines tìm thấy: $engines');

      final available = await _tts.isLanguageAvailable('vi-VN').timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[NotificationTts] ⏱️ isLanguageAvailable() timeout');
          return false;
        },
      );
      debugPrint('[NotificationTts] vi-VN available = $available');

      final langResult = await _tts.setLanguage('vi-VN').timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[NotificationTts] ⏱️ setLanguage() timeout');
          return null;
        },
      );
      debugPrint('[NotificationTts] setLanguage(vi-VN) -> $langResult');

      await _tts.setSpeechRate(0.48);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);

      _tts.setStartHandler(() => debugPrint('[NotificationTts] ▶️ bắt đầu đọc'));
      _tts.setCompletionHandler(() => debugPrint('[NotificationTts] ✅ đọc xong'));
      _tts.setCancelHandler(() => debugPrint('[NotificationTts] ⏹️ bị huỷ'));
      _tts.setErrorHandler((msg) => debugPrint('[NotificationTts] ❌ lỗi engine: $msg'));

      debugPrint('[NotificationTts] ✅ init xong, sẵn sàng đọc');
    } catch (e) {
      debugPrint('[NotificationTts] ❌ init lỗi: $e');
    } finally {
      _ready = true;
    }
  }

  /// Đọc to [text]. Dừng câu đang đọc dở (nếu có) trước khi đọc câu mới,
  /// để tin nhắn dồn dập không bị chồng tiếng lên nhau.
  Future<void> speak(String text) async {
    debugPrint('[NotificationTts] 🔔 gọi speak (ready=$_ready): "$text"');
    if (!_ready || text.trim().isEmpty) return;
    try {
      await _tts.stop();
      final result = await _tts.speak(text);
      debugPrint('[NotificationTts] speak() trả về: $result');
    } catch (e) {
      debugPrint('[NotificationTts] ❌ speak lỗi: $e');
    }
  }

  Future<void> stop() => _tts.stop();
}