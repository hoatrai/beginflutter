import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Global key để show SnackBar từ bất kỳ page nào
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  late WebSocketChannel channel;
  int _refCounter = 1;

  // Messages và participants toàn app
  ValueNotifier<List<Message>> messages = ValueNotifier([]);
  ValueNotifier<List<Participant>> participants = ValueNotifier([]);

  // Kết nối WebSocket
  void connect(String url, String topic, {int currentUserId = 0}) {
    channel = WebSocketChannel.connect(Uri.parse(url));

    channel.stream.listen(
          (data) => _onData(data, currentUserId),
      onError: (e) => print("❌ SOCKET ERROR: $e"),
      onDone: () => print("🔌 SOCKET CLOSED"),
    );

    // Join topic
    channel.sink.add(jsonEncode({
      "topic": topic,
      "event": "phx_join",
      "payload": {},
      "ref": "${_refCounter++}"
    }));
  }

  void _onData(dynamic data, int currentUserId) {
    try {
      final decoded = jsonDecode(data);
      final event = decoded["event"];
      final payload = decoded["payload"];

      if (event == "user_joined") {
        final joinedUserId = int.tryParse(payload["user_id"].toString()) ?? 0;
        final username = payload["username"] ?? "Người dùng";

        final messageText = joinedUserId == currentUserId
            ? "🎉 Bạn đã tham gia nhóm"
            : "👤 $username đã tham gia nhóm";

        // 1️⃣ Show SnackBar toàn app
        final context = navigatorKey.currentContext;
        if (context != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(messageText),
              duration: const Duration(seconds: 2),
            ),
          );
        }

        // 2️⃣ Thêm message hệ thống
        messages.value = [
          ...messages.value,
          Message(
            id: "system_${DateTime.now().millisecondsSinceEpoch}",
            senderId: 0,
            senderName: "Hệ thống",
            content: messageText,
            time: DateTime.now(),
            isOwn: false,
            avatarUrl: null,
          )
        ];

        // 3️⃣ Cập nhật participants
        if (!participants.value.any((p) => p.userId == joinedUserId)) {
          participants.value = [
            ...participants.value,
            Participant(
              userId: joinedUserId,
              username: username,
              avatarUrl: payload["avatar_url"],
            )
          ];
        }
      }

      // TODO: handle các event khác: new_message, typing...
    } catch (e) {
      print("💥 JSON ERROR: $e");
    }
  }

  // Gửi message (ví dụ)
  void sendMessage(String topic, String content, int senderId, String senderName) {
    final payload = {
      "topic": topic,
      "event": "new_message",
      "payload": {
        "sender_id": senderId,
        "sender_name": senderName,
        "content": content,
      },
      "ref": "${_refCounter++}"
    };
    channel.sink.add(jsonEncode(payload));
  }
}

// ---------------- Models ----------------
class Message {
  final String id;
  final int senderId;
  final String senderName;
  final String content;
  final DateTime time;
  final bool isOwn;
  final String? avatarUrl;

  Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.time,
    required this.isOwn,
    this.avatarUrl,
  });
}

class Participant {
  final int userId;
  final String username;
  final String? avatarUrl;

  Participant({
    required this.userId,
    required this.username,
    this.avatarUrl,
  });
}
