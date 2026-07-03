import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../app_globals.dart'; // navigatorKey, isChatPageOpen
import '../pages/video_call_page.dart';
import '../pages/webrtc_signal_bus.dart';

/// GlobalCallService — singleton sống suốt vòng đời app.
///
/// Fix so với bản cũ:
/// 1. _showOverlay dùng addPostFrameCallback → tránh lỗi navigator null
///    khi app vừa mở từ terminated state.
/// 2. Retry overlay tối đa 10 lần (mỗi 200ms) nếu navigator chưa sẵn sàng.
class GlobalCallService {
  GlobalCallService._();
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

    if (topic == null) return;

    if (isChatPageOpen) return;

    await _connectCallChannel(topic);

    // Dùng addPostFrameCallback để đảm bảo navigator sẵn sàng
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showOverlayWithRetry(
        fromName: fromName,
        fromAvatar: fromAvatar,
        topic: topic,
      );
    });
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
          attempt: attempt + 1,
        );
      });
      return;
    }
    _showOverlay(
        fromName: fromName, fromAvatar: fromAvatar, topic: topic);
  }

  Future<void> _connectCallChannel(String topic) async {
    await _closeCallChannel();
    _activeTopic = topic;

    try {
      _callChannel = WebSocketChannel.connect(
        Uri.parse("wss://socket.spiritwebs.com/socket/websocket"),
      );

      _callChannel!.sink.add(jsonEncode({
        "topic": topic,
        "event": "phx_join",
        "payload": {},
        "ref": "${_refCounter++}",
      }));

      final broadcastStream = _callChannel!.stream.asBroadcastStream();
      _broadcastStream = broadcastStream;

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

  Future<void> _closeCallChannel() async {
    _wsSub?.cancel();
    _wsSub = null;
    await _callChannel?.sink.close();
    _callChannel = null;
    _activeTopic = null;
  }

  void _showOverlay({
    required String fromName,
    String? fromAvatar,
    required String topic,
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
    bool _accepted = false;

    void dismiss() {
      FlutterRingtonePlayer().stop();
      _autoDismissTimer?.cancel();
      controller.reverse().then((_) {
        _overlay?.remove();
        _overlay = null;
        _dismissOverlay = null;
        controller.dispose();
        if (!_accepted) _closeCallChannel();
      });
    }
    _dismissOverlay = dismiss;

    _overlay = OverlayEntry(
      builder: (ctx) => _GlobalCallBanner(
        fromName: fromName,
        avatarUrl: fromAvatar,
        onCreateController: (c) => controller = c,
        onAccept: () async {
          _accepted = true;
          _send("call_accept", {});

          final activeChannel = _callChannel;
          final activeTopic = _activeTopic;

          _wsSub?.cancel();
          _wsSub = null;
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
              ),
            ),
          );
        },
        onReject: () {
          dismiss();
          _send("call_reject", {});
        },
      ),
    );

    overlayState.insert(_overlay!);

    _autoDismissTimer = Timer(const Duration(seconds: 30), () {
      _dismissOverlay?.call();
    });
  }
}

// ---------------------------------------------------------------------------
// Banner widget
// ---------------------------------------------------------------------------

class _GlobalCallBanner extends StatefulWidget {
  final String fromName;
  final String? avatarUrl;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final void Function(AnimationController) onCreateController;

  const _GlobalCallBanner({
    required this.fromName,
    required this.avatarUrl,
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
                            children: const [
                              Icon(Icons.videocam_rounded,
                                  size: 13, color: Colors.greenAccent),
                              SizedBox(width: 4),
                              Text(
                                "Cuộc gọi video đến...",
                                style: TextStyle(
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
                      icon: Icons.videocam_rounded,
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