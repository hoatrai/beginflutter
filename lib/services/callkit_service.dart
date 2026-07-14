import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

/// CallkitService — bọc gói `flutter_callkit_incoming` để hiện MÀN HÌNH CUỘC
/// GỌI ĐẾN THẬT SỰ của hệ điều hành (Android: full-screen Activity kiểu
/// điện thoại thường, kể cả khi máy khoá/app bị kill; iOS: CallKit).
///
/// ⚠️ ĐÂY LÀ PHẦN "PHASE 1" — dùng chung đường FCM hiện có (background
/// handler), KHÔNG cần VoIP push (PushKit) riêng. Nhờ vậy làm được ngay mà
/// không cần Apple Developer Certificate.
///
/// Giới hạn đã biết:
///  - Android: hoạt động tốt kể cả app bị kill hẳn (background isolate của
///    Firebase vẫn được OS đánh thức để chạy `showIncomingCall`), MIỄN LÀ
///    người dùng chưa "Force stop" app thủ công trong Settings và không bị
///    trình dọn pin của hãng (Xiaomi/Oppo/Vivo...) kill nền quá mạnh — cái
///    này Android không đảm bảo 100%, cần hướng dẫn người dùng thêm app vào
///    danh sách "không tối ưu pin" ở máy dùng ROM Trung Quốc.
///  - iOS: hàm `showIncomingCall` ở đây CHỈ chạy được khi app đang chạy nền
///    (không phải bị kill hẳn), vì iOS không cho chạy code Dart nền khi app
///    đã bị kill trừ khi dùng PushKit VoIP push thật (Phase 2, xem ghi chú
///    cuối file `docs/callkit_setup.md` đi kèm).
///
/// 🔌 KHÔNG import GlobalCallService trực tiếp ở đây (tránh import vòng vì
/// GlobalCallService lại cần gọi CallkitService.endCall(...) để dẹp UI
/// native khi cuộc gọi được xử lý từ trong app). Thay vào đó dùng 2 callback
/// `onAccept` / `onReject`, được gán 1 lần trong `main()` (đầu file
/// `main.dart`, ngay sau `WidgetsFlutterBinding.ensureInitialized()`).
class CallkitService {
  CallkitService._();
  static final CallkitService instance = CallkitService._();

  StreamSubscription<CallEvent?>? _eventSub;
  bool _initialized = false;

  /// Gán trong main.dart = GlobalCallService.instance.acceptCallFromNative
  void Function({
  required String topic,
  String? fromId,
  required String fromName,
  String? fromAvatar,
  required String callType,
  })? onAccept;

  /// Gán trong main.dart = GlobalCallService.instance.rejectCallFromNative
  void Function(String topic)? onReject;

