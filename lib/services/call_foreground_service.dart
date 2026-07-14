import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// CallForegroundService — giữ tiến trình app "sống" ở mức hệ điều hành
/// TRONG SUỐT lúc đang có cuộc gọi video/voice.
///
/// 🐛 BUG ĐÃ SỬA: package `flutter_foreground_task` đã có sẵn trong
/// pubspec.yaml (comment "Thêm để chạy foreground service trên Android")
/// nhưng KHÔNG hề được gọi ở bất kỳ đâu trong code, và AndroidManifest.xml
/// cũng thiếu <service> + permission tương ứng. Vì vậy khi user đẩy app
/// xuống nền GIỮA LÚC đang gọi (bấm Home / chuyển app khác), Android áp
/// background execution limits (Doze/App Standby, throttle CPU, network)
/// lên app y như một app bình thường không có gì đang chạy quan trọng cả
/// → WebSocketChannel tín hiệu WebRTC bị treo/rớt sau vài chục giây →
/// mất tiếng/mất hình dù cuộc gọi vẫn "đang mở" trên UI.
///
/// Cách sửa: bật 1 foreground service THẬT (có notification "Đang trong
/// cuộc gọi") ngay khi vào VideoCallPage — lúc app còn đang ở foreground.
/// ⚠️ PHẢI start lúc còn foreground: Android 14+ (API 34) CẤM khởi động
/// foreground service loại `camera`/`microphone` khi app đã ở nền, nên
/// không thể "chờ tới lúc backgrounded mới bật" — phải bật ngay từ đầu
/// cuộc gọi, không dùng thì thôi (không tốn gì thêm nếu app luôn ở
/// foreground suốt cuộc gọi).
class CallForegroundService {
  CallForegroundService._();

  static bool _notificationInitDone = false;

  static Future<void> _ensureNotificationInit() async {
    if (_notificationInitDone) return;
    _notificationInitDone = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'call_foreground_channel',
        channelName: 'Cuộc gọi đang diễn ra',
        channelDescription:
            'Hiện khi có cuộc gọi video/voice đang mở, giữ cuộc gọi không bị ngắt khi app xuống nền.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Gọi ở `VideoCallPage.initState()` — NGAY khi cuộc gọi mở lên, lúc app
  /// chắc chắn đang ở foreground (đảm bảo được start hợp lệ).
  static Future<void> start({required bool isVideo}) async {
    try {
      await _ensureNotificationInit();

      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
        return;
      }

      await FlutterForegroundTask.startService(
        serviceId: 9100,
        notificationTitle: 'Đang trong cuộc gọi',
        notificationText: isVideo
            ? 'Cuộc gọi video đang diễn ra — chạm để quay lại'
            : 'Cuộc gọi thoại đang diễn ra — chạm để quay lại',
        notificationIcon: null,
        // ⚠️ Bản flutter_foreground_task đang dùng (8.17.0, ghim bởi
        // ^8.0.0 trong pubspec.yaml) KHÔNG có tham số `serviceTypes` ở
        // hàm startService() (tham số đó chỉ có ở bản mới hơn, 9.x+).
        // Ở bản 8.x, loại foreground service (camera|microphone) được
        // xác định HOÀN TOÀN qua android:foregroundServiceType khai báo
        // sẵn trong <service> của AndroidManifest.xml — không cần (và
        // không thể) truyền lại ở đây.
        callback: startCallback,
      );
    } catch (e) {
      // Không throw — nếu vì lý do gì đó (quyền bị từ chối, thiết bị lạ...)
      // service không bật được, cuộc gọi vẫn tiếp tục chạy bình thường lúc
      // app đang ở foreground, chỉ mất phần "giữ sống khi xuống nền".
      debugPrint('CallForegroundService: start lỗi $e');
    }
  }

  /// Gọi ở `VideoCallPage.dispose()` — cuộc gọi đã kết thúc (tự cúp máy
  /// hoặc bị đối phương cúp), không cần giữ app sống nữa.
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('CallForegroundService: stop lỗi $e');
    }
  }
}

/// Callback top-level bắt buộc (chạy trên isolate riêng của service).
/// KHÔNG làm gì thêm ở đây — mục đích duy nhất của service này là giữ
/// process app không bị OS coi là "idle background app" trong lúc gọi,
/// bản thân WebRTC/WebSocket vẫn chạy trên isolate chính của Flutter.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_CallTaskHandler());
}

class _CallTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
