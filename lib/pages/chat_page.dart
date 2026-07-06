import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import '../main.dart';
import '../app_globals.dart';
import 'user_info_page.dart'; // Trang profile người dùng nếu có
import 'video_call_page.dart';
import 'webrtc_signal_bus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';
import '../config/app_config.dart';

// ✅ Danh sách biểu cảm nhanh dùng cho ticker/reaction
const List<String> kQuickReactions = ['👍', '❤️', '😆', '😮', '😢', '😡'];

Future<bool> requestCallPermissions() async {
  final statuses = await [
    Permission.camera,
    Permission.microphone,
  ].request();

  return statuses[Permission.camera]!.isGranted &&
      statuses[Permission.microphone]!.isGranted;
}


class ChatPage extends StatefulWidget {
  final int userId;
  final String username;
  final int targetId;
  final String targetUser;
  final String? targetAvatar;
  final String serverUrl;

  const ChatPage({
    super.key,
    required this.userId,
    required this.username,
    required this.targetId,
    required this.targetUser,
    this.targetAvatar,
    this.serverUrl = AppConfig.websocketUrl,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late WebSocketChannel channel;
  final ValueNotifier<List<_Message>> messages = ValueNotifier([]);
  final ValueNotifier<String?> typingUserNotifier = ValueNotifier(null);
  final TextEditingController input = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();

  // ---------------- EMOJI PICKER ----------------
  bool _showEmojiPicker = false;
  final FocusNode _inputFocusNode = FocusNode();




  bool _loading = true;
  bool _uploading = false;

  bool _isReconnecting = false;
  bool _isConnected = false;

  OverlayEntry? _incomingCallOverlay;
  VoidCallback? _incomingCallBannerDismiss;




  Timer? _typingTimer;
  Timer? _heartbeatTimer;
  int refCounter = 1;
  bool _hasJoinedRoom = false;
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  // Nhớ callType của cuộc gọi mình vừa bấm "Gọi" — dùng cho fallback ở
  // event "call_accept" khi _onCallAccepted đã bị null (hiếm, do race
  // condition), để _openCall vẫn mở đúng UI voice/video.
  String _currentCallType = "video";

  @override
  void initState() {
    super.initState();
    isChatPageOpen = true;
    currentChatTargetId = widget.targetId;
    _loadOldMessages();
    connectSocket();
    _markChatAsRead(); // ✅ thêm dòng này
  }

  @override
  void dispose() {
    isChatPageOpen = false;
    currentChatTargetId = null;
    _typingTimer?.cancel();
    _heartbeatTimer?.cancel();
    _incomingCallOverlay?.remove();
    _incomingCallOverlay = null;
    _incomingCallBannerDismiss = null;
    //channel.sink.close();
    scrollController.dispose();
    input.dispose();
    messages.dispose();
    typingUserNotifier.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // ---------------- SOCKET ----------------
  String getTopic() {
    final ids = [widget.userId, widget.targetId]..sort();
    return "room:chat_${ids[0]}_${ids[1]}";
  }

  void _callVideo() async {
    final ok = await requestCallPermissions();
    debugPrint("PERMISSION OK = $ok");
    if (!ok) {
      debugPrint("❌ User từ chối camera/mic");
      return;
    }

    print("📹 CLICK CALL VIDEO");

    channel.sink.add(jsonEncode({
      "topic": getTopic(),
      "event": "call_invite",
      "payload": {
        "from_id": widget.userId,
        "from_name": widget.username,
        "call_type": "video",
      },
      "ref": "${refCounter++}"
    }));

    // 🔔 Phát chuông "đang gọi" liên tục cho tới khi: bên kia bấm Nghe
    // (→ _openCall sẽ tự stop), bên kia từ chối, hoặc mình tự bấm Hủy.
    FlutterRingtonePlayer().play(
      android: AndroidSounds.ringtone,
      ios: IosSounds.electronic,
      looping: true,
      volume: 0.6,
      asAlarm: false,
    );

    // 📞 Hiện màn hình "Đang gọi..." — KHÔNG mở thẳng VideoCallPage ở đây.
    // VideoCallPage chỉ mở khi nhận được "call_accept" (xử lý trong
    // _OutgoingCallScreen, vì nó cũng cần tự lắng nghe _onData qua callback
    // để biết khi nào đối phương bấm Nghe / Từ chối).
    _showOutgoingCallScreen(callType: "video");
  }

  void _callVoice() async {
    final ok = await Permission.microphone.request();
    if (!ok.isGranted) {
      debugPrint("❌ User từ chối microphone");
      return;
    }

    print("📞 CLICK CALL VOICE");

    channel.sink.add(jsonEncode({
      "topic": getTopic(),
      "event": "call_invite",
      "payload": {
        "from_id": widget.userId,
        "from_name": widget.username,
        "call_type": "voice",
      },
      "ref": "${refCounter++}"
    }));

    FlutterRingtonePlayer().play(
      android: AndroidSounds.ringtone,
      ios: IosSounds.electronic,
      looping: true,
      volume: 0.6,
      asAlarm: false,
    );

    _showOutgoingCallScreen(callType: "voice");
  }

  /// Điều khiển bởi _onData: gọi callback tương ứng khi nhận call_accept
  /// hoặc call_reject, để màn hình "Đang gọi..." biết phải làm gì tiếp.
  VoidCallback? _onCallAccepted;
  VoidCallback? _onCallRejectedWhileCalling;

  void _showOutgoingCallScreen({String callType = "video"}) {
    _currentCallType = callType;
    _onCallAccepted = () {
      FlutterRingtonePlayer().stop();
      if (Navigator.canPop(context)) Navigator.pop(context); // đóng "Đang gọi..."
      _openCall(true, callType: callType);
    };
    _onCallRejectedWhileCalling = () {
      FlutterRingtonePlayer().stop();
      if (Navigator.canPop(context)) Navigator.pop(context); // đóng "Đang gọi..."
    };

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _OutgoingCallScreen(
          targetName: widget.targetUser,
          targetAvatar: widget.targetAvatar,
          callType: callType,
          onCancel: () {
            FlutterRingtonePlayer().stop();
            channel.sink.add(jsonEncode({
              "topic": getTopic(),
              "event": "call_end",
              "payload": {},
              "ref": "${refCounter++}"
            }));
            Navigator.pop(context);
          },
        ),
      ),
    ).then((_) {
      // Màn hình "Đang gọi..." đã bị pop (bằng bất kỳ cách nào) — dọn
      // callback để tránh gọi nhầm vào lần gọi tiếp theo.
      _onCallAccepted = null;
      _onCallRejectedWhileCalling = null;
    });
  }

  /// Popup "có cuộc gọi đến" kiểu thông báo iOS — trượt từ mép trên xuống,
  /// không che hết màn hình như AlertDialog cũ.
  void _showIncomingCall(String fromName, {String callType = "video"}) {
    // Nếu đã có popup đang hiện (ví dụ do double-tap nút gọi ở phía đối
    // phương), bỏ cái cũ trước khi tạo cái mới, tránh chồng 2 overlay.
    _incomingCallOverlay?.remove();
    _incomingCallOverlay = null;

    // 🔔 Chuông báo có cuộc gọi đến — dùng âm khác kiểu với chuông "đang
    // gọi" của người gọi (notification thay vì ringtone) để không bị
    // nhầm lẫn khi 2 người cùng dùng máy gần nhau lúc test.
    FlutterRingtonePlayer().play(
      android: AndroidSounds.notification,
      ios: IosSounds.glass,
      looping: true,
      volume: 0.6,
      asAlarm: false,
    );

    final overlay = Overlay.of(context);
    late AnimationController controller;

    void dismiss() {
      FlutterRingtonePlayer().stop();
      controller.reverse().then((_) {
        _incomingCallOverlay?.remove();
        _incomingCallOverlay = null;
        _incomingCallBannerDismiss = null;
        controller.dispose();
      });
    }
    _incomingCallBannerDismiss = dismiss;

    final entry = OverlayEntry(
      builder: (overlayContext) {
        return _IncomingCallBanner(
          fromName: fromName,
          avatarUrl: widget.targetAvatar,
          callType: callType,
          onCreateController: (c) => controller = c,
          onAccept: () {
            dismiss();
            channel.sink.add(jsonEncode({
              "topic": getTopic(),
              "event": "call_accept",
              "payload": {},
              "ref": "${refCounter++}"
            }));
            _openCall(false, callType: callType);
          },
          onReject: () {
            dismiss();
            // Báo cho người gọi biết mình đã từ chối, tránh họ bị treo
            // chờ "call_accept" vô thời hạn. Cần server có handle_in
            // "call_reject" + broadcast_from! (đã thêm ở RoomChannel).
            channel.sink.add(jsonEncode({
              "topic": getTopic(),
              "event": "call_reject",
              "payload": {},
              "ref": "${refCounter++}"
            }));
          },
        );
      },
    );

    _incomingCallOverlay = entry;
    overlay.insert(entry);
  }
  void _openCall(bool isCaller, {String callType = "video"}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoCallPage(
          socket: channel,
          topic: getTopic(),
          isCaller: isCaller,
          callType: callType,
          targetName: widget.targetUser,
          targetAvatar: widget.targetAvatar,
        ),
      ),
    );
  }

  void _reconnectSocket() async {
    if (_isReconnecting) return;

    _isReconnecting = true;

    await Future.delayed(const Duration(seconds: 2));

    if (mounted) {
      connectSocket();
    }

    _isReconnecting = false;
  }

  void connectSocket() {
    try {
      channel = WebSocketChannel.connect(Uri.parse(widget.serverUrl));

      _isConnected = true;
      print("🚀 CONNECT OK");

      channel.stream.listen(
            (data) => _onData(data),

        onDone: () {
          print("🔌 SOCKET CLOSED");

          _isConnected = false;

          _reconnectSocket();
        },

        onError: (err) {
          print("❌ SOCKET ERROR: $err");

          _isConnected = false;

          _reconnectSocket();
        },
      );

      Future.delayed(const Duration(milliseconds: 300), () {
        if (!_hasJoinedRoom) {
          _joinRoom();
          _initUser();
          _startHeartbeat();
        }
      });

    } catch (e) {
      print("❌ CONNECT FAIL: $e");
      _isConnected = false;
      _reconnectSocket();
    }
  }



  void _joinRoom() {
    if (_hasJoinedRoom) return;
    final join = {
      "topic": getTopic(),
      "event": "phx_join",
      "payload": {},
      "ref": "${refCounter++}"
    };
    channel.sink.add(jsonEncode(join));
    _hasJoinedRoom = true;
  }

  void _initUser() {
    final msg = {
      "topic": getTopic(),
      "event": "init_user",
      "payload": {"user_id": widget.userId, "username": widget.username},
      "ref": "${refCounter++}"
    };
    channel.sink.add(jsonEncode(msg));
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      final heartbeat = {
        "topic": "phoenix",
        "event": "heartbeat",
        "payload": {},
        "ref": "${refCounter++}"
      };
      channel.sink.add(jsonEncode(heartbeat));
    });
  }

  void deleteMessage(String messageId) async {
    print("🗑️ Đang xóa message với ID: $messageId"); // <-- thêm dòng này
    try {
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/delete-message"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"id": messageId}),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true) {

          // 🔥 Broadcast delete realtime
          channel.sink.add(jsonEncode({
            "topic": getTopic(),
            "event": "delete_message",
            "payload": {
              "id": messageId,
            },
            "ref": "${refCounter++}"
          }));

          // Xóa local
          messages.value =
              messages.value.where((m) => m.id != messageId).toList();
          messages.notifyListeners();
        }
        else {
          print("❌ Xóa thất bại");
        }
      } else {
        print("❌ Lỗi server: ${res.statusCode}");
      }
    } catch (e) {
      print("❌ Lỗi deleteMessage: $e");
    }
  }

  // ✅ Đánh dấu đã đọc toàn bộ tin nhắn từ targetId gửi cho mình
  Future<void> _markChatAsRead() async {
    try {
      await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/mark-chat-read"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "user_id": widget.userId,
          "target_id": widget.targetId,
        }),
      );
    } catch (e) {
      debugPrint("❌ Lỗi đánh dấu đã đọc: $e");
    }
  }

  // ---------------- REACTIONS (ticker biểu cảm) ----------------
  Future<void> _toggleReaction(_Message msg, String emoji) async {
    final uid = widget.userId;
    final current = List<int>.from(msg.reactions[emoji] ?? []);
    final alreadyReacted = current.contains(uid);

    // ✅ Cập nhật UI ngay (optimistic update)
    if (alreadyReacted) {
      current.remove(uid);
      if (current.isEmpty) {
        msg.reactions.remove(emoji);
      } else {
        msg.reactions[emoji] = current;
      }
    } else {
      msg.reactions[emoji] = [...current, uid];
    }
    messages.notifyListeners();

    final endpoint = alreadyReacted ? "remove-reaction" : "add-reaction";

    try {
      // ✅ Lưu DB trước (giống pattern send-message), message_type=private
      // để phân biệt với reaction của group chat trong cùng bảng dùng chung.
      await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/$endpoint"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "message_id": msg.id,
          "user_id": uid,
          "emoji": emoji,
          "message_type": "private",
        }),
      );

      // ✅ Rồi mới báo realtime cho đối phương
      channel.sink.add(jsonEncode({
        "topic": getTopic(),
        "event": alreadyReacted ? "remove_reaction" : "add_reaction",
        "payload": {
          "message_id": msg.id,
          "emoji": emoji,
          "user_id": uid,
          "username": widget.username,
        },
        "ref": "${refCounter++}"
      }));
    } catch (e) {
      debugPrint("❌ Reaction sync error: $e");
      // Lưu DB thất bại thì rollback lại UI cho khỏi lệch dữ liệu
      if (alreadyReacted) {
        msg.reactions[emoji] = [...current, uid];
      } else {
        final rollback = List<int>.from(msg.reactions[emoji] ?? []);
        rollback.remove(uid);
        if (rollback.isEmpty) {
          msg.reactions.remove(emoji);
        } else {
          msg.reactions[emoji] = rollback;
        }
      }
      messages.notifyListeners();
    }
  }

  // ---------------- EMOJI PICKER (nhập emoji vào ô tin nhắn) ----------------
  void _toggleEmojiPicker() {
    if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
      _inputFocusNode.requestFocus();
    } else {
      // Ẩn bàn phím hệ thống trước khi hiện bảng emoji, tránh 2 bàn phím
      // (system keyboard + emoji picker) tranh nhau không gian phía dưới.
      _inputFocusNode.unfocus();
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) setState(() => _showEmojiPicker = true);
      });
    }
  }

  void _onEmojiSelected(Category? category, Emoji emoji) {
    input.text += emoji.emoji;
    input.selection = TextSelection.fromPosition(
      TextPosition(offset: input.text.length),
    );
    sendTyping(); // vẫn báo "đang gõ" như gõ bàn phím bình thường
    setState(() {});
  }

  void _onEmojiBackspacePressed() {
    if (input.text.isEmpty) return;
    input.text = input.text.characters.skipLast(1).toString();
    input.selection = TextSelection.fromPosition(
      TextPosition(offset: input.text.length),
    );
    setState(() {});
  }


  void sendMessage() async {
    final text = input.text.trim();
    if (text.isEmpty) return;

    // Clear input cho mượt UI
    input.clear();
    setState(() {});
    _stopTyping();

    // ===============================
    // 🚀 OPTIMISTIC UI - HIỆN TIN NGAY
    // ===============================
    final tempId = "local_${DateTime.now().millisecondsSinceEpoch}";

    final tempMsg = _Message(
      id: tempId,
      senderId: widget.userId.toString(),
      senderName: widget.username,
      senderAvatar: '',
      content: text,
      time: DateTime.now(),
      isOwn: true,
    );

    messages.value = List<_Message>.from(messages.value)..add(tempMsg);
    messages.notifyListeners();
    _scrollToBottom();
    // ===============================

    try {
      // 1️⃣ Gọi API để lưu DB và lấy ID thật
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/send-message"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "sender_id": widget.userId,
          "receiver_id": widget.targetId,
          "message": text,
        }),
      );

      if (res.statusCode != 200) {
        debugPrint("❌ Send API failed: ${res.statusCode}");
        throw Exception("API error");
      }

      final data = jsonDecode(res.body);
      final realId = data['id'];
      if (realId == null) {
        debugPrint("❌ API không trả về id");
        throw Exception("Missing id");
      }

      // 🔁 REPLACE tempId -> realId (sync lại message local)
      final idx = messages.value.indexWhere((m) => m.id == tempId);
      if (idx != -1) {
        final old = messages.value[idx];
        messages.value[idx] = _Message(
          id: realId.toString(),
          senderId: old.senderId,
          senderName: old.senderName,
          senderAvatar: old.senderAvatar,
          content: old.content,
          time: old.time,
          isOwn: true,
        );
        messages.notifyListeners();
      }

      // 2️⃣ Gửi socket để user khác nhận realtime
      final msg = {
        "topic": getTopic(),
        "event": "send_message",
        "payload": {
          "id": realId,
          "receiver_id": widget.targetId,
          "content": text,
        },
        "ref": "${refCounter++}"
      };

      channel.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint("❌ sendMessage error: $e");

      // ❌ Nếu lỗi: xóa temp message hoặc đánh dấu lỗi (tuỳ bạn)
      messages.value =
          messages.value.where((m) => m.id != tempId).toList();
      messages.notifyListeners();
    }
  }



  void sendTyping() {
    _typingTimer?.cancel();
    final msg = {
      "topic": getTopic(),
      "event": "typing",
      "payload": {"username": widget.username, "target_id": widget.targetId},
      "ref": "${refCounter++}"
    };
    channel.sink.add(jsonEncode(msg));
    _typingTimer = Timer(const Duration(milliseconds: 800), _stopTyping);
  }

  void _stopTyping() {
    final msg = {
      "topic": getTopic(),
      "event": "stop_typing",
      "payload": {"target_id": widget.targetId},
      "ref": "${refCounter++}"
    };
    channel.sink.add(jsonEncode(msg));
  }

  void _onData(dynamic data) {
    dynamic decoded;
    try {
      decoded = jsonDecode(data);
    } catch (e) {
      print("💥 JSON ERROR: $e");
      return;
    }

    final event = decoded["event"];
    final payload = decoded["payload"];


    if (event == "new_message") {
      final senderId = payload["sender_id"];
      final isOwn = senderId == widget.userId;

      final rawType = payload["type"] ?? "text";
      MessageType msgType = MessageType.text;
      if (rawType == "image") msgType = MessageType.image;
      if (rawType == "file") msgType = MessageType.file;

      final fileUrl = payload["file_url"] ?? payload["content"]; // fallback base64

      final m = _Message(
        id: payload["id"]?.toString() ?? "local_${DateTime.now().millisecondsSinceEpoch}",
        senderId: senderId.toString(),
        senderName: payload["sender_name"] ?? "Người dùng",
        senderAvatar: payload["sender_avatar"] ?? (isOwn ? '' : widget.targetAvatar ?? ''),
        content: payload["content"] ?? '',
        time: (DateTime.tryParse(payload["created_at"] ?? '') ?? DateTime.now().toUtc())
            .toUtc()
            .add(const Duration(hours: 7)),
        isOwn: isOwn,
        type: msgType,
        fileUrl: fileUrl,
        fileName: payload["file_name"],
      );

      if (!messages.value.any((msg) => msg.id == m.id)) {
        messages.value = List<_Message>.from(messages.value)..add(m);
        messages.notifyListeners();
        _scrollToBottom();
        if (!isOwn) _markChatAsRead();
      }
    }

    // ✅ Có người thả biểu cảm cho 1 tin nhắn
    if (event == "reaction_added") {
      final messageId = payload["message_id"]?.toString();
      final emoji = payload["emoji"]?.toString();
      final userId = int.tryParse(payload["user_id"].toString()) ?? 0;

      if (messageId != null && emoji != null) {
        final idx = messages.value.indexWhere((m) => m.id == messageId);
        if (idx != -1) {
          final list = List<int>.from(messages.value[idx].reactions[emoji] ?? []);
          if (!list.contains(userId)) {
            list.add(userId);
            messages.value[idx].reactions[emoji] = list;
            messages.notifyListeners();
          }
        }
      }
    }

    // ✅ Có người bỏ biểu cảm khỏi 1 tin nhắn
    if (event == "reaction_removed") {
      final messageId = payload["message_id"]?.toString();
      final emoji = payload["emoji"]?.toString();
      final userId = int.tryParse(payload["user_id"].toString()) ?? 0;

      if (messageId != null && emoji != null) {
        final idx = messages.value.indexWhere((m) => m.id == messageId);
        if (idx != -1) {
          final list = List<int>.from(messages.value[idx].reactions[emoji] ?? []);
          list.remove(userId);
          if (list.isEmpty) {
            messages.value[idx].reactions.remove(emoji);
          } else {
            messages.value[idx].reactions[emoji] = list;
          }
          messages.notifyListeners();
        }
      }
    }

    if (event == "typing") {
      final senderId = payload["sender_id"];
      final username = payload["username"];
      if (senderId != widget.userId) typingUserNotifier.value = username;
    }

    if (event == "stop_typing") {
      typingUserNotifier.value = null;
    }

    if (event == "call_invite") {
      final callType = payload["call_type"] as String? ?? "video";
      _showIncomingCall(payload["from_name"], callType: callType);
    }

    // Người gọi tự bấm "Hủy" ở màn hình "Đang gọi..." trong lúc mình vẫn
    // đang thấy popup "có cuộc gọi đến" — phải tự đóng popup + dừng chuông,
    // không đợi mình bấm gì cả, nếu không popup treo vô thời hạn dù người
    // gọi đã hủy từ lâu.
    if (event == "call_end") {
      _incomingCallBannerDismiss?.call();
    }

    if (event == "call_accept") {
      // Nếu mình đang ở màn hình "Đang gọi..." (_onCallAccepted != null),
      // dùng callback đó để stop chuông + đóng màn hình + mở VideoCallPage
      // đúng thứ tự. Nếu callback null (trường hợp hiếm: nhận call_accept
      // mà không ở màn hình đang gọi), fallback về cách cũ.
      if (_onCallAccepted != null) {
        _onCallAccepted!();
      } else {
        _openCall(true, callType: _currentCallType);
      }
    }

    // Đối phương bấm "Từ chối" trước khi mình mở được VideoCallPage —
    // chỉ cần báo cho người gọi, không có UI nào đang mở để pop cả
    // (khác với call_reject nhận TRONG lúc đang ở VideoCallPage, việc đó
    // do WebRTCSignalBus.onCallEnded xử lý).
    if (event == "call_reject") {
      if (_onCallRejectedWhileCalling != null) {
        _onCallRejectedWhileCalling!();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Đối phương đã từ chối cuộc gọi")),
        );
      }
    }

    if (event == "delete_message") {
      final id = payload["id"].toString();

      messages.value =
          messages.value.where((m) => m.id != id).toList();
      messages.notifyListeners();
    }


    // ✅ THÊM DÒNG NÀY (CUỐI HÀM)
    WebRTCSignalBus.instance.handle(data);

  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;
      final offset = scrollController.position.hasPixels
          ? scrollController.position.minScrollExtent
          : 0.0;
      scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> pickImage() async {
    if (_showEmojiPicker) setState(() => _showEmojiPicker = false);

    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (file == null) return;

    final bytes = await file.readAsBytes();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("🖼️ Gửi ảnh?"),
        content: Image.memory(bytes),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Hủy")),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Gửi")),
        ],
      ),
    );

    if (ok == true) {
      final tempId = "local_${DateTime.now().millisecondsSinceEpoch}";

      // ⭐️ TẠO TEMP MESSAGE HIỂN THỊ NGAY
      final tempMsg = _Message(
        id: tempId,
        senderId: widget.userId.toString(),
        senderName: widget.username,
        senderAvatar: '',
        content: base64Encode(bytes), // <-- lưu local ảnh dưới dạng base64
        fileName: file.name,
        time: DateTime.now(),
        isOwn: true,
        type: MessageType.image,
      );

      messages.value = [...messages.value, tempMsg];
      messages.notifyListeners();
      _scrollToBottom();

      // upload lên server, có thể truyền tempId để update message sau khi upload xong
      uploadFile(bytes, file.name, MessageType.image, tempId: tempId);
    }
  }


  Future<void> pickFile() async {
    if (_showEmojiPicker) setState(() => _showEmojiPicker = false);

    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return;

    final file = result.files.first;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("📎 Gửi file?"),
        content: Text(file.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Hủy")),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Gửi")),
        ],
      ),
    );

    if (ok == true) {
      uploadFile(file.bytes!, file.name, MessageType.file);
    }
  }

  Future<void> uploadFile(
      Uint8List bytes,
      String filename,
      MessageType type, {
        String? tempId,
      }) async {
    if (_uploading) return;

    try {
      setState(() => _uploading = true);

      // 1️⃣ Nếu chưa có tempId → tạo temp message hiển thị ngay
      if (tempId == null) {
        tempId = "local_${DateTime.now().millisecondsSinceEpoch}";
        final tempMsg = _Message(
          id: tempId,
          senderId: widget.userId.toString(),
          senderName: widget.username,
          senderAvatar: '',
          content: '', // file chưa upload nên content rỗng
          fileName: filename,
          time: DateTime.now(),
          isOwn: true,
          type: type,
        );
        messages.value = [...messages.value, tempMsg];
        messages.notifyListeners();
        _scrollToBottom();
      }

      // 2️⃣ Upload file lên server
      final request = http.MultipartRequest(
        "POST",
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/upload"),
      );

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
        ),
      );

      request.fields['sender_id'] = widget.userId.toString();
      request.fields['receiver_id'] = widget.targetId.toString();
      request.fields['message'] = ''; // optional caption

      final res = await request.send();
      final body = await res.stream.bytesToString();

      debugPrint("Upload response: $body");

      final data = jsonDecode(body);

      if (data['success'] != true || data['url'] == null) {
        throw Exception("Upload failed: ${data['message'] ?? 'Unknown error'}");
      }

      final url = data['url'];
      final filenameFromServer = data['filename'] ?? filename;

      // 3️⃣ Update message local với URL + filename + realId
      final realId = data['id']?.toString() ?? tempId; // dùng ID thật
      final idx = messages.value.indexWhere((m) => m.id == tempId);
      if (idx != -1) {
        final old = messages.value[idx];
        messages.value[idx] = _Message(
          id: realId,  // <-- dùng ID thật
          senderId: old.senderId,
          senderName: old.senderName,
          senderAvatar: old.senderAvatar,
          content: old.content, // giữ base64 hoặc rỗng
          fileName: filenameFromServer,
          fileUrl: url,
          time: old.time,
          isOwn: old.isOwn,
          type: old.type,
        );
        messages.notifyListeners();
      }

      // 4️⃣ Gửi socket để user khác nhận realtime với ID thật
      sendMediaMessage(url, filenameFromServer, type, realId);

    } catch (e) {
      debugPrint("❌ Upload error: $e");
    } finally {
      setState(() => _uploading = false);
    }
  }

  String messageTypeToString(MessageType type) {
    switch (type) {
      case MessageType.image:
        return "image";
      case MessageType.file:
        return "file";
      default:
        return "text";
    }
  }

  void sendMediaMessage(
      String url,
      String filename,
      MessageType type,
      String messageId,
      ) {
    final typeString = messageTypeToString(type);

    debugPrint("🚀 SEND MEDIA | type=$typeString | file=$filename");

    channel.sink.add(jsonEncode({
      "topic": getTopic(),
      "event": "send_message",
      "payload": {
        "id": messageId,
        "type": typeString,      // ✅ FIX
        "content": "",
        "file_name": filename,
        "file_url": url,
        "receiver_id": widget.targetId,
      },
      "ref": "${refCounter++}"
    }));
  }









  // ---------------- LOAD OLD MESSAGES ----------------
  Future<void> _loadOldMessages() async {
    try {
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/get-messages"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "user1_id": widget.userId,
          "user2_id": widget.targetId,
        }),
      );
      if (res.statusCode == 200) {
        final List data = jsonDecode(res.body)['messages'] ?? [];
        messages.value = data.map<_Message>((m) {
          final senderId = m['sender_id'].toString();
          final isOwn = senderId == widget.userId.toString();
          final rawType = m['type'] ?? 'text';
          MessageType msgType = MessageType.text;
          if (rawType == 'image') msgType = MessageType.image;
          if (rawType == 'file') msgType = MessageType.file;

          // ✅ Parse reactions nếu backend trả về, dạng { "👍": [1,2], "❤️": [3] }
          final Map<String, List<int>> parsedReactions = {};
          final rawReactions = m['reactions'];
          if (rawReactions is Map) {
            rawReactions.forEach((key, value) {
              if (value is List) {
                parsedReactions[key.toString()] =
                    value.map((e) => int.tryParse(e.toString()) ?? 0).toList();
              }
            });
          }

          return _Message(
            id: m['id'].toString(),
            senderId: senderId,
            senderName: m['sender_name'] ?? "Người dùng",
            senderAvatar: isOwn
                ? ''
                : widget.targetAvatar ??
                '${AppConfig.webDomain}/media/2025/10/default-avatar.png',
            content: m['message'] ?? '',
            time: (DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now().toUtc())
                .toUtc()
                .add(const Duration(hours: 7)),
            isOwn: isOwn,
            // ⭐️ THÊM
            type: msgType,
            fileUrl: m['file_url'],
            fileName: m['file_name'],
            reactions: parsedReactions,
          );
        }).toList();
        _scrollToBottom();
      }
    } catch (e) {
      print("❌ Load messages error: $e");
    } finally {
      setState(() {
        _loading = false; // ← tắt loading
      });
    }
  }


  Widget _buildLoadingList() {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(8),
      itemCount: 6,
      itemBuilder: (_, i) {
        final alignRight = i.isEven;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            mainAxisAlignment:
            alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              _LoadingBubble(width: 180 + (i % 3) * 20, height: 18),
            ],
          ),
        );
      },
    );
  }


  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            // AppBar
            AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              title: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserInfoPage(
                            userId: widget.userId,
                            targetUserId: widget.targetId,
                            username: widget.targetUser,
                            avatarUrl: widget.targetAvatar,
                          ),
                        ),
                      );
                    },
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: accentOrange,
                      backgroundImage: widget.targetAvatar != null
                          ? NetworkImage(widget.targetAvatar!)
                          : null,
                      child: widget.targetAvatar == null
                          ? Text(
                        widget.targetUser[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white),
                      )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.targetUser,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),

              // 👇 THÊM Ở ĐÂY
              actions: [
                IconButton(
                  icon: const Icon(Icons.call, color: Colors.white),
                  tooltip: "Gọi thoại",
                  onPressed: _callVoice,
                ),
                IconButton(
                  icon: const Icon(Icons.videocam, color: Colors.white),
                  tooltip: "Gọi video",
                  onPressed: _callVideo,
                ),
              ],
            ),

            // Typing indicator
            ValueListenableBuilder<String?>(
              valueListenable: typingUserNotifier,
              builder: (_, typingUser, __) {
                if (typingUser == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text(
                    "$typingUser đang gõ...",
                    style: TextStyle(
                      color: accentOrange,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                );
              },
            ),

            // Message list
            Expanded(
              child: _loading
                  ? _buildLoadingList()
                  : ValueListenableBuilder<List<_Message>>(
                valueListenable: messages,
                builder: (_, msgs, __) {
                  final list = msgs.reversed.toList();
                  return ListView.builder(
                    controller: scrollController,
                    reverse: true,
                    padding: const EdgeInsets.all(8),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _MessageBubblePhoenix(
                      key: ValueKey(list[i].id), // ⭐️ CỰC KỲ QUAN TRỌNG
                      msg: list[i],
                      primaryBlue: primaryBlue,
                      accentOrange: accentOrange,
                      currentUserId: widget.userId,
                      targetAvatar: widget.targetAvatar,
                      onDelete: (id) => deleteMessage(id),
                      onReact: (emoji) => _toggleReaction(list[i], emoji),
                    ),

                  );
                },
              ),
            ),


            // Input box
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [primaryBlue.withOpacity(0.8), accentOrange.withOpacity(0.8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: SafeArea(
                top: false,
                bottom: !_showEmojiPicker,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _showEmojiPicker
                            ? Icons.keyboard
                            : Icons.emoji_emotions_outlined,
                        color: Colors.white,
                      ),
                      tooltip: "Emoji",
                      onPressed: _toggleEmojiPicker,
                    ),
                    IconButton(
                      icon: const Icon(Icons.image, color: Colors.white),
                      onPressed: pickImage,
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file, color: Colors.white),
                      onPressed: pickFile,
                    ),
                    Expanded(
                      child: TextField(
                        controller: input,
                        focusNode: _inputFocusNode,
                        onTap: () {
                          if (_showEmojiPicker) {
                            setState(() => _showEmojiPicker = false);
                          }
                        },
                        onChanged: (_) => sendTyping(),
                        onSubmitted: (_) => sendMessage(),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: "Nhập tin nhắn...",
                          hintStyle: TextStyle(color: Colors.white70),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: sendMessage,
                    ),
                  ],
                ),
              ),
            ),

            // ✅ Bảng chọn emoji — chỉ hiện khi bấm icon 😊
            if (_showEmojiPicker)
              SizedBox(
                height: 250,
                child: EmojiPicker(
                  onEmojiSelected: _onEmojiSelected,
                  onBackspacePressed: _onEmojiBackspacePressed,
                  config: Config(
                    height: 250,
                    checkPlatformCompatibility: true,
                    emojiViewConfig: EmojiViewConfig(
                      columns: 7,
                      emojiSizeMax: 28,
                      backgroundColor: const Color(0xFF1E293B),
                      recentsLimit: 28,
                      noRecents: const Text(
                        'Chưa có emoji gần đây',
                        style: TextStyle(fontSize: 14, color: Colors.white54),
                        textAlign: TextAlign.center,
                      ),
                      loadingIndicator: const SizedBox.shrink(),
                    ),
                    skinToneConfig: const SkinToneConfig(
                      dialogBackgroundColor: Colors.white,
                      indicatorColor: Colors.grey,
                    ),
                    categoryViewConfig: CategoryViewConfig(
                      backgroundColor: const Color(0xFF1E293B),
                      indicatorColor: accentOrange,
                      iconColor: Colors.white70,
                      iconColorSelected: accentOrange,
                      backspaceColor: accentOrange,
                    ),
                    bottomActionBarConfig: const BottomActionBarConfig(
                      backgroundColor: Color(0xFF1E293B),
                      buttonIconColor: Colors.white70,
                    ),
                    searchViewConfig: const SearchViewConfig(
                      backgroundColor: Color(0xFF1E293B),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
enum MessageType {
  text,
  image,
  file,
}

// ---------------- Message model ----------------
class _Message {
  final String id;
  final String senderId;
  final String senderName;
  final String senderAvatar;
  final String content;
  final DateTime time;
  final bool isOwn;

  // ⭐️ THÊM
  final MessageType type;
  final String? fileUrl;
  final String? fileName;
  // ✅ emoji -> danh sách userId đã thả biểu cảm đó
  final Map<String, List<int>> reactions;

  _Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.senderAvatar,
    required this.content,
    required this.time,
    required this.isOwn,

    // ⭐️ THÊM
    this.type = MessageType.text,
    this.fileUrl,
    this.fileName,
    Map<String, List<int>>? reactions,
  }) : reactions = reactions ?? {};
}

// ---------------- Message Bubble giống Phoenix ----------------
class _MessageBubblePhoenix extends StatefulWidget {
  final _Message msg;
  final Color primaryBlue;
  final Color accentOrange;
  final int currentUserId;
  final String? targetAvatar;
  final void Function(String msgId)? onDelete; // callback xóa
  final void Function(String emoji)? onReact;  // callback thả biểu cảm

  const _MessageBubblePhoenix({
    super.key,
    required this.msg,
    required this.primaryBlue,
    required this.accentOrange,
    required this.currentUserId,
    this.targetAvatar,
    this.onDelete,
    this.onReact,
  });

  @override
  State<_MessageBubblePhoenix> createState() => _MessageBubblePhoenixState();
}

class _MessageBubblePhoenixState extends State<_MessageBubblePhoenix> {
  double opacity = 1.0;
  double scale = 1.0;

  Future<void> _animateDelete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                widget.primaryBlue.withOpacity(0.9),
                widget.accentOrange.withOpacity(0.9)
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Xác nhận xóa",
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                "Bạn có chắc muốn xóa tin nhắn này?",
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text("Hủy", style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text("Xóa", style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirm == true) {
      setState(() {
        scale = 0.7;
        opacity = 0.0;
      });
      await Future.delayed(const Duration(milliseconds: 250));
      widget.onDelete?.call(widget.msg.id);
    }
  }

  // ✅ Bottom sheet chọn biểu cảm + (nếu là tin của mình) nút xóa
  void _showMessageActions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: const BoxDecoration(
          color: Color(0xFF1E293B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: kQuickReactions.map((emoji) {
                return GestureDetector(
                  onTap: () {
                    Navigator.pop(sheetContext);
                    widget.onReact?.call(emoji);
                  },
                  child: Text(emoji, style: const TextStyle(fontSize: 30)),
                );
              }).toList(),
            ),
            if (widget.msg.isOwn) ...[
              const SizedBox(height: 8),
              const Divider(color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text("Xóa tin nhắn", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _animateDelete();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ✅ Dòng hiển thị các biểu cảm đã thả cho tin nhắn này
  Widget _buildReactionsRow() {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: widget.msg.reactions.entries.map((entry) {
        final emoji = entry.key;
        final userIds = entry.value;
        final reactedByMe = userIds.contains(widget.currentUserId);
        return GestureDetector(
          onTap: () => widget.onReact?.call(emoji),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: reactedByMe
                  ? Colors.white.withOpacity(0.35)
                  : Colors.black.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
              border: reactedByMe
                  ? Border.all(color: Colors.white, width: 1)
                  : null,
            ),
            child: Text(
              "$emoji ${userIds.length}",
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
        );
      }).toList(),
    );
  }


  String _formatTime(DateTime time) {
    final now = DateTime.now();
    if (time.day == now.day &&
        time.month == now.month &&
        time.year == now.year) {
      return DateFormat('HH:mm').format(time);
    } else if (time.year == now.year) {
      return DateFormat('dd/MM HH:mm').format(time);
    } else {
      return DateFormat('dd/MM/yyyy HH:mm').format(time);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOwn = widget.msg.isOwn;

    final noBubble =
        widget.msg.type == MessageType.image ||
            widget.msg.type == MessageType.file;

    // --- Build content widget ---
    Widget contentWidget;

    if (widget.msg.type == MessageType.image) {
      debugPrint("Message ID: ${widget.msg.id}, fileUrl: ${widget.msg.fileUrl}");
      debugPrint("Image fileUrl: ${widget.msg.fileUrl}");
      debugPrint("Image content length: ${widget.msg.content.length}");

      // Ảnh network
      if (widget.msg.fileUrl != null && widget.msg.fileUrl!.isNotEmpty) {
        contentWidget = GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  body: Center(
                    child: InteractiveViewer(
                      child: Image.network(
                        widget.msg.fileUrl!,
                        headers: {
                          'User-Agent': 'FlutterApp',
                        },
                        errorBuilder: (_, __, ___) => Container(
                          color: Colors.red,
                          child: const Icon(Icons.broken_image, color: Colors.white70),
                        ),
                      ),
                    ),

                  ),
                ),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              widget.msg.fileUrl!,
              width: 200,
              fit: BoxFit.cover,
              headers: {
                'User-Agent': 'FlutterApp', // thêm header nếu server block
              },
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Container(
                  width: 200,
                  height: 100,

                  child: const Center(child: CircularProgressIndicator()),
                );
              },
              errorBuilder: (_, __, ___) => Container(
                width: 200,
                height: 100,
                child: const Icon(Icons.broken_image, color: Colors.white70),
              ),
            ),
          ),
        );
      }
      // Ảnh Base64 local
      else if (widget.msg.content.isNotEmpty) {
        try {
          final bytes = base64Decode(widget.msg.content);
          contentWidget = GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    backgroundColor: Colors.black,
                    body: Center(
                      child: InteractiveViewer(
                        child: Image.memory(bytes),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                bytes,
                width: 200,
                height: 200,
                fit: BoxFit.cover,
              ),
            ),
          );
        } catch (e) {
          contentWidget = Container(
            width: 200,
            height: 200,
            color: Colors.grey,
            child: const Icon(Icons.broken_image, color: Colors.white70),
          );
        }
      }
      // fallback nếu không có ảnh
      else {
        contentWidget = Container(
          width: 200,
          height: 200,
          color: Colors.grey,
          child: const Icon(Icons.image, color: Colors.white70),
        );
      }
    }
    // FILE
    else if (widget.msg.type == MessageType.file) {
      debugPrint("📎 FILE UI: ${widget.msg.fileName} | ${widget.msg.fileUrl}");

      contentWidget = GestureDetector(
        onTap: () async {
          final url = widget.msg.fileUrl;
          if (url == null || url.isEmpty) return;

          final uri = Uri.parse(url);

          if (!await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          )) {
            debugPrint("❌ Không mở được file: $url");
          }
        },
        child: Container(
          constraints: const BoxConstraints(minWidth: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.msg.fileName ?? "File",
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // TEXT
    else {
      contentWidget = Text(
        widget.msg.content,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          height: 1.3,
        ),
      );
    }

    // --- Return chat bubble ---
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: GestureDetector(
        onLongPress: _showMessageActions,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Row(
              mainAxisAlignment:
              isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!isOwn)
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserInfoPage(
                            userId: widget.currentUserId,
                            targetUserId: int.tryParse(widget.msg.senderId) ?? 0,
                            username: widget.msg.senderName,
                            avatarUrl: widget.msg.senderAvatar,
                          ),
                        ),
                      );
                    },
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: widget.accentOrange,
                      backgroundImage: widget.msg.senderAvatar.isNotEmpty
                          ? NetworkImage(widget.msg.senderAvatar)
                          : null,
                      child: widget.msg.senderAvatar.isEmpty
                          ? Text(
                        widget.msg.senderName[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white),
                      )
                          : null,
                    ),
                  ),
                if (!isOwn) const SizedBox(width: 6),

                Flexible(
                  child: Column(
                    crossAxisAlignment:
                    isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: noBubble
                            ? EdgeInsets.zero
                            : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: noBubble
                            ? null
                            : BoxDecoration(
                          gradient: LinearGradient(
                            colors: isOwn
                                ? [widget.primaryBlue.withOpacity(0.9), widget.primaryBlue]
                                : [widget.accentOrange.withOpacity(0.9), widget.accentOrange],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(12),
                            topRight: const Radius.circular(12),
                            bottomLeft: Radius.circular(isOwn ? 12 : 0),
                            bottomRight: Radius.circular(isOwn ? 0 : 12),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment:
                          isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            contentWidget,
                            if (widget.msg.type != MessageType.image)
                              const SizedBox(height: 3),
                            Text(
                              _formatTime(widget.msg.time),
                              style: TextStyle(
                                fontSize: 10,
                                color: widget.msg.type == MessageType.image
                                    ? Colors.white
                                    : Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ✅ hiển thị ticker/biểu cảm nếu có
                      if (widget.msg.reactions.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _buildReactionsRow(),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

// ------------------- BUBBLE NHẤP NHÁY -------------------
class _LoadingBubble extends StatefulWidget {
  final double width;
  final double height;
  const _LoadingBubble({required this.width, required this.height, super.key});

  @override
  State<_LoadingBubble> createState() => _LoadingBubbleState();
}

class _LoadingBubbleState extends State<_LoadingBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacityAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    _opacityAnim = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacityAnim,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey.shade300.withOpacity(_opacityAnim.value),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

// =============================================================================
// INCOMING CALL BANNER — thông báo cuộc gọi đến, trượt từ mép trên xuống
// (kiểu iOS), thay cho AlertDialog cũ (che giữa màn hình, không có hiệu ứng).
// =============================================================================

class _IncomingCallBanner extends StatefulWidget {
  final String fromName;
  final String? avatarUrl;
  final String callType;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final void Function(AnimationController controller) onCreateController;

  const _IncomingCallBanner({
    required this.fromName,
    required this.avatarUrl,
    this.callType = "video",
    required this.onAccept,
    required this.onReject,
    required this.onCreateController,
  });

  @override
  State<_IncomingCallBanner> createState() => _IncomingCallBannerState();
}

class _IncomingCallBannerState extends State<_IncomingCallBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slide;
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    // Cho ChatPage giữ tham chiếu controller này để có thể gọi reverse()
    // khi người dùng bấm Nghe/Từ chối (animation trượt NGƯỢC lên trước khi
    // gỡ khỏi Overlay, thay vì biến mất đột ngột).
    widget.onCreateController(_controller);

    _controller.forward();

    // Tự ẩn popup sau 30s nếu không ai bấm gì — tránh banner treo vĩnh
    // viễn trên màn hình nếu người gọi đã tắt app/mất mạng mà không kịp
    // gửi được "call_end".
    _autoDismissTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) widget.onReject();
    });
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    // _controller được dispose bởi ChatPage._showIncomingCall (sau khi
    // .reverse() chạy xong), không dispose ở đây để tránh dispose 2 lần.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slide,
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: EdgeInsets.fromLTRB(10, topPadding + 6, 10, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xF21C1C1E), // xám đen mờ kiểu iOS
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                // Avatar người gọi
                CircleAvatar(
                  radius: 21,
                  backgroundColor: Colors.white24,
                  backgroundImage: (widget.avatarUrl != null &&
                      widget.avatarUrl!.isNotEmpty)
                      ? NetworkImage(widget.avatarUrl!)
                      : null,
                  child: (widget.avatarUrl == null || widget.avatarUrl!.isEmpty)
                      ? const Icon(Icons.person, color: Colors.white70, size: 22)
                      : null,
                ),
                const SizedBox(width: 12),

                // Tên + phụ đề
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
                              color: Colors.white70,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // Nút Từ chối (đỏ)
                _CallActionButton(
                  icon: Icons.call_end_rounded,
                  color: Colors.redAccent,
                  onTap: widget.onReject,
                ),
                const SizedBox(width: 8),

                // Nút Nghe (xanh)
                _CallActionButton(
                  icon: widget.callType == "voice"
                      ? Icons.call_rounded
                      : Icons.videocam_rounded,
                  color: Colors.greenAccent.shade700,
                  onTap: widget.onAccept,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 19),
      ),
    );
  }
}