  /// Gọi 1 LẦN duy nhất, càng sớm càng tốt trong main() — TRƯỚC khi
  /// runApp() cũng được, để không bỏ lỡ sự kiện accept/decline xảy ra
  /// ngay lúc app vừa mở lên từ trạng thái bị kill.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Android 13+: cần quyền hiện notification.
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        "title": "Quyền thông báo",
        "rationaleMessagePermission":
        "Cần quyền thông báo để hiển thị cuộc gọi đến.",
        "postNotificationMessageRequired":
        "Vui lòng bật lại quyền thông báo trong Cài đặt để nhận được cuộc gọi đến.",
      });
    } catch (e) {
      debugPrint("CallkitService: requestNotificationPermission lỗi $e");
    }

    // Android 14+: cần quyền full-screen intent riêng, nếu không cuộc gọi
    // đến khi máy khoá sẽ chỉ tụt xuống thành notification thường — đúng
    // triệu chứng cũ mà mình đang sửa, nên KHÔNG được bỏ qua bước này.
    try {
      final canFullScreen = await FlutterCallkitIncoming.canUseFullScreenIntent();
      if (canFullScreen == false) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (e) {
      debugPrint("CallkitService: full screen intent permission lỗi $e");
    }

    _eventSub = FlutterCallkitIncoming.onEvent.listen(_onCallkitEvent);

    // Xử lý trường hợp: app bị kill hẳn -> người dùng bấm "Nghe" ngay trên
    // màn hình cuộc gọi native -> Android mở lại app -> app khởi động lại
    // từ đầu và KHÔNG có cách nào tự nhiên biết "cuộc gọi vừa được nghe".
    // `activeCalls()` trả về cuộc gọi gần nhất (kể cả đã accept) để mình
    // tự điều hướng vào VideoCallPage ngay khi app mở lên.
    await checkPendingAcceptedCall();
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
  }

  /// Hiện màn hình cuộc gọi đến native. Gọi từ:
  ///  - `_firebaseMessagingBackgroundHandler` (main.dart) khi app nền/bị kill.
  ///  - có thể gọi cả lúc foreground nếu sau này muốn thay UI banner tự chế
  ///    bằng UI native luôn cho đồng nhất (hiện tại CHƯA đổi để tránh phá
  ///    luồng foreground đang chạy ổn).
  Future<void> showIncomingCall(Map<String, dynamic> data) async {
    final topic = data['topic'] as String?;
    if (topic == null) return;

    final fromName = data['from_name']?.toString() ?? 'Ai đó';
    final fromAvatar = data['from_avatar']?.toString();
    final callType = data['call_type']?.toString() ?? 'video';
    final fromId = data['from_id']?.toString() ?? '';

    final params = CallKitParams(
      id: topic, // dùng topic làm id -> khỏi cần map ngược lại lúc accept
      nameCaller: fromName,
      appName: 'Spirit',
      avatar: fromAvatar,
      handle: fromName,
      // Quy ước của flutter_callkit_incoming: 0 = audio, 1 = video.
      type: callType == 'voice' ? 0 : 1,
      duration: 30000, // khớp với _autoDismissTimer 30s bên GlobalCallService
      textAccept: 'Nghe',
      textDecline: 'Từ chối',
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Cuộc gọi nhỡ',
      ),
      extra: <String, dynamic>{
        'topic': topic,
        'from_id': fromId,
        'from_name': fromName,
        'from_avatar': fromAvatar ?? '',
        'call_type': callType,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        // ⚠️ FIX: thiếu flag này khiến một số máy chỉ tụt màn hình cuộc gọi
        // đến xuống thành 1 notification thường khi máy đang khoá (đúng
        // triệu chứng "im lặng, không biết có ai gọi") thay vì bật full-
        // screen Activity thật sự kiểu điện thoại. Bắt buộc phải có cùng
        // với quyền full-screen intent đã request ở init().
        isShowFullLockedScreen: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0955fa',
        actionColor: '#4CAF50',
        incomingCallNotificationChannelName: 'Cuộc gọi đến',
        missedCallNotificationChannelName: 'Cuộc gọi nhỡ',
      ),
      ios: const IOSParams(
        handleType: 'generic',
        supportsVideo: true,
        audioSessionMode: 'videoChat',
      ),
    );

    try {
      await FlutterCallkitIncoming.showCallkitIncoming(params);
    } catch (e) {
      debugPrint("CallkitService: showCallkitIncoming lỗi $e");
    }
  }

  /// Gọi khi bên gọi huỷ trước khi bên nghe kịp bắt máy (FCM type
  /// "call_cancel"), hoặc khi cuộc gọi đã được xử lý xong bằng cách khác
  /// (đã nghe/từ chối từ trong app) — dẹp UI cuộc gọi đến native theo id.
  Future<void> endCall(String topic) async {
    try {
      await FlutterCallkitIncoming.endCall(topic);
    } catch (e) {
      debugPrint("CallkitService: endCall lỗi $e");
    }
  }

  Future<void> endAllCalls() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (e) {
      debugPrint("CallkitService: endAllCalls lỗi $e");
    }
  }

  /// Xem có cuộc gọi nào đã được "Nghe" ngay trên UI native trước khi app
  /// kịp khởi động không (trường hợp app bị kill hẳn). Nếu có, tự điều
  /// hướng vào VideoCallPage giống hệt như bấm "Nghe" trên banner trong app.
  Future<void> checkPendingAcceptedCall() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      if (calls is! List || calls.isEmpty) return;

      final call = calls.first;
      final extra = (call is Map) ? call['extra'] : null;
      final isAccepted = (call is Map) ? call['isAccepted'] == true : false;
      if (!isAccepted || extra is! Map) return;

      _acceptFromExtra(Map<String, dynamic>.from(extra));
    } catch (e) {
      debugPrint("CallkitService: checkPendingAcceptedCall lỗi $e");
    }
  }

  void _onCallkitEvent(CallEvent? event) {
    if (event == null) return;
    final body = event.body is Map
        ? Map<String, dynamic>.from(event.body)
        : <String, dynamic>{};
    final extra = body['extra'] is Map
        ? Map<String, dynamic>.from(body['extra'])
        : <String, dynamic>{};

    switch (event.event) {
      case Event.actionCallAccept:
        _acceptFromExtra(extra);
        break;
      case Event.actionCallDecline:
      case Event.actionCallTimeout:
        final topic = extra['topic']?.toString();
        if (topic != null) {
          onReject?.call(topic);
        }
        break;
      default:
        break;
    }
  }

  void _acceptFromExtra(Map<String, dynamic> extra) {
    final topic = extra['topic']?.toString();
    if (topic == null) return;

    onAccept?.call(
      topic: topic,
      fromId: extra['from_id']?.toString(),
      fromName: extra['from_name']?.toString() ?? 'Ai đó',
      fromAvatar: (extra['from_avatar']?.toString().isNotEmpty ?? false)
          ? extra['from_avatar'].toString()
          : null,
      callType: extra['call_type']?.toString() ?? 'video',
    );
  }
}