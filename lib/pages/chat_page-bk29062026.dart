import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import 'user_info_page.dart'; // Trang profile người dùng nếu có
import 'video_call_page.dart';
import 'webrtc_signal_bus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';


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
    this.serverUrl = "wss://socket.spiritwebs.com/socket/websocket",
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




  bool _loading = true;
  bool _uploading = false;

  bool _isReconnecting = false;
  bool _isConnected = false;




  Timer? _typingTimer;
  Timer? _heartbeatTimer;
  int refCounter = 1;
  bool _hasJoinedRoom = false;
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  @override
  void initState() {
    super.initState();
    isChatPageOpen = true;
    _loadOldMessages();
    connectSocket();
  }

  @override
  void dispose() {
    isChatPageOpen = false;
    _typingTimer?.cancel();
    _heartbeatTimer?.cancel();
    //channel.sink.close();
    scrollController.dispose();
    input.dispose();
    messages.dispose();
    typingUserNotifier.dispose();
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
      },
      "ref": "${refCounter++}"
    }));
    // 👇 THÊM DÒNG NÀY
   // _openCall(true);
  }

  void _showIncomingCall(String fromName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text("📹 Video call"),
        content: Text("$fromName đang gọi cho bạn"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Từ chối"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              channel.sink.add(jsonEncode({
                "topic": getTopic(),
                "event": "call_accept",
                "payload": {},
                "ref": "${refCounter++}"
              }));
              _openCall(false);
            },
            child: const Text("Nghe"),
          ),
        ],
      ),
    );
  }
  void _openCall(bool isCaller) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoCallPage(
          socket: channel,
          topic: getTopic(),
          isCaller: isCaller,
        ),
      ),
    );
  }

  /*void _reconnectSocket() async {
    await Future.delayed(Duration(seconds: 2));
    connectSocket(); // hàm mở WebSocket + join topic
  }*/
  void _reconnectSocket() async {
    if (_isReconnecting) return;

    _isReconnecting = true;

    await Future.delayed(const Duration(seconds: 2));

    if (mounted) {
      connectSocket();
    }

    _isReconnecting = false;
  }

  /*void connectSocket() {
    channel = WebSocketChannel.connect(Uri.parse(widget.serverUrl));
    print("🚀 CONNECT → ${widget.serverUrl}");

    channel.stream.listen(
          (data) {
        _onData(data);
      },
      onDone: () {
        print("🔌 SOCKET CLOSED → reconnecting...");
        _reconnectSocket();
      },
      onError: (err) {
        print("❌ SOCKET ERROR: $err → reconnecting...");
        _reconnectSocket();
      },
    );


    Future.delayed(const Duration(milliseconds: 300), () {
      _joinRoom();
      _initUser();
      _startHeartbeat();
    });
  }*/
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
      _showIncomingCall(payload["from_name"]);
    }

    if (event == "call_accept") {
      _openCall(true);
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
                  icon: const Icon(Icons.videocam, color: Colors.white),
                  onPressed: _callVideo, // hàm đã hướng dẫn
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
                child: Row(
                  children: [
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
  });
}

// ---------------- Message Bubble giống Phoenix ----------------
class _MessageBubblePhoenix extends StatefulWidget {
  final _Message msg;
  final Color primaryBlue;
  final Color accentOrange;
  final int currentUserId;
  final String? targetAvatar;
  final void Function(String msgId)? onDelete; // callback xóa

  const _MessageBubblePhoenix({
    super.key,
    required this.msg,
    required this.primaryBlue,
    required this.accentOrange,
    required this.currentUserId,
    this.targetAvatar,
    this.onDelete,
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
        onLongPress: isOwn ? _animateDelete : null,
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
                  child: Container(
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
