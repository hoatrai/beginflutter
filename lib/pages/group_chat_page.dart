import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'user_info_page.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';

class GroupChatPage extends StatefulWidget {
  final int userId;
  final String username;
  final String? userAvatar; // ⭐ avatar của CHÍNH user hiện tại (khác groupAvatar)
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

class _GroupChatPageState extends State<GroupChatPage> {
  WebSocketChannel? channel;
  final ValueNotifier<List<_Message>> messages = ValueNotifier([]);
  final ValueNotifier<String?> typingUserNotifier = ValueNotifier(null);
  final ValueNotifier<List<_Participant>> participants = ValueNotifier([]);
  final TextEditingController input = TextEditingController();
  final ScrollController scrollController = ScrollController();

  Timer? _typingTimer;
  Timer? _heartbeatTimer;
  Timer? _typingStopTimer;
  int refCounter = 1;
  bool _hasJoinedRoom = false;
  bool _initialized = false; // server đã xác nhận init_user thành công
  bool _loading = true;

  bool _isConnected = false;
  bool _isReconnecting = false;

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  // ---------------- Map lưu avatar tất cả user ----------------
  final Map<int, String> _userAvatars = {};

  // Tin nhắn đang chờ gửi lại nếu socket chưa init xong khi user bấm gửi
  final List<String> _pendingTextQueue = [];

  @override
  void initState() {
    super.initState();
    _loadOldMessages();
    connectSocket();
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _heartbeatTimer?.cancel();
    _typingStopTimer?.cancel();
    channel?.sink.close();
    scrollController.dispose();
    input.dispose();
    messages.dispose();
    typingUserNotifier.dispose();
    participants.dispose();
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
      "avatar_url": widget.userAvatar ?? '', // ⭐ avatar của user, KHÔNG dùng groupAvatar
    });
    _userAvatars[widget.userId] = widget.userAvatar ?? '';
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

