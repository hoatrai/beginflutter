import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'user_info_page.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';
import '../app_globals.dart'; // ✅ currentUserAvatar, isGroupChatPageOpen, currentGroupChatId

class GroupChatPage extends StatefulWidget {
  final int userId;
  final String username;
  final String? userAvatar; // giữ lại để tương thích cũ, KHÔNG dùng để gửi socket
  final int groupId;
  final String groupName;
  final String? groupAvatar;
  final String serverUrl;

  const GroupChatPage({
    super.key,
    required this.userId,
    required this.username,
    this.userAvatar,
    required this.groupId,
    required this.groupName,
    this.groupAvatar,
    this.serverUrl = AppConfig.websocketUrl,
  });

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

enum MessageType { text, image, file }

// ✅ Danh sách biểu cảm nhanh dùng cho ticker/reaction
const List<String> kQuickReactions = ['👍', '❤️', '😆', '😮', '😢', '😡'];

class _GroupChatPageState extends State<GroupChatPage> {
  WebSocketChannel? channel;
  final ValueNotifier<List<_Message>> messages = ValueNotifier([]);
  final ValueNotifier<String?> typingUserNotifier = ValueNotifier(null);
  final ValueNotifier<List<_Participant>> participants = ValueNotifier([]);
  final TextEditingController input = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();

  // ---------------- EMOJI PICKER ----------------
  bool _showEmojiPicker = false;
  final FocusNode _inputFocusNode = FocusNode();

  Timer? _typingTimer;
  Timer? _heartbeatTimer;
  Timer? _typingStopTimer;
  int refCounter = 1;
  bool _hasJoinedRoom = false;
  bool _initialized = false;
  bool _loading = true;
  bool _uploading = false;

  bool _isConnected = false;
  bool _isReconnecting = false;

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  final Map<int, String> _userAvatars = {};
  final List<String> _pendingTextQueue = [];

  @override
  void initState() {
    super.initState();
    isGroupChatPageOpen = true;          // ✅
    currentGroupChatId = widget.groupId; // ✅
    _loadOldMessages();
    connectSocket();
  }

  @override
  void dispose() {
    isGroupChatPageOpen = false;         // ✅
    currentGroupChatId = null;           // ✅
    _typingTimer?.cancel();
    _heartbeatTimer?.cancel();
    _typingStopTimer?.cancel();
    channel?.sink.close();
    scrollController.dispose();
    input.dispose();
    messages.dispose();
    typingUserNotifier.dispose();
    participants.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  String getTopic() => "group_chat:${widget.groupId}";

  // ---------------- CONNECT / RECONNECT ----------------
  void connectSocket() {
    try {
      channel = WebSocketChannel.connect(Uri.parse(widget.serverUrl));
      _isConnected = true;
      _hasJoinedRoom = false;
      _initialized = false;

      channel!.stream.listen(
        _onData,
        onError: (e) {
          debugPrint("❌ SOCKET ERROR: $e");
          _isConnected = false;
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint("🔌 SOCKET CLOSED");
          _isConnected = false;
          _scheduleReconnect();
        },
      );

      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        _joinRoom();
        _initUser();
        _startHeartbeat();
      });
    } catch (e) {
      debugPrint("❌ CONNECT FAIL: $e");
      _isConnected = false;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isReconnecting || !mounted) return;
    _isReconnecting = true;
    _heartbeatTimer?.cancel();

    Future.delayed(const Duration(seconds: 2), () {
      _isReconnecting = false;
      if (mounted) connectSocket();
    });
  }

  void _joinRoom() {
    if (_hasJoinedRoom) return;
    _send("phx_join", {});
    _hasJoinedRoom = true;
  }

