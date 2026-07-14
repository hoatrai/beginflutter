import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../app_globals.dart'; // navigatorKey, isChatPageOpen, currentChatTargetId
import '../config/app_config.dart';
import '../pages/video_call_page.dart';
import '../pages/webrtc_signal_bus.dart';
import 'callkit_service.dart';

/// GlobalCallService — singleton sống suốt vòng đời app.
///
/// ⚠️ FIX QUAN TRỌNG (so với bản cũ):
/// Bản cũ hủy `_wsSub` ngay trong `onAccept`, TRƯỚC khi mở VideoCallPage.
/// Vì VideoCallPage/WebRTCSignalBus KHÔNG tự listen() lên channel.stream
/// (thiết kế của bus là để ChatPage._onData làm việc đó), nên trong luồng
/// gọi đến từ FCM/GlobalCallService (không có ChatPage nào đang mở), việc
/// hủy _wsSub khiến KHÔNG CÒN AI lắng nghe channel.stream nữa.
/// → webrtc_offer/answer/ice của caller gửi tới sau khi accept sẽ bị rơi
/// mất hoàn toàn → "báo tới, bắt máy được nhưng không có tín hiệu".
///
/// Cách sửa: giữ `_wsSub` sống xuyên suốt cuộc gọi (không hủy lúc accept),
/// chỉ đóng nó khi cuộc gọi thực sự kết thúc (tự cúp máy, hoặc nhận được
/// call_end/call_reject từ đối phương qua WebRTCSignalBus.onCallEnded).
///
/// Fix phụ: `isChatPageOpen` trước đây là cờ boolean chung, khiến cuộc gọi
/// đến bị bỏ qua hoàn toàn nếu người dùng đang mở BẤT KỲ ChatPage nào, kể
/// cả đang chat với người khác (không phải người gọi). Giờ so sánh đúng
/// `currentChatTargetId` với id người gọi.
class GlobalCallService {
  GlobalCallService._() {
    // onCallEnded là broadcast stream của WebRTCSignalBus — nghe thêm ở
    // đây không ảnh hưởng gì tới các listener khác (VideoCallPage...).
    // Dùng để tự dọn dẹp channel của GlobalCallService khi cuộc gọi kết
    // thúc từ phía đối phương (call_end / call_reject), tránh rò rỉ kết
    // nối WebSocket treo mãi sau khi cuộc gọi đã xong.
    WebRTCSignalBus.instance.onCallEnded.listen((_) {
      closeActiveCallChannel();
    });
  }

  static final GlobalCallService instance = GlobalCallService._();

  // ---- state ----
  OverlayEntry? _overlay;
  VoidCallback? _dismissOverlay;
  WebSocketChannel? _callChannel;
  Stream<dynamic>? _broadcastStream;
  int _refCounter = 9000;
  String? _activeTopic;
  Timer? _autoDismissTimer;
  StreamSubscription? _wsSub;

  // ---------------------------------------------------------------
  // PUBLIC API
  // ---------------------------------------------------------------