          return _Message(
            id: m['id'].toString(),
            senderId: senderId,
            senderName: m['nickname'] ?? 'Người lạ',
            content: m['message'] ?? '',
            time: (DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now())
                .add(const Duration(hours: 7)),
            isOwn: senderId == widget.userId,
            avatarUrl: m['avatar_url'],
          );
        }).toList();

        // ⭐ merge thay vì gán đè, tránh mất tin nhắn realtime nhận được
        // trong lúc REST API đang load (race condition)
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

  /// Gộp danh sách tin nhắn mới vào danh sách hiện tại theo `id`, giữ thứ
  /// tự thời gian, không ghi đè những tin đã nhận qua socket trong lúc
  /// đang chờ REST API trả về.
  void _mergeMessages(List<_Message> incoming) {
    final map = <String, _Message>{};
    for (final m in messages.value) {
      map[m.id] = m;
    }
    for (final m in incoming) {
      map[m.id] = m;
    }
    final merged = map.values.toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    messages.value = merged;
  }

  // ---------------- SEND MESSAGE ----------------
  void sendMessage() {
    final text = input.text.trim();
    if (text.isEmpty) return;
    input.clear();
    _stopTyping();

    if (!_initialized) {
      // socket chưa init xong (vừa mở app / vừa reconnect) — chờ rồi gửi lại
      debugPrint("⏳ Socket chưa init xong, sẽ gửi lại khi sẵn sàng");
      _pendingTextQueue.add(text);
      return;
    }

    _sendTextNow(text);
  }

  void _sendTextNow(String text) {
    final msg = _Message(
      id: "local_${DateTime.now().millisecondsSinceEpoch}",
      senderId: widget.userId,
      senderName: widget.username,
      content: text,
      time: DateTime.now(),
      isOwn: true,
      avatarUrl: widget.userAvatar,
    );

    messages.value = [...messages.value, msg];
    _scrollToBottom();

    _send("send_message", {
      "content": text,
      "sender_id": widget.userId,
      "sender_name": widget.username,
      "avatar_url": widget.userAvatar,
    });

    _saveMessageToServer(msg);
  }

  Future<void> _saveMessageToServer(_Message msg) async {
    try {
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/send-group-message"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "group_id": widget.groupId,
          "sender_id": msg.senderId,
          "sender_name": msg.senderName,
          "message": msg.content,
        }),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true) {
          final realId = data['data']['id'].toString();
          // cập nhật id thật cho tin nhắn local (tránh trùng/khác id với
          // bản broadcast realtime nếu server gửi message_deleted sau này)
          final idx = messages.value.indexWhere((m) => m.id == msg.id);
          if (idx != -1) {
            final updated = List<_Message>.from(messages.value);
            updated[idx].id = realId;
            messages.value = updated;
          }
        }
      }
    } catch (e) {
      debugPrint("❌ Save message error: $e");
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

    // ---------- Phản hồi join/init (phx_reply) ----------
    if (event == "phx_reply") {
      final status = payload?["status"];
      final response = payload?["response"];
      if (status == "ok" && response?["message"] == "user_initialized") {
        _initialized = true;
        // gửi lại các tin nhắn đang chờ vì lúc đó socket chưa init xong
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
          // server từ chối send_message vì chưa init -> thử init lại
          _initUser();
        }
      }
      return;
    }

    if (event == "new_message") {
      // ⭐ ép kiểu an toàn — tránh crash/nuốt lỗi do sender_id có thể là
      // String hoặc int tùy phản hồi server
      final senderId = int.tryParse(payload["sender_id"].toString()) ?? 0;
      final avatar = payload["avatar_url"];
      if (avatar != null && avatar.toString().isNotEmpty) {
        _userAvatars[senderId] = avatar.toString();
      }

      if (senderId != widget.userId) {
        final m = _Message(
          id: payload["id"]?.toString() ??
              "local_${DateTime.now().millisecondsSinceEpoch}",
          senderId: senderId,
          senderName: payload["sender_name"] ?? "Người dùng",
          content: payload["content"] ?? '',
          time: (DateTime.tryParse(payload["created_at"] ?? '') ?? DateTime.now())
              .toLocal(),
          isOwn: false,
          avatarUrl: _userAvatars[senderId] ?? avatar,
        );

        if (!messages.value.any((msg) => msg.id == m.id)) {
          messages.value = [...messages.value, m];
          _scrollToBottom();
        }

        if (!participants.value.any((p) => p.userId == m.senderId)) {
          participants.value = [
            ...participants.value,
            _Participant(
              userId: m.senderId,
              username: m.senderName,
              avatarUrl: m.avatarUrl,
            )
          ];
        }
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
          SnackBar(
            content: Text(messageText),
            duration: const Duration(seconds: 2),
          ),
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
          _Participant(
            userId: joinedUserId,
            username: username,
            avatarUrl: avatar,
          )
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
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                )
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Icon(Icons.arrow_back_ios_new,
                          color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: widget.groupAvatar != null && widget.groupAvatar!.isNotEmpty
                          ? ClipOval(
                        child: Image.network(
                          widget.groupAvatar!,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                        ),
                      )
                          : Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white24,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          widget.groupName.isNotEmpty
                              ? widget.groupName[0].toUpperCase()
                              : "-",
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.groupName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    // Hiển thị trạng thái kết nối — giúp người dùng biết
                    // socket đang bị rớt thay vì tự hỏi vì sao tin nhắn không
                    // gửi/nhận được.
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
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
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
                        onLongPress: () {
                          if (list[i].isOwn) _deleteMessage(list[i]);
                        },
                        child: _MessageBubble(
                          list[i],
                          primaryBlue: primaryBlue,
                          accentOrange: accentOrange,
                          currentUserId: widget.userId,
                          userAvatars: _userAvatars,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            _buildInputBox(),
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
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
      ),
    );
  }

  Widget _buildSkeletonBubble(bool isOwn) {
    return Container(
      height: 18 + (isOwn ? 0 : 6),
      width: isOwn ? 150 : 120,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
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
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: input,
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

  _Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.time,
    required this.isOwn,
    this.avatarUrl,
  });
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
  final Map<int, String> userAvatars; // map avatar từ parent

  const _MessageBubble(
      this.msg, {
        required this.primaryBlue,
        required this.accentOrange,
        required this.currentUserId,
        required this.userAvatars,
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

  @override
  Widget build(BuildContext context) {
    final isOwn = msg.isOwn;
    final Color bubbleColor = isOwn ? primaryBlue : _getUserColor(msg.senderId);

    final avatarUrl = userAvatars[msg.senderId] ?? msg.avatarUrl;

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
                  Text(
                    msg.senderName,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(
                    color: bubbleColor.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(msg.content, style: const TextStyle(color: Colors.white)),
                ),
                Text(
                  _formatMessageTime(msg.time),
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
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