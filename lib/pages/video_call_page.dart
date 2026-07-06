import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../services/global_call_service.dart';
import 'webrtc_signal_bus.dart';

/// ⚠️ FIX QUAN TRỌNG (so với bản cũ):
/// Bản cũ tự gọi `widget.socket.stream.listen(_onSignal)` trong initState().
/// Vì `widget.socket` chính là `channel` đã có 1 listener active từ
/// ChatPage._onData (WebSocketChannel.stream là SINGLE-SUBSCRIPTION stream,
/// không phải broadcast), gọi .listen() lần 2 sẽ throw:
///   StateError: Stream has already been listened to.
/// → màn hình gọi video crash ngay khi mở lên.
///
/// Cách sửa: VideoCallPage KHÔNG tự listen() socket nữa. ChatPage._onData
/// vẫn là nơi DUY NHẤT lắng nghe channel.stream, và nó forward dữ liệu thô
/// cho WebRTCSignalBus.instance.handle(data) (đã có sẵn dòng này trong
/// chat_page.dart). VideoCallPage chỉ:
///   - dùng socket.sink để GỬI (ghi vào sink không bị giới hạn single-listen)
///   - lắng nghe WebRTCSignalBus.instance.onRemoteStream / onCallEnded
///     (đây là Stream.broadcast() nội bộ, nghe bao nhiêu lần cũng được)
class VideoCallPage extends StatefulWidget {
  final WebSocketChannel socket;
  final String topic;
  final bool isCaller;

  /// "video" hoặc "voice". Quyết định có xin quyền/track camera hay
  /// không, và UI hiển thị (preview video vs. màn hình thoại kiểu
  /// _OutgoingCallScreen).
  final String callType;

  /// Chỉ dùng cho UI (avatar + tên đối phương).
  /// Có thể null nếu ChatPage chưa truyền vào — UI sẽ fallback icon person.
  final String? targetName;
  final String? targetAvatar;

  const VideoCallPage({
    super.key,
    required this.socket,
    required this.topic,
    required this.isCaller,
    this.callType = "video",
    this.targetName,
    this.targetAvatar,
  });

  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  RTCPeerConnection? pc;
  MediaStream? localStream;

  final RTCVideoRenderer local = RTCVideoRenderer();
  final RTCVideoRenderer remote = RTCVideoRenderer();

  bool initialized = false;
  bool _callEnded = false;

  bool get _isVideoCall => widget.callType != "voice";

  // ---- trạng thái điều khiển dùng chung cho cả voice & video ----
  bool _muted = false;
  bool _speakerOn = true;
  bool _switchingCamera = false;
  bool _remoteConnected = false;
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;

  StreamSubscription<MediaStream>? _remoteStreamSub;
  StreamSubscription<String>? _callEndedSub;

  @override
  void initState() {
    super.initState();

    // Gắn socket/topic vào bus để gửi offer/answer/ice qua đúng kênh.
    WebRTCSignalBus.instance.bindSocket(
      channel: widget.socket,
      topicName: widget.topic,
    );

    // Nghe remote stream + tín hiệu kết thúc cuộc gọi qua bus — KHÔNG
    // listen() trực tiếp lên widget.socket.stream nữa.
    _remoteStreamSub = WebRTCSignalBus.instance.onRemoteStream.listen((stream) {
      if (!mounted) return;
      setState(() {
        if (_isVideoCall) remote.srcObject = stream;
        _remoteConnected = true;
      });
      _startDurationTimer();
    });

    _callEndedSub = WebRTCSignalBus.instance.onCallEnded.listen((_) {
      if (!mounted || _callEnded) return;
      _callEnded = true;
      _showRemoteEndedAndPop();
    });

    _init();
  }

