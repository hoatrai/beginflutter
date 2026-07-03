import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  /// Chỉ dùng cho UI màn hình gọi thoại (avatar + tên đối phương).
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

  // ---- chỉ dùng cho UI gọi thoại ----
  bool _muted = false;
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

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$m:$s";
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

  Widget _buildVideoUI() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(
              remote,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
          Positioned(
            right: 12,
            top: 40,
            width: 120,
            height: 160,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white24),
                borderRadius: BorderRadius.circular(8),
              ),
              child: RTCVideoView(local, mirror: true),
            ),
          ),
          if (!initialized)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton(
                backgroundColor: Colors.red,
                onPressed: _hangUp,
                child: const Icon(Icons.call_end),
              ),
            ),
          )
        ],
      ),
    );
  }

  /// Màn hình gọi thoại — không có camera nên không có gì để render
  /// RTCVideoView, thay vào đó hiện avatar + tên + thời gian gọi, đồng bộ
  /// phong cách tối giản với _OutgoingCallScreen ở chat_page.dart.
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
                GestureDetector(
                  onTap: _toggleMute,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: _muted ? Colors.white : Colors.white12,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _muted ? Icons.mic_off : Icons.mic,
                      color: _muted ? Colors.black : Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 28),
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
              ],
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}