// =============================================================================
// OUTGOING CALL SCREEN — màn hình "Đang gọi..." hiện cho NGƯỜI GỌI ngay sau
// khi bấm nút gọi video, để họ biết tín hiệu đã được gửi và đang chờ phản
// hồi (trước đây bấm gọi xong màn hình không đổi gì, không biết có gọi
// được không).
// =============================================================================

class _OutgoingCallScreen extends StatefulWidget {
  final String targetName;
  final String? targetAvatar;
  final String callType;
  final VoidCallback onCancel;

  const _OutgoingCallScreen({
    required this.targetName,
    required this.targetAvatar,
    this.callType = "video",
    required this.onCancel,
  });

  @override
  State<_OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<_OutgoingCallScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        widget.onCancel();
        return false;
      },
      child: Scaffold(
        // ✅ Nền gradient đồng bộ với theme app thay vì màu đen phẳng
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue, Colors.black.withOpacity(0.85), accentOrange.withOpacity(0.6)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // ✅ Dùng SingleChildScrollView + ConstrainedBox thay vì
                // Column cứng với Spacer — nếu nội dung cao hơn màn hình
                // (máy nhỏ), nó sẽ scroll được thay vì bị tràn/vỡ layout
                // (nguyên nhân gây dải cảnh báo đen-vàng lệch 1 bên).
                return SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const SizedBox(height: 32),
                          Text(
                            widget.callType == "voice"
                                ? "📞 Đang gọi thoại..."
                                : "📹 Đang gọi video...",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Expanded(child: SizedBox()),
                          ScaleTransition(
                            scale: _pulseAnimation,
                            child: Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white24, width: 2),
                              ),
                              padding: const EdgeInsets.all(6),
                              child: CircleAvatar(
                                radius: 54,
                                backgroundColor: Colors.white24,
                                backgroundImage: (widget.targetAvatar != null &&
                                    widget.targetAvatar!.isNotEmpty)
                                    ? NetworkImage(widget.targetAvatar!)
                                    : null,
                                child: (widget.targetAvatar == null ||
                                    widget.targetAvatar!.isEmpty)
                                    ? const Icon(Icons.person,
                                    color: Colors.white70, size: 46)
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              widget.targetName,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            "Đang chờ phản hồi...",
                            style: TextStyle(color: Colors.white54, fontSize: 13),
                          ),
                          const Expanded(child: SizedBox()),
                          GestureDetector(
                            onTap: widget.onCancel,
                            child: Container(
                              width: 62,
                              height: 62,
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.call_end_rounded,
                                  color: Colors.white, size: 28),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            "Hủy",
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}