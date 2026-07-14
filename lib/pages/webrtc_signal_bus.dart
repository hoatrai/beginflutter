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

  // 🆕 FIX: hàng đợi tín hiệu webrtc_offer/answer/ice đến TRƯỚC khi `pc`
  // (RTCPeerConnection) được tạo xong. Trước đây `handle()` có
  // `if (pc == null) return;` khiến những tín hiệu đến sớm bị VỨT THẲNG,
  // không hề được lưu lại — đây chính là nguyên nhân "thỉnh thoảng bắt
  // máy xong không thấy hình/không có tiếng": bên gọi tạo & gửi offer
  // nhanh hơn thời gian bên nghe xin quyền camera/mic + tạo xong pc (đặc
  // biệt máy yếu hoặc lần đầu hiện popup xin quyền), offer/ice tới sớm bị
  // mất, không có SDP exchange nên không bao giờ có track. Giờ những tín
  // hiệu đến sớm được xếp hàng, và được xử lý lại (theo đúng thứ tự) ngay
  // khi `pc` sẵn sàng qua `flushPending()`.
  final List<Map<String, dynamic>> _pendingSignals = [];

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
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final event = msg["event"];

    // call_end / call_reject cần xử lý dù `pc` chưa được tạo (ví dụ người
    // gọi hủy trước khi người nghe kịp bấm "Nghe" / mở VideoCallPage).
    if (event == "call_end" || event == "call_reject") {
      _callEndedCtrl.add(event.toString());
      // Cuộc gọi đã kết thúc/bị từ chối trước khi kịp xử lý -> hàng đợi
      // (nếu có) không còn ý nghĩa gì nữa, dọn luôn tránh rò rỉ.
      _pendingSignals.clear();
      return;
    }

    if (!event.toString().startsWith("webrtc_")) return;

    // 🆕 FIX: `pc` chưa sẵn sàng (VideoCallPage còn đang xin quyền
    // camera/mic / tạo peer connection) -> XẾP HÀNG thay vì vứt bỏ.
    // `flushPending()` sẽ xử lý lại đúng thứ tự ngay khi `pc` có giá trị.
    if (pc == null) {
      print("⏳ WebRTC Signal queued (pc chưa sẵn sàng): $event");
      _pendingSignals.add(msg);
      return;
    }

    await _process(msg);
  }

  /// Xử lý lại toàn bộ tín hiệu đã bị xếp hàng vì tới sớm (trước khi `pc`
  /// được tạo xong). PHẢI gọi hàm này ngay sau khi gán
  /// `WebRTCSignalBus.instance.pc = pc;` trong VideoCallPage._init(),
  /// nếu không những offer/ice đến sớm sẽ nằm im trong hàng đợi mãi mãi.
  Future<void> flushPending() async {
    if (_pendingSignals.isEmpty) return;
    final queued = List<Map<String, dynamic>>.from(_pendingSignals);
    _pendingSignals.clear();
    print("🔁 Flushing ${queued.length} tín hiệu webrtc bị xếp hàng trước đó");
    for (final msg in queued) {
      await _process(msg);
    }
  }

  /// Xử lý thật sự 1 message webrtc_* — tách riêng khỏi handle() để dùng
  /// chung được cho cả luồng "đến trực tiếp" lẫn luồng "flush hàng đợi".
  Future<void> _process(Map<String, dynamic> msg) async {
    final event = msg["event"];
    final payload = msg["payload"] ?? {};

    if (pc == null) return; // an toàn: lẽ ra không xảy ra khi gọi từ đây

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
    // 🆕 Dọn nốt hàng đợi (nếu còn sót) — tránh tín hiệu của cuộc gọi cũ
    // bị flush nhầm vào peer connection của cuộc gọi kế tiếp.
    _pendingSignals.clear();
  }
}