  void _initUser() {
    _send("init_user", {
      "user_id": widget.userId,
      "username": widget.username,
      "avatar_url": currentUserAvatar,
    });
    _userAvatars[widget.userId] = currentUserAvatar;
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (channel == null) return;
      channel!.sink.add(jsonEncode({
        "topic": "phoenix",
        "event": "heartbeat",
        "payload": {},
        "ref": "${refCounter++}"
      }));
    });
  }

  void _send(String event, Map<String, dynamic> payload) {
    if (channel == null) return;
    channel!.sink.add(jsonEncode({
      "topic": getTopic(),
      "event": event,
      "payload": payload,
      "ref": "${refCounter++}"
    }));
  }

  // ---------------- LOAD OLD MESSAGES ----------------
  Future<void> _loadOldMessages() async {
    if (mounted) setState(() => _loading = true);
    try {
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/get-group-messages"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"group_id": widget.groupId}),
      );

      if (res.statusCode == 200) {
        final List data = jsonDecode(res.body)['messages'] ?? [];
        data.sort((a, b) {
          final aTime = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.now();
          final bTime = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.now();
          return aTime.compareTo(bTime);
        });

        final loaded = data.map<_Message>((m) {
          final senderId = int.tryParse(m['sender_id'].toString()) ?? 0;

          if (m['avatar_url'] != null && m['avatar_url'].toString().isNotEmpty) {
            _userAvatars[senderId] = m['avatar_url'];
          }

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
            senderName: m['nickname'] ?? 'Người lạ',
            content: m['message'] ?? '',
            time: (DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now())
                .add(const Duration(hours: 7)),
            isOwn: senderId == widget.userId,
            avatarUrl: m['avatar_url'],
            type: msgType,
            fileUrl: m['file_url'],
            fileName: m['file_name'],
            reactions: parsedReactions,
          );
        }).toList();

        _mergeMessages(loaded);

        final uniqueUsers = <int, _Participant>{};
        for (var m in messages.value) {
          if (!uniqueUsers.containsKey(m.senderId)) {
            uniqueUsers[m.senderId] = _Participant(
              userId: m.senderId,
              username: m.senderName,
              avatarUrl: _userAvatars[m.senderId] ?? m.avatarUrl,
            );
          }
        }
        participants.value = uniqueUsers.values.toList();
      }
    } catch (e) {
      debugPrint("❌ Load group messages error: $e");
    } finally {
      if (mounted) setState(() => _loading = false);
      Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
    }
  }

  void _mergeMessages(List<_Message> incoming) {
    final map = <String, _Message>{};
    for (final m in messages.value) {
      map[m.id] = m;
    }
    for (final m in incoming) {
      map[m.id] = m;
    }
    final merged = map.values.toList()..sort((a, b) => a.time.compareTo(b.time));
    messages.value = merged;
  }

  // ---------------- SEND TEXT MESSAGE ----------------
  void sendMessage() {
    final text = input.text.trim();
    if (text.isEmpty) return;
    input.clear();
    _stopTyping();

    if (!_initialized) {
      debugPrint("⏳ Socket chưa init xong, sẽ gửi lại khi sẵn sàng");
      _pendingTextQueue.add(text);
      return;
    }

    _sendTextNow(text);
  }

  Future<void> _sendTextNow(String text) async {
    final tempId = "local_${DateTime.now().millisecondsSinceEpoch}";
    final tempMsg = _Message(
      id: tempId,
      senderId: widget.userId,
      senderName: widget.username,
      content: text,
      time: DateTime.now(),
      isOwn: true,
      avatarUrl: currentUserAvatar,
    );
    messages.value = [...messages.value, tempMsg];
    _scrollToBottom();

    try {
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/send-group-message"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "group_id": widget.groupId,
          "sender_id": widget.userId,
          "sender_name": widget.username,
          "message": text,
          "avatar_url": currentUserAvatar,
        }),
      );
      final data = jsonDecode(res.body);
      final realId = data['data']['id'].toString();

      final idx = messages.value.indexWhere((m) => m.id == tempId);
      if (idx != -1) messages.value[idx].id = realId;

      _send("send_message", {
        "id": realId,
        "content": text,
        "sender_id": widget.userId,
        "sender_name": widget.username,
        "avatar_url": currentUserAvatar,
      });
    } catch (e) {
      debugPrint("❌ Save message error: $e");
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

  // ---------------- PICK & SEND IMAGE ----------------
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

    if (ok != true) return;

    final tempId = "local_${DateTime.now().millisecondsSinceEpoch}";
    final tempMsg = _Message(
      id: tempId,
      senderId: widget.userId,
      senderName: widget.username,
      content: base64Encode(bytes),
      time: DateTime.now(),
      isOwn: true,
      avatarUrl: currentUserAvatar,
      type: MessageType.image,
      fileName: file.name,
    );

    messages.value = [...messages.value, tempMsg];
    _scrollToBottom();

    uploadFile(bytes, file.name, MessageType.image, tempId: tempId);
  }

  // ---------------- PICK & SEND FILE ----------------
  Future<void> pickFile() async {
    if (_showEmojiPicker) setState(() => _showEmojiPicker = false);

    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return;

    final file = result.files.first;
    if (file.bytes == null) return;

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

  // ---------------- UPLOAD (chung cho ảnh + file) ----------------
  Future<void> uploadFile(
      Uint8List bytes,
      String filename,
      MessageType type, {
        String? tempId,
      }) async {
    if (_uploading) return;

    try {
      setState(() => _uploading = true);

      tempId ??= "local_${DateTime.now().millisecondsSinceEpoch}";

      if (!messages.value.any((m) => m.id == tempId)) {
        final tempMsg = _Message(
          id: tempId,
          senderId: widget.userId,
          senderName: widget.username,
          content: '',
          time: DateTime.now(),
          isOwn: true,
          avatarUrl: currentUserAvatar,
          type: type,
          fileName: filename,
        );
        messages.value = [...messages.value, tempMsg];
        _scrollToBottom();
      }

      final request = http.MultipartRequest(
        "POST",
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/upload"),
      );
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
      request.fields['sender_id'] = widget.userId.toString();
      request.fields['sender_name'] = widget.username;
      request.fields['avatar_url'] = currentUserAvatar;
      request.fields['group_id'] = widget.groupId.toString();
      request.fields['message'] = '';
      // ✅ gửi thẳng type đã biết chắc từ client, khỏi cần server đoán mime
      request.fields['type'] = type == MessageType.image ? 'image' : 'file';

      final res = await request.send();
      final body = await res.stream.bytesToString();
      final data = jsonDecode(body);

      if (data['success'] != true || data['url'] == null) {
        throw Exception("Upload failed: ${data['message'] ?? 'Unknown error'}");
      }

      final url = data['url'];
      final filenameFromServer = data['filename'] ?? filename;
      final realId = data['id']?.toString() ?? tempId;

      final idx = messages.value.indexWhere((m) => m.id == tempId);
      if (idx != -1) {
        final old = messages.value[idx];
        messages.value[idx] = _Message(
          id: realId,
          senderId: old.senderId,
          senderName: old.senderName,
          content: old.content,
          time: old.time,
          isOwn: true,
          avatarUrl: old.avatarUrl,
          type: old.type,
          fileUrl: url,
          fileName: filenameFromServer,
          reactions: old.reactions,
        );
        messages.notifyListeners();
      }

      _send("send_message", {
        "id": realId,
        "type": type == MessageType.image ? "image" : "file",
        "content": "",
        "file_name": filenameFromServer,
        "file_url": url,
        "sender_id": widget.userId,
        "sender_name": widget.username,
        "avatar_url": currentUserAvatar,
      });
    } catch (e) {
      debugPrint("❌ Upload error: $e");
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ---------------- DELETE MESSAGE ----------------
  Future<void> _deleteMessage(_Message msg) async {
    try {
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/delete-group-message"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"message_id": msg.id}),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true) {
          _send("delete_message", {"message_id": msg.id});
        }
      }
    } catch (e) {
      debugPrint("❌ Delete message error: $e");
    }
  }

  // ---------------- REACTIONS (ticker biểu cảm) ----------------
  Future<void> _toggleReaction(_Message msg, String emoji) async {
    final uid = widget.userId;
    final current = List<int>.from(msg.reactions[emoji] ?? []);
    final alreadyReacted = current.contains(uid);

    // ✅ Cập nhật UI ngay (optimistic update), không chờ mạng
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
      // ✅ Lưu DB trước (giống pattern send-group-message)
      await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/$endpoint"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "message_id": msg.id,
          "user_id": uid,
          "emoji": emoji,
          "message_type": "group",
        }),
      );

      // ✅ Rồi mới báo realtime cho những người khác trong nhóm
      _send(alreadyReacted ? "remove_reaction" : "add_reaction", {
        "message_id": msg.id,
        "emoji": emoji,
        "user_id": uid,
        "username": widget.username,
      });
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

  void _showMessageActions(_Message msg) {
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
                    unawaited(_toggleReaction(msg, emoji));
                  },
                  child: Text(emoji, style: const TextStyle(fontSize: 30)),
                );
              }).toList(),
            ),
            if (msg.isOwn) ...[
              const SizedBox(height: 8),
              const Divider(color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text("Xóa tin nhắn", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _deleteMessage(msg);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- TYPING ----------------
  void sendTyping() {
    _typingTimer?.cancel();
    _send("typing", {"username": widget.username});
    _typingTimer = Timer(const Duration(milliseconds: 800), _stopTyping);
  }

  void _stopTyping() {
    _send("stop_typing", {});
  }

  // ---------------- SOCKET EVENT HANDLER ----------------
  void _onData(dynamic data) {
    if (!mounted) return;

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(data);
    } catch (e) {
      debugPrint("💥 JSON ERROR: $e");
      return;
    }

    final event = decoded["event"];
    final payload = decoded["payload"];

    if (event == "phx_reply") {
      final status = payload?["status"];
      final response = payload?["response"];
      if (status == "ok" && response?["message"] == "user_initialized") {
        _initialized = true;
        if (_pendingTextQueue.isNotEmpty) {
          final queued = List<String>.from(_pendingTextQueue);
          _pendingTextQueue.clear();
          for (final text in queued) {
            _sendTextNow(text);
          }
        }
      } else if (status == "error") {
        debugPrint("⚠️ phx_reply lỗi: ${response?["reason"]}");
        if (response?["reason"] == "not_initialized") {
          _initUser();
        }
      }
      return;
    }

    if (event == "new_message") {
      final senderId = int.tryParse(payload["sender_id"].toString()) ?? 0;
      final avatar = payload["avatar_url"];
      if (avatar != null && avatar.toString().isNotEmpty) {
        _userAvatars[senderId] = avatar.toString();
      }

      if (senderId != widget.userId) {
        final rawType = payload["type"] ?? "text";
        MessageType msgType = MessageType.text;
        if (rawType == "image") msgType = MessageType.image;
        if (rawType == "file") msgType = MessageType.file;

        final m = _Message(
          id: payload["id"]?.toString() ?? "local_${DateTime.now().millisecondsSinceEpoch}",
          senderId: senderId,
          senderName: payload["sender_name"] ?? "Người dùng",
          content: payload["content"] ?? '',
          time: (DateTime.tryParse(payload["created_at"] ?? '') ?? DateTime.now()).toLocal(),
          isOwn: false,
          avatarUrl: _userAvatars[senderId] ?? avatar,
          type: msgType,
          fileUrl: payload["file_url"],
          fileName: payload["file_name"],
        );

        if (!messages.value.any((msg) => msg.id == m.id)) {
          messages.value = [...messages.value, m];
          _scrollToBottom();
        }

        if (!participants.value.any((p) => p.userId == m.senderId)) {
          participants.value = [
            ...participants.value,
            _Participant(userId: m.senderId, username: m.senderName, avatarUrl: m.avatarUrl)
          ];
        }
      }
      return;
    }

    // ✅ Có người thả biểu cảm cho 1 tin nhắn
    if (event == "reaction_added") {
      final messageId = payload["message_id"]?.toString();
      final emoji = payload["emoji"]?.toString();
      final userId = int.tryParse(payload["user_id"].toString()) ?? 0;
      if (messageId == null || emoji == null) return;

      final idx = messages.value.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        final list = List<int>.from(messages.value[idx].reactions[emoji] ?? []);
        if (!list.contains(userId)) {
          list.add(userId);
          messages.value[idx].reactions[emoji] = list;
          messages.notifyListeners();
        }
      }
      return;
    }

    // ✅ Có người bỏ biểu cảm khỏi 1 tin nhắn
    if (event == "reaction_removed") {
      final messageId = payload["message_id"]?.toString();
      final emoji = payload["emoji"]?.toString();
      final userId = int.tryParse(payload["user_id"].toString()) ?? 0;
      if (messageId == null || emoji == null) return;

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
      return;
    }

    if (event == "typing") {
      typingUserNotifier.value = payload["username"];
      return;
    }
    if (event == "stop_typing") {
      typingUserNotifier.value = null;
      return;
    }

    if (event == "user_online") {
      final onlineUserId = int.tryParse(payload["user_id"].toString()) ?? 0;
      final username = payload["username"] ?? "Người dùng";
      final avatar = payload["avatar_url"];
      if (avatar != null && avatar.toString().isNotEmpty) {
        _userAvatars[onlineUserId] = avatar.toString();
      }

      if (!participants.value.any((p) => p.userId == onlineUserId)) {
        participants.value = [
          ...participants.value,
          _Participant(userId: onlineUserId, username: username, avatarUrl: avatar)
        ];
      }
      return;
    }

    if (event == "user_joined") {
      final joinedUserId = int.tryParse(payload["user_id"].toString()) ?? 0;
      final username = payload["username"] ?? "Người dùng";
      final avatar = payload["avatar_url"];
      if (avatar != null && avatar.toString().isNotEmpty) {
        _userAvatars[joinedUserId] = avatar.toString();
      }

      final messageText = joinedUserId == widget.userId
          ? "🎉 $username Bạn đã tham gia nhóm"
          : "👤 $username đã tham gia nhóm";

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(messageText), duration: const Duration(seconds: 2)),
        );
      }

      messages.value = [
        ...messages.value,
        _Message(
          id: "system_${DateTime.now().millisecondsSinceEpoch}",
          senderId: 0,
          senderName: "Hệ thống",
          content: messageText,
          time: DateTime.now(),
          isOwn: false,
          avatarUrl: null,
        )
      ];

      _scrollToBottom();

      if (!participants.value.any((p) => p.userId == joinedUserId)) {
        participants.value = [
          ...participants.value,
          _Participant(userId: joinedUserId, username: username, avatarUrl: avatar)
        ];
      }
      return;
    }

    if (event == "message_deleted") {
      final deletedId = payload["message_id"].toString();
      messages.value = messages.value.where((m) => m.id != deletedId).toList();
      return;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(110),
        child: SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.groupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (!_isConnected)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(Icons.cloud_off, color: Colors.white70, size: 18),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (participants.value.isNotEmpty)
                  SizedBox(
                    height: 36,
                    child: ValueListenableBuilder<List<_Participant>>(
                      valueListenable: participants,
                      builder: (_, list, __) => ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final p = list[i];
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.white24,
                                backgroundImage: (p.avatarUrl != null && p.avatarUrl!.isNotEmpty)
                                    ? NetworkImage(p.avatarUrl!)
                                    : null,
                                child: (p.avatarUrl == null || p.avatarUrl!.isEmpty)
                                    ? Text(
                                  p.username.isNotEmpty
                                      ? p.username[0].toUpperCase()
                                      : "-",
                                  style:
                                  const TextStyle(color: Colors.white, fontSize: 12),
                                )
                                    : null,
                              ),
                              const SizedBox(height: 2),
                              Flexible(
                                child: Text(
                                  p.username,
                                  style: const TextStyle(fontSize: 10, color: Colors.white70),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
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
            ValueListenableBuilder<String?>(
              valueListenable: typingUserNotifier,
              builder: (_, typingUser, __) => typingUser == null
                  ? const SizedBox.shrink()
                  : Padding(
                padding: const EdgeInsets.all(6),
                child: Text("$typingUser đang gõ...",
                    style: TextStyle(
                        fontSize: 12,
                        color: accentOrange,
                        fontStyle: FontStyle.italic)),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: _loading
                    ? _buildLoadingList()
                    : ValueListenableBuilder<List<_Message>>(
                  valueListenable: messages,
                  builder: (_, msgs, __) {
                    final list = msgs;
                    return ListView.builder(
                      key: const ValueKey("msgList"),
                      controller: scrollController,
                      reverse: false,
                      padding: const EdgeInsets.all(8),
                      itemCount: list.length,
                      itemBuilder: (_, i) => GestureDetector(
                        onLongPress: () => _showMessageActions(list[i]),
                        child: _MessageBubble(
                          list[i],
                          primaryBlue: primaryBlue,
                          accentOrange: accentOrange,
                          currentUserId: widget.userId,
                          userAvatars: _userAvatars,
                          onReact: (emoji) => _toggleReaction(list[i], emoji),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            _buildInputBox(),
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

  Widget _buildLoadingList() {
    return shimmer.Shimmer.fromColors(
      baseColor: Colors.white.withOpacity(0.08),
      highlightColor: Colors.white.withOpacity(0.45),
      period: const Duration(milliseconds: 1100),
      child: ListView.builder(
        itemCount: 8,
        padding: const EdgeInsets.all(12),
        itemBuilder: (_, i) {
          final isOwn = i % 2 == 0;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!isOwn) _buildSkeletonAvatar(),
                const SizedBox(width: 6),
                _buildSkeletonBubble(isOwn),
                if (isOwn) const SizedBox(width: 6),
                if (isOwn) _buildSkeletonAvatar(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSkeletonAvatar() {
    return Container(
      width: 32,
      height: 32,
      decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
    );
  }

  Widget _buildSkeletonBubble(bool isOwn) {
    return Container(
      height: 18 + (isOwn ? 0 : 6),
      width: isOwn ? 150 : 120,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
    );
  }

  Widget _buildInputBox() => Container(
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
              _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions_outlined,
              color: Colors.white,
            ),
            tooltip: "Emoji",
            onPressed: _toggleEmojiPicker,
          ),
          IconButton(
            icon: const Icon(Icons.image, color: Colors.white),
            onPressed: _uploading ? null : pickImage,
          ),
          IconButton(
            icon: const Icon(Icons.attach_file, color: Colors.white),
            onPressed: _uploading ? null : pickFile,
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
              decoration: const InputDecoration(
                hintText: "Nhập tin nhắn...",
                hintStyle: TextStyle(color: Colors.white70),
                border: InputBorder.none,
              ),
            ),
          ),
          if (_uploading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.send, color: Colors.white),
              onPressed: sendMessage,
            )
        ],
      ),
    ),
  );
}

// ---------------- MESSAGE ----------------
class _Message {
  String id;
  final int senderId;
  final String senderName;
  final String content;
  final DateTime time;
  final bool isOwn;
  final String? avatarUrl;
  final MessageType type;
  final String? fileUrl;
  final String? fileName;
  // ✅ emoji -> danh sách userId đã thả biểu cảm đó
  Map<String, List<int>> reactions;

  _Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.time,
    required this.isOwn,
    this.avatarUrl,
    this.type = MessageType.text,
    this.fileUrl,
    this.fileName,
    Map<String, List<int>>? reactions,
  }) : reactions = reactions ?? {};
}

// ---------------- PARTICIPANT ----------------
class _Participant {
  final int userId;
  final String username;
  final String? avatarUrl;

  _Participant({required this.userId, required this.username, this.avatarUrl});
}

// ---------------- MESSAGE BUBBLE ----------------
class _MessageBubble extends StatelessWidget {
  final _Message msg;
  final Color primaryBlue;
  final Color accentOrange;
  final int currentUserId;
  final Map<int, String> userAvatars;
  final void Function(String emoji) onReact;

  const _MessageBubble(
      this.msg, {
        required this.primaryBlue,
        required this.accentOrange,
        required this.currentUserId,
        required this.userAvatars,
        required this.onReact,
        super.key,
      });

  static final List<Color> _userColors = [
    Colors.blue,
    Colors.orange,
    Colors.green,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.indigo,
    Colors.brown,
    Colors.cyan,
    Colors.amber,
  ];

  Color _getUserColor(int userId) {
    return _userColors[userId % _userColors.length];
  }

  String _formatMessageTime(DateTime time) {
    final now = DateTime.now();
    if (time.year == now.year && time.month == now.month && time.day == now.day) {
      return DateFormat.Hm().format(time);
    } else {
      return DateFormat('dd/MM/yyyy HH:mm').format(time);
    }
  }

  Widget _buildContent(BuildContext context) {
    if (msg.type == MessageType.image) {
      // Ảnh network
      if (msg.fileUrl != null && msg.fileUrl!.isNotEmpty) {
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  body: Center(
                    child: InteractiveViewer(
                      child: Image.network(
                        msg.fileUrl!,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image,
                          color: Colors.white70,
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
              msg.fileUrl!,
              width: 200,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return const SizedBox(
                  width: 200,
                  height: 100,
                  child: Center(child: CircularProgressIndicator()),
                );
              },
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 200,
                height: 100,
                child: Icon(Icons.broken_image, color: Colors.white70),
              ),
            ),
          ),
        );
      }
      // Ảnh base64 local (đang upload)
      if (msg.content.isNotEmpty) {
        try {
          final bytes = base64Decode(msg.content);
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(bytes, width: 200, height: 200, fit: BoxFit.cover),
          );
        } catch (_) {
          return const SizedBox(
            width: 200,
            height: 200,
            child: Icon(Icons.broken_image, color: Colors.white70),
          );
        }
      }
      return const SizedBox(
        width: 200,
        height: 200,
        child: Icon(Icons.image, color: Colors.white70),
      );
    }

    if (msg.type == MessageType.file) {
      return GestureDetector(
        onTap: () async {
          final url = msg.fileUrl;
          if (url == null || url.isEmpty) return;
          final uri = Uri.parse(url);
          if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
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
                  msg.fileName ?? "File",
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Text(msg.content, style: const TextStyle(color: Colors.white));
  }

  // ✅ Dòng hiển thị các biểu cảm đã thả cho tin nhắn này
  Widget _buildReactionsRow() {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: msg.reactions.entries.map((entry) {
        final emoji = entry.key;
        final userIds = entry.value;
        final reactedByMe = userIds.contains(currentUserId);
        return GestureDetector(
          onTap: () => onReact(emoji),
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

  @override
  Widget build(BuildContext context) {
    final isOwn = msg.isOwn;
    final Color bubbleColor = isOwn ? primaryBlue : _getUserColor(msg.senderId);
    final avatarUrl = userAvatars[msg.senderId] ?? msg.avatarUrl;
    final noBubble = msg.type == MessageType.image;

    Widget avatar = GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UserInfoPage(
              userId: currentUserId,
              username: msg.senderName,
              avatarUrl: avatarUrl ?? '',
              targetUserId: msg.senderId,
            ),
          ),
        );
      },
      child: CircleAvatar(
        radius: 16,
        backgroundColor: Colors.white24,
        backgroundImage:
        (avatarUrl != null && avatarUrl.isNotEmpty) ? NetworkImage(avatarUrl) : null,
        child: (avatarUrl == null || avatarUrl.isEmpty)
            ? Text(
          msg.senderName.isNotEmpty ? msg.senderName[0].toUpperCase() : "-",
          style: const TextStyle(color: Colors.white, fontSize: 12),
        )
            : null,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isOwn) avatar,
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isOwn)
                  Text(msg.senderName, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Container(
                  padding: noBubble
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: noBubble
                      ? null
                      : BoxDecoration(
                    color: bubbleColor.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _buildContent(context),
                ),
                // ✅ hiển thị ticker/biểu cảm nếu có
                if (msg.reactions.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _buildReactionsRow(),
                ],
                Text(_formatMessageTime(msg.time),
                    style: const TextStyle(color: Colors.white54, fontSize: 10)),
              ],
            ),
          ),
          if (isOwn) const SizedBox(width: 6),
          if (isOwn) avatar,
        ],
      ),
    );
  }
}