  void _showRemoteEndedAndPop() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Cuộc gọi đã kết thúc")),
    );
    Navigator.of(context).pop();
  }

  void _startDurationTimer() {
    if (_durationTimer != null) return; // chỉ start 1 lần
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _callDuration += const Duration(seconds: 1));
    });
  }

  void _toggleMute() {
    if (localStream == null) return;
    final audioTracks = localStream!.getAudioTracks();
    if (audioTracks.isEmpty) return;
    setState(() {
      _muted = !_muted;
      for (final t in audioTracks) {
        t.enabled = !_muted;
      }
    });
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _speakerOn = !_speakerOn);
    try {
      await Helper.setSpeakerphoneOn(_speakerOn);
    } catch (e) {
      debugPrint("toggleSpeaker error: $e");
    }
  }

  Future<void> _switchCamera() async {
    if (localStream == null || _switchingCamera) return;
    final videoTracks = localStream!.getVideoTracks();
    if (videoTracks.isEmpty) return;
    setState(() => _switchingCamera = true);
    try {
      await Helper.switchCamera(videoTracks.first);
    } catch (e) {
      debugPrint("switchCamera error: $e");
    } finally {
      if (mounted) setState(() => _switchingCamera = false);
    }
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? "$h:$m:$s" : "$m:$s";
  }

  // ---------------- INIT WEBRTC ----------------
  Future<void> _init() async {
    if (_isVideoCall) {
      await local.initialize();
      await remote.initialize();
    }

    // 🎤📷 Get media — gọi thoại thì KHÔNG xin quyền/track camera.
    localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': _isVideoCall,
    });

    // 🌍 Create peer connection
    pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ]
    });

    // Đưa pc cho bus quản lý — handle() trong bus dùng pc này để
    // setRemoteDescription/createAnswer/addCandidate khi nhận signal.
    WebRTCSignalBus.instance.pc = pc;

    // ➕ Add tracks
    for (var track in localStream!.getTracks()) {
      pc!.addTrack(track, localStream!);
    }

    // 🎥 Remote stream — forward qua bus để onRemoteStream phát ra,
    // VideoCallPage tự nghe lại ở initState() phía trên.
    WebRTCSignalBus.instance.bindPeerConnectionTrackListener();

    // ❄ ICE candidate — gửi qua bus.send() để dùng đúng "ref" tăng dần
    // của bus, đồng bộ format với webrtc_offer/webrtc_answer.
    pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      WebRTCSignalBus.instance.send("webrtc_ice", {
        "candidate": candidate.candidate,
        "sdpMid": candidate.sdpMid,
        "sdpMLineIndex": candidate.sdpMLineIndex,
      });
    };

    // 🎥 Local preview (chỉ video call mới có gì để hiện)
    if (_isVideoCall) {
      local.srcObject = localStream;
    }

    // 🔊 Mặc định bật loa ngoài cho cuộc gọi video (voice call thì để
    // mặc định earpiece cho tự nhiên như gọi điện thoại thường).
    if (_isVideoCall) {
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    } else {
      _speakerOn = false;
    }

    if (!mounted) return;
    setState(() => initialized = true);

    // ☎ Caller tạo offer
    if (widget.isCaller) {
      await _createOffer();
    }
  }

  // ---------------- CREATE OFFER ----------------
  Future<void> _createOffer() async {
    if (pc == null) return;

    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);

    WebRTCSignalBus.instance.send("webrtc_offer", {
      "sdp": offer.sdp,
    });

    debugPrint("📤 Sent OFFER");
  }

  // ---------------- HANG UP (người dùng tự bấm kết thúc) ----------------
  void _hangUp() {
    if (!_callEnded) {
      _callEnded = true;
      // Báo cho phía bên kia biết mình đã rời cuộc gọi, để họ không bị
      // treo trên màn hình chờ vô thời hạn. Cần server có handle_in cho
      // "call_end" và broadcast_from! lại cho phía kia.
      WebRTCSignalBus.instance.send("call_end", {});

      // ✅ Đóng luôn kênh WebSocket riêng của GlobalCallService (nếu cuộc
      // gọi này đến từ FCM, không phải từ ChatPage). Nếu không gọi dòng
      // này, kênh đó sẽ treo mở mãi vì GlobalCallService chỉ tự đóng khi
      // NHẬN được call_end/call_reject từ đối phương — còn khi CHÍNH
      // MÌNH chủ động cúp máy thì không có ai kích hoạt việc dọn dẹp đó.
      GlobalCallService.instance.closeActiveCallChannel();
    }
    Navigator.of(context).pop();
  }

  // ---------------- CLEANUP ----------------
  @override
  void dispose() {
    _remoteStreamSub?.cancel();
    _callEndedSub?.cancel();
    _durationTimer?.cancel();

    if (_isVideoCall) {
      local.dispose();
      remote.dispose();
    }
    localStream?.dispose();
    pc?.close();

    // Reset bus để cuộc gọi tiếp theo không vô tình dùng lại pc/socket cũ
    // (singleton sống suốt đời app, nếu không reset thì lần gọi sau
    // WebRTCSignalBus.instance.pc vẫn trỏ vào peer connection đã close()).
    WebRTCSignalBus.instance.reset();

    super.dispose();
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    if (!_isVideoCall) return _buildVoiceUI();
    return _buildVideoUI();
  }

  // =====================================================================
  // VIDEO CALL UI
  // =====================================================================
  Widget _buildVideoUI() {
    final hasAvatar = widget.targetAvatar != null && widget.targetAvatar!.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ---- Nền: remote video, hoặc avatar mờ nếu chưa kết nối ----
          Positioned.fill(
            child: _remoteConnected
                ? RTCVideoView(
              remote,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
                : _buildConnectingBackground(hasAvatar),
          ),

          // ---- Overlay tối nhẹ phía trên để chữ/nút luôn dễ đọc ----
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.55),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withOpacity(0.65),
                    ],
                    stops: const [0.0, 0.2, 0.7, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // ---- Thanh trên: tên + trạng thái/thời gian ----
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Column(
                  children: [
                    Text(
                      widget.targetName ?? "Người dùng",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _remoteConnected
                          ? _formatDuration(_callDuration)
                          : "Đang kết nối...",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ---- Khung preview camera của chính mình ----
          if (_isVideoCall)
            Positioned(
              right: 14,
              top: 90,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 110,
                  height: 150,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white24, width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: RTCVideoView(
                    local,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),

          // ---- Spinner khi đang khởi tạo webrtc (xin quyền, mở camera) ----
          if (!initialized)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // ---- Thanh điều khiển dưới cùng ----
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 22),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _CallIconButton(
                      icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      active: _muted,
                      onTap: _toggleMute,
                    ),
                    const SizedBox(width: 18),
                    _CallIconButton(
                      icon: Icons.cameraswitch_rounded,
                      active: false,
                      onTap: _switchCamera,
                    ),
                    const SizedBox(width: 18),
                    // Nút cúp máy — to hơn, nổi bật, ở giữa
                    GestureDetector(
                      onTap: _hangUp,
                      child: Container(
                        width: 66,
                        height: 66,
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.call_end_rounded,
                            color: Colors.white, size: 30),
                      ),
                    ),
                    const SizedBox(width: 18),
                    _CallIconButton(
                      icon: _speakerOn
                          ? Icons.volume_up_rounded
                          : Icons.volume_down_rounded,
                      active: _speakerOn,
                      onTap: _toggleSpeaker,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Nền hiển thị khi chưa nhận được remote stream — thay vì màn đen trơ
  /// trọi kèm 1 spinner giữa màn hình, hiện avatar đối phương phóng to +
  /// làm mờ, giống UI "đang kết nối" của các app gọi video phổ biến.
  Widget _buildConnectingBackground(bool hasAvatar) {
    return Container(
      color: const Color(0xFF111318),
      child: hasAvatar
          ? Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            widget.targetAvatar!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          BackdropFilter(
            filter: ColorFilter.mode(
              Colors.black.withOpacity(0.55),
              BlendMode.darken,
            ) as dynamic,
            child: Container(color: Colors.black.withOpacity(0.35)),
          ),
        ],
      )
          : const Center(
        child: Icon(Icons.videocam_rounded, color: Colors.white24, size: 64),
      ),
    );
  }

  // =====================================================================
  // VOICE CALL UI
  // =====================================================================
  Widget _buildVoiceUI() {
    final hasAvatar =
        widget.targetAvatar != null && widget.targetAvatar!.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF111318),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),
            Text(
              _remoteConnected ? "📞 Đang trong cuộc gọi" : "📞 Đang kết nối...",
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const Spacer(),
            CircleAvatar(
              radius: 64,
              backgroundColor: Colors.white24,
              backgroundImage: hasAvatar ? NetworkImage(widget.targetAvatar!) : null,
              child: !hasAvatar
                  ? const Icon(Icons.person, color: Colors.white70, size: 56)
                  : null,
            ),
            const SizedBox(height: 24),
            Text(
              widget.targetName ?? "Người dùng",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _remoteConnected ? _formatDuration(_callDuration) : "Đang chờ phản hồi...",
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallIconButton(
                  icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  active: _muted,
                  onTap: _toggleMute,
                ),
                const SizedBox(width: 24),
                GestureDetector(
                  onTap: _hangUp,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.call_end_rounded,
                        color: Colors.white, size: 30),
                  ),
                ),
                const SizedBox(width: 24),
                _CallIconButton(
                  icon: _speakerOn
                      ? Icons.volume_up_rounded
                      : Icons.volume_down_rounded,
                  active: _speakerOn,
                  onTap: _toggleSpeaker,
                ),
              ],
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

/// Nút tròn dùng chung cho thanh điều khiển cuộc gọi (mute, đổi camera,
/// loa ngoài...). `active` = true khi tính năng đang BẬT (ví dụ đang mute)
/// → tô nền sáng để phân biệt rõ trạng thái đang bật/tắt.
class _CallIconButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _CallIconButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withOpacity(0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: active ? Colors.black87 : Colors.white,
          size: 24,
        ),
      ),
    );
  }
}