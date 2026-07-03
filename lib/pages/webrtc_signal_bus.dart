import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebRTCSignalBus {
  static final WebRTCSignalBus instance = WebRTCSignalBus._();
  WebRTCSignalBus._();

  RTCPeerConnection? pc;
  WebSocketChannel? socket;
  String? topic;

  // VideoCallPage lắng nghe stream này để biết khi nào pc.onTrack bắn ra
  // remote stream mới, thay vì tự đăng ký listen() trên socket gốc.
  final StreamController<MediaStream> _remoteStreamCtrl =
  StreamController<MediaStream>.broadcast();
  Stream<MediaStream> get onRemoteStream => _remoteStreamCtrl.stream;

  // Báo cho UI biết cuộc gọi đã kết thúc từ phía bên kia (call_end/call_reject).
  final StreamController<String> _callEndedCtrl =
  StreamController<String>.broadcast();
  Stream<String> get onCallEnded => _callEndedCtrl.stream;

  int _refCounter = 1000; // tránh trùng ref với chat

  /// Gắn socket khi mở call.
  ///
  /// ⚠️ KHÔNG tự `channel.stream.listen(...)` ở đây. WebSocketChannel.stream
  /// là single-subscription stream — nếu cả ChatPage và bus này cùng listen
  /// trên cùng 1 channel sẽ throw StateError("Stream has already been
  /// listened to"). ChatPage._onData là nơi DUY NHẤT được listen() trên
  /// socket; nó tự forward data thô cho `handle()` ở dưới.
  void bindSocket({
    required WebSocketChannel channel,
    required String topicName,
  }) {
    socket = channel;
    topic = topicName;
  }

  String _nextRef() => (_refCounter++).toString();

  /// ✅ Gửi signal (PHẢI có ref)
  void send(String event, Map payload) {
    if (socket == null) return;

    final msg = {
      "topic": topic,
      "event": event,
      "payload": payload,
      "ref": _nextRef(),   // ⭐ BẮT BUỘC
    };

    print("📤 WS SEND: $msg");
    socket!.sink.add(jsonEncode(msg));
  }

  /// Nhận signal từ server (data là chuỗi JSON thô, y nguyên những gì
  /// ChatPage._onData nhận được từ socket — bus này tự decode lại).
  void handle(dynamic data) async {
    dynamic msg;
    try {
      msg = jsonDecode(data);
    } catch (_) {
      return;
    }

    final event = msg["event"];
    final payload = msg["payload"] ?? {};

    // call_end / call_reject cần xử lý dù `pc` chưa được tạo (ví dụ người
    // gọi hủy trước khi người nghe kịp bấm "Nghe" / mở VideoCallPage).
    if (event == "call_end" || event == "call_reject") {
      _callEndedCtrl.add(event.toString());
      return;
    }

    if (pc == null) return;
    if (!event.toString().startsWith("webrtc_")) return;

    print("📩 WebRTC Signal: $event");

    // 📨 OFFER
    if (event == "webrtc_offer") {
      await pc!.setRemoteDescription(
        RTCSessionDescription(payload["sdp"], "offer"),
      );

      final answer = await pc!.createAnswer();
      await pc!.setLocalDescription(answer);

      send("webrtc_answer", {
        "sdp": answer.sdp,
      });
    }

    // 📨 ANSWER
    if (event == "webrtc_answer") {
      await pc!.setRemoteDescription(
        RTCSessionDescription(payload["sdp"], "answer"),
      );
    }

    // ❄ ICE
    if (event == "webrtc_ice") {
      await pc!.addCandidate(
        RTCIceCandidate(
          payload["candidate"],
          payload["sdpMid"],
          payload["sdpMLineIndex"],
        ),
      );
    }
  }

  /// Gọi 1 lần khi tạo xong RTCPeerConnection (trong VideoCallPage._init)
  /// để mọi remote track mới tự động đi qua [onRemoteStream].
  void bindPeerConnectionTrackListener() {
    pc?.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStreamCtrl.add(event.streams.first);
      }
    };
  }

  /// Dọn dẹp khi đóng màn hình gọi. KHÔNG đóng _remoteStreamCtrl /
  /// _callEndedCtrl vì bus này là singleton tồn tại suốt đời app — chỉ
  /// reset pc/socket/topic để lần gọi sau không dùng nhầm peer connection cũ.
  void reset() {
    pc = null;
    socket = null;
    topic = null;
  }
}