  /// Gọi từ setupFirebaseMessaging khi nhận FCM có type == "video_call".
  Future<void> handleFcmCall(Map<String, dynamic> data) async {
    final fromName = data['from_name'] ?? 'Ai đó';
    final fromAvatar = data['from_avatar'] as String?;
    final topic = data['topic'] as String?;
    final fromId = int.tryParse(data['from_id']?.toString() ?? '');
    // ✅ Đọc call_type từ FCM — nếu server cũ chưa có field này thì mặc
    // định "video" để giữ hành vi cũ, nhưng cần server gửi kèm field này
    // (xem patch room_channel.ex / notifications.ex) để cuộc gọi voice
    // không bị hiện nhầm thành video khi nhận qua đường FCM.
    final callType = (data['call_type'] as String?) ?? 'video';

    if (topic == null) return;

    // ✅ Chỉ bỏ qua nếu đang chat ĐÚNG với người đang gọi — không bỏ qua
    // toàn bộ chỉ vì đang mở một ChatPage bất kỳ. Nếu đang chat với đúng
    // người gọi thì luồng call_invite/call_accept trong ChatPage tự lo,
    // không cần GlobalCallService xen vào.
    if (isChatPageOpen &&
        fromId != null &&
        currentChatTargetId != null &&
        currentChatTargetId == fromId) {
      return;
    }

    await _connectCallChannel(topic);

    // Dùng addPostFrameCallback để đảm bảo navigator sẵn sàng
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showOverlayWithRetry(
        fromName: fromName,
        fromAvatar: fromAvatar,
        topic: topic,
        callType: callType,
      );
    });
  }

  /// Đóng kết nối WebSocket riêng của GlobalCallService (dùng cho cuộc gọi
  /// đến khi không có ChatPage mở sẵn). Gọi khi:
  ///   - Cuộc gọi kết thúc do đối phương gửi call_end/call_reject (tự động
  ///     qua listener onCallEnded ở constructor).
  ///   - Chính người nhận cuộc gọi chủ động cúp máy trong VideoCallPage
  ///     (VideoCallPage._hangUp() nên gọi hàm này).
  void closeActiveCallChannel() {
    _wsSub?.cancel();
    _wsSub = null;
    _broadcastStream = null;
    _callChannel = null;
    _activeTopic = null;
  }

  void cancelPendingCall(String? topic) {
    if (topic == null) return;

    // ⚠️ FIX: trước đây chỉ dismiss banner khi topic khớp _activeTopic,
    // bỏ sót trường hợp cuộc gọi đến lúc app đang nền/bị kill (hiện qua
    // CallkitService.showIncomingCall native, KHÔNG đi qua handleFcmCall
    // nên _activeTopic vẫn null), rồi app được mở lên foreground trong
    // lúc đang đổ chuông — FCM "call_cancel" lúc đó bị FOREGROUND listener
    // bắt (không phải background handler), gọi thẳng vào đây, nhưng vì
    // topic != _activeTopic nên không làm gì cả → màn hình CallKit native
    // tiếp tục đổ chuông tới hết 30s dù người gọi đã cúp máy từ lâu.
    //
    // Luôn gọi endCall(topic) trước — no-op an toàn nếu không có cuộc gọi
    // native nào khớp id này — để dẹp CallKit native trong MỌI trường hợp,
    // không chỉ trường hợp có banner trong-app đang hiện.
    CallkitService.instance.endCall(topic);

    if (topic == _activeTopic) {
      _dismissOverlay?.call(); // tự stop chuông banner + đóng channel
    }
  }

  // ---------------------------------------------------------------
  // PRIVATE
  // ---------------------------------------------------------------

  /// Thử hiện overlay — nếu navigator chưa sẵn sàng thì retry sau 200ms,
  /// tối đa 10 lần (~2 giây). Giải quyết trường hợp app vừa mở từ terminated.
  void _showOverlayWithRetry({
    required String fromName,
    String? fromAvatar,
    required String topic,
    required String callType,
    int attempt = 0,
  }) {
    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      if (attempt >= 10) {
        debugPrint('GlobalCallService: overlay not available after 10 attempts');
        return;
      }
      Future.delayed(const Duration(milliseconds: 200), () {
        _showOverlayWithRetry(
          fromName: fromName,
          fromAvatar: fromAvatar,
          topic: topic,
          callType: callType,
          attempt: attempt + 1,
        );
      });
      return;
    }
    _showOverlay(
      fromName: fromName,
      fromAvatar: fromAvatar,
      topic: topic,
      callType: callType,
    );
  }

  Future<void> _connectCallChannel(String topic) async {
    // Đóng kênh cũ (nếu có) trước khi mở kênh mới cho cuộc gọi này.
    closeActiveCallChannel();
    _activeTopic = topic;

    try {
      // ⚠️ FIX: trước đây hardcode nhầm domain "socket.spiritwebs.com"
      // (không phải domain socket thật của app, xem AppConfig.websocketUrl
      // là "wss://socket.okinawanew.com/socket/websocket"). Vì domain sai,
      // kết nối thất bại ÂM THẦM (WebSocketChannel.connect() không đợi
      // handshake nên không throw), khiến banner vẫn hiện bình thường,
      // người dùng bấm "Nghe" nhưng call_accept được gửi vào một kết nối
      // chết — server không bao giờ nhận được. Giờ dùng chung URL với
      // ChatPage để đảm bảo luôn đúng.
      _callChannel = WebSocketChannel.connect(
        Uri.parse(AppConfig.websocketUrl),
      );

      _callChannel!.sink.add(jsonEncode({
        "topic": topic,
        "event": "phx_join",
        "payload": {},
        "ref": "${_refCounter++}",
      }));

      final broadcastStream = _callChannel!.stream.asBroadcastStream();
      _broadcastStream = broadcastStream;

      // ⭐ Subscription này PHẢI sống xuyên suốt cuộc gọi — không hủy khi
      // người dùng bấm "Nghe". Đây là nơi DUY NHẤT forward webrtc_offer/
      // answer/ice vào WebRTCSignalBus.handle() trong luồng gọi đến qua
      // FCM (không có ChatPage nào đang mở để làm việc này thay).
      _wsSub = broadcastStream.listen(
            (data) {
          _onChannelData(data);
          WebRTCSignalBus.instance.handle(data);
        },
        onError: (_) {},
        onDone: () {},
      );
    } catch (e) {
      debugPrint("GlobalCallService: WS connect error: $e");
    }
  }

  void _onChannelData(dynamic data) {
    try {
      final msg = jsonDecode(data as String);
      final event = msg['event'];
      if (event == 'call_end' || event == 'call_reject') {
        // Dẹp cả banner trong-app lẫn màn hình CallKit native (nếu lỡ cả
        // 2 đang hiện song song — hiếm nhưng có thể xảy ra khi app vừa
        // chuyển từ nền sang foreground giữa lúc đang đổ chuông). endCall
        // là no-op an toàn nếu không có cuộc gọi native nào khớp topic.
        if (_activeTopic != null) {
          CallkitService.instance.endCall(_activeTopic!);
        }
        _dismissOverlay?.call();
      }
    } catch (_) {}
  }

  void _send(String event, Map payload) {
    if (_callChannel == null || _activeTopic == null) return;
    _callChannel!.sink.add(jsonEncode({
      "topic": _activeTopic,
      "event": event,
      "payload": payload,
      "ref": "${_refCounter++}",
    }));
  }

  void _showOverlay({
    required String fromName,
    String? fromAvatar,
    required String topic,
    required String callType,
  }) {
    // Hủy overlay cũ nếu có
    _dismissOverlay?.call();

    FlutterRingtonePlayer().play(
      android: AndroidSounds.ringtone,
      ios: IosSounds.glass,
      looping: true,
      volume: 0.7,
      asAlarm: false,
    );

    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState == null) return;

    late AnimationController controller;
    bool accepted = false;

    void dismiss() {
      FlutterRingtonePlayer().stop();
      _autoDismissTimer?.cancel();
      controller.reverse().then((_) {
        _overlay?.remove();
        _overlay = null;
        _dismissOverlay = null;
        controller.dispose();
        // Nếu người dùng từ chối / để hết giờ mà KHÔNG bấm nghe, đóng
        // luôn kênh — không còn ai cần dùng tới nó nữa.
        if (!accepted) closeActiveCallChannel();
      });
    }

    _dismissOverlay = dismiss;

    _overlay = OverlayEntry(
      builder: (ctx) => _GlobalCallBanner(
        fromName: fromName,
        avatarUrl: fromAvatar,
        callType: callType,
        onCreateController: (c) => controller = c,
        onAccept: () async {
          accepted = true;
          _send("call_accept", {});
          // Dẹp UI cuộc gọi native tương ứng (nếu đang hiện) — không hại
          // gì nếu không có cuộc gọi nào khớp id này (no-op).
          CallkitService.instance.endCall(topic);

          final activeChannel = _callChannel;
          final activeTopic = _activeTopic;

          // ✅ KHÔNG hủy _wsSub ở đây nữa (xem giải thích ở đầu file).
          // Chỉ dọn tham chiếu nội bộ để tránh dùng nhầm cho cuộc gọi
          // tiếp theo — _wsSub vẫn tiếp tục chạy, forward dữ liệu vào
          // WebRTCSignalBus suốt thời gian cuộc gọi diễn ra.
          _callChannel = null;
          _activeTopic = null;

          dismiss();

          if (activeChannel == null || activeTopic == null) return;

          WebRTCSignalBus.instance.bindSocket(
            channel: activeChannel,
            topicName: activeTopic,
          );

          navigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => VideoCallPage(
                socket: activeChannel,
                topic: activeTopic,
                isCaller: false,
                callType: callType, // ✅ giữ đúng loại cuộc gọi (voice/video)
              ),
            ),
          );
        },
        onReject: () {
          dismiss();
          _send("call_reject", {});
          CallkitService.instance.endCall(topic);
        },
      ),
    );

    overlayState.insert(_overlay!);

    _autoDismissTimer = Timer(const Duration(seconds: 30), () {
      _dismissOverlay?.call();
    });
  }

  // ---------------------------------------------------------------
  // 🆕 GỌI TỪ CallkitService — khi người dùng bấm Nghe/Từ chối trên màn
  // hình cuộc gọi đến NATIVE (Android full-screen Activity / iOS CallKit),
  // thường xảy ra khi app đang nền hoặc bị kill hẳn lúc chuông reo, nên
  // KHÔNG có channel/banner nào được dựng sẵn từ handleFcmCall() — phải tự
  // kết nối lại từ đầu ở đây.
  // ---------------------------------------------------------------

  /// Người dùng bấm "Nghe" trên UI cuộc gọi đến native.
  Future<void> acceptCallFromNative({
    required String topic,
    String? fromId,
    required String fromName,
    String? fromAvatar,
    required String callType,
  }) async {
    // Nếu đúng lúc này banner trong-app cho CÙNG topic cũng đang hiện
    // (hiếm, ví dụ app vừa chuyển sang foreground kịp lúc) -> dùng lại
    // luôn kênh đã kết nối sẵn thay vì mở kênh mới, tránh 2 kết nối trùng.
    if (_activeTopic == topic && _callChannel != null) {
      _dismissOverlay?.call();
    }

    await _connectCallChannel(topic);
    _send("call_accept", {});
    CallkitService.instance.endCall(topic);

    final activeChannel = _callChannel;
    _callChannel = null;
    _activeTopic = null;
    if (activeChannel == null) return;

    WebRTCSignalBus.instance.bindSocket(channel: activeChannel, topicName: topic);

    // ⚠️ FIX race condition với SplashPage (xem giải thích đầy đủ ở
    // `PendingNativeCall` trong services/app_globals.dart).
    //
    // Nếu navigator ĐÃ sẵn sàng (app đang chạy nền chứ không bị kill hẳn,
    // MainPage/route hiện tại đã tồn tại từ trước) -> an toàn để push
    // trực tiếp như cũ, không có Splash nào đang tranh route.
    //
    // Nếu navigator CHƯA sẵn sàng (app vừa được mở lại từ trạng thái bị
    // kill -> đang chạy qua SplashPage) -> KHÔNG tự push nữa (dễ bị
    // SplashPage.pushReplacement() xoá mất ngay sau đó). Thay vào đó lưu
    // lại, để MainPage._openPendingNativeCall() tự mở sau khi Splash đã
    // điều hướng xong.
    final overlayReady = navigatorKey.currentState?.overlay != null;
    if (overlayReady) {
      _pushVideoCallPageWithRetry(
        socket: activeChannel,
        topic: topic,
        callType: callType,
        targetName: fromName,
        targetAvatar: fromAvatar,
      );
    } else {
      pendingNativeCall = PendingNativeCall(
        socket: activeChannel,
        topic: topic,
        callType: callType,
        targetName: fromName,
        targetAvatar: fromAvatar,
      );
    }
  }

  /// Người dùng bấm "Từ chối" (hoặc để hết giờ) trên UI cuộc gọi đến native.
  void rejectCallFromNative(String topic) async {
    CallkitService.instance.endCall(topic);
    if (_activeTopic == topic) {
      // Có banner trong-app đang hiện song song cho topic này -> dùng
      // đúng luồng dismiss cũ (đã tự gửi call_reject qua onReject).
      _dismissOverlay?.call();
      return;
    }
    // Không có channel nào đang mở sẵn -> kết nối tạm để báo cho người
    // gọi biết mình đã từ chối, xong đóng lại ngay.
    await _connectCallChannel(topic);
    _send("call_reject", {});
    closeActiveCallChannel();
  }

  void _pushVideoCallPageWithRetry({
    required WebSocketChannel socket,
    required String topic,
    required String callType,
    String? targetName,
    String? targetAvatar,
    int attempt = 0,
  }) {
    final nav = navigatorKey.currentState;
    if (nav == null) {
      if (attempt >= 15) {
        debugPrint('GlobalCallService: navigator not ready after 15 attempts, bỏ qua điều hướng');
        return;
      }
      Future.delayed(const Duration(milliseconds: 200), () {
        _pushVideoCallPageWithRetry(
          socket: socket,
          topic: topic,
          callType: callType,
          targetName: targetName,
          targetAvatar: targetAvatar,
          attempt: attempt + 1,
        );
      });
      return;
    }

    nav.push(
      MaterialPageRoute(
        builder: (_) => VideoCallPage(
          socket: socket,
          topic: topic,
          isCaller: false,
          callType: callType,
          targetName: targetName,
          targetAvatar: targetAvatar,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Banner widget
// ---------------------------------------------------------------------------

class _GlobalCallBanner extends StatefulWidget {
  final String fromName;
  final String? avatarUrl;
  final String callType;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final void Function(AnimationController) onCreateController;

  const _GlobalCallBanner({
    required this.fromName,
    required this.avatarUrl,
    required this.callType,
    required this.onAccept,
    required this.onReject,
    required this.onCreateController,
  });

  @override
  State<_GlobalCallBanner> createState() => _GlobalCallBannerState();
}

class _GlobalCallBannerState extends State<_GlobalCallBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    widget.onCreateController(_ctrl);
    _ctrl.forward();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: EdgeInsets.fromLTRB(10, topPad + 6, 10, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xF21C1C1E),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: Colors.white24,
                      backgroundImage: (widget.avatarUrl?.isNotEmpty ?? false)
                          ? NetworkImage(widget.avatarUrl!)
                          : null,
                      child: (widget.avatarUrl?.isNotEmpty ?? false)
                          ? null
                          : const Icon(Icons.person,
                          color: Colors.white70, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.fromName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                widget.callType == "voice"
                                    ? Icons.call_rounded
                                    : Icons.videocam_rounded,
                                size: 13,
                                color: Colors.greenAccent,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                widget.callType == "voice"
                                    ? "Cuộc gọi thoại đến..."
                                    : "Cuộc gọi video đến...",
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _CallButton(
                      icon: Icons.call_end,
                      color: Colors.redAccent,
                      onTap: widget.onReject,
                    ),
                    const SizedBox(width: 10),
                    _CallButton(
                      icon: widget.callType == "voice"
                          ? Icons.call_rounded
                          : Icons.videocam_rounded,
                      color: Colors.greenAccent,
                      onTap: widget.onAccept,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _CallButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: color.withOpacity(0.18),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}