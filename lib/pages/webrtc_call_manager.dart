import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'webrtc_signal_bus.dart';

class WebRTCCallManager {
  static final WebRTCCallManager instance = WebRTCCallManager._();
  WebRTCCallManager._();

  RTCPeerConnection? pc;
  MediaStream? localStream;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  bool initialized = false;

  // ---------------- INIT ----------------
  Future<void> init() async {
    if (initialized) return;

    await localRenderer.initialize();
    await remoteRenderer.initialize();

    final config = {
      "iceServers": [
        {"urls": "stun:stun.l.google.com:19302"}
      ]
    };

    pc = await createPeerConnection(config);

    // 👉 Khi có stream remote
    pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
      }
    };

    // 👉 ICE gửi qua signal
    pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;

      WebRTCSignalBus.instance.send("webrtc_ice", {
        "candidate": candidate.candidate,
        "sdpMid": candidate.sdpMid,
        "sdpMLineIndex": candidate.sdpMLineIndex,
      });
    };

    // 👉 Lấy camera + mic
    localStream = await navigator.mediaDevices.getUserMedia({
      "video": true,
      "audio": true,
    });

    // 👉 Gắn track vào PC
    for (var track in localStream!.getTracks()) {
      pc!.addTrack(track, localStream!);
    }

    localRenderer.srcObject = localStream;

    // 🔗 Bind PC cho signal bus
    WebRTCSignalBus.instance.pc = pc;

    initialized = true;
  }

  // ---------------- START CALL (CALLER) ----------------
  Future<void> startCall() async {
    if (pc == null) return;

    final offer = await pc!.createOffer();
    await pc!.setLocalDescription(offer);

    WebRTCSignalBus.instance.send("webrtc_offer", {
      "sdp": offer.sdp,
    });

    print("📤 Sent OFFER");
  }

  // ---------------- CLEANUP ----------------
  void dispose() {
    initialized = false;
    localRenderer.dispose();
    remoteRenderer.dispose();
    localStream?.dispose();
    pc?.close();
    pc = null;
  }
}
