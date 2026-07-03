    import 'dart:async';
    import 'dart:convert';
    import 'package:flutter/material.dart';
    import 'package:phoenix_socket/phoenix_socket.dart';
    import 'package:intl/intl.dart';
    import 'package:http/http.dart' as http;
    import 'user_info_page.dart';
    import '../config/app_config.dart';

    class ChatPagePhoenix extends StatefulWidget {
      final String username;
      final int userId;
      final String targetUser;
      final int targetId;
      final String? targetAvatar;
      final String serverUrl;

      const ChatPagePhoenix({
        super.key,
        required this.username,
        required this.userId,
        required this.targetUser,
        required this.targetId,
        this.targetAvatar,
        this.serverUrl = AppConfig.websocketUrl,
      });

      @override
      State<ChatPagePhoenix> createState() => _ChatPageState();
    }

    class _ChatPageState extends State<ChatPagePhoenix> {
      PhoenixSocket? socket;
      PhoenixChannel? channel;

      final controller = TextEditingController();
      final scrollController = ScrollController();
      final messages = ValueNotifier<List<_Message>>([]);

      bool sending = false;
      bool isTyping = false;
      bool _loading = true;
      bool _channelReady = false;
      // Thêm dòng này
      final typingUserNotifier = ValueNotifier<String?>(null);


      String? typingUser;
      Timer? typingTimer;

      final Color primaryBlue = const Color(0xFF1E3A8A);
      final Color accentOrange = const Color(0xFFFF7F50);

      @override
      void initState() {
        super.initState();
        _loadOldMessages();
        _initSocket();
      }

      int parseIntSafe(String? value, {int defaultValue = 0}) {
        if (value == null) return defaultValue;
        return int.tryParse(value) ?? defaultValue;
      }


      @override
      void dispose() {
        channel?.leave();
        socket?.dispose();
        controller.dispose();
        scrollController.dispose();
        messages.dispose();
        typingTimer?.cancel();
        super.dispose();
      }

      // ---------------- SOCKET ----------------
      Future<void> _initSocket() async {
        if (socket == null) socket = PhoenixSocket(widget.serverUrl);

        try {
          if (!(socket?.isConnected ?? false)) {
            await socket!.connect();
          }

          if (!_channelReady) {
            await _createChannel();
          }
        } catch (e) {
          debugPrint("❌ Socket connect error: $e");
        }
      }

      Future<void> _createChannel() async {
        final ids = [widget.userId, widget.targetId]..sort();
        final topic = "room:chat_${ids[0]}_${ids[1]}";

        if (channel != null) return; // channel đã tạo rồi

        // Chỉ tạo channel, không gửi params khi join
        channel = socket!.addChannel(topic: topic);

        try {
          await channel!.join(); // join sạch, không crash
          _channelReady = true;
          debugPrint("✅ Joined channel: $topic");

          // Gửi user info sau join
          await channel!.push("init_user", {
            "user_id": widget.userId,
            "username": widget.username,
          });
          await Future.delayed(const Duration(milliseconds: 100)); // chắc chắn assign xong

        } catch (e) {
          _channelReady = false;
          debugPrint("❌ Failed join channel: $topic | $e");
          return;
        }

        // Lắng nghe realtime
        channel!.messages.listen((event) {
          final e = event.event.toString();
          final payload = event.payload;
          debugPrint("⚡ Event: $e | payload type=${payload.runtimeType} | value=$payload");

          if (event.event == "typing" || event.event == "stop_typing") {

            final data = Map<String, dynamic>.from(event.payload as Map);
            final senderId = data["sender_id"]?.toString();
            final username = data["username"]?.toString();
            debugPrint("🔥 Typing event: ${event.event} | sender=$senderId username=$username | currentUser=${widget.userId}");

            if (senderId == null || senderId == widget.userId) return;

            debugPrint("💬 TypingEvent: $event.event from $username");

            if (event.event == "typing") {
              if (typingUser != username) {
                setState(() => typingUser = username);
              }
            } else if (event.event == "stop_typing") {
              Future.delayed(const Duration(milliseconds: 800), () {
                if (mounted && typingUser == username) {
                  setState(() => typingUser = null);
                }
              });
            }

          }
          else if (event.event == "new_message_${widget.userId}" || event.event == "new_message_${widget.targetId}") {
            _handleIncomingMessage(event.payload);
          }

        });







      }



      Future<void> _pushWithRetry(String event, Map<String, dynamic> payload) async {
        int retries = 0;
        while (retries < 3) {
          try {
            if (_channelReady && channel?.state == PhoenixChannelState.joined) {
              await channel!.push(event, payload);
              return;
            }
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 500));
          retries++;
        }
      }

      // ---------------- MESSAGE ----------------
      Future<void> _loadOldMessages() async {
        setState(() => _loading = true);
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
              final senderId = m['sender_id'];
              final isOwn = senderId == widget.userId;
              return _Message(
                id: m['id'].toString(),
                senderId: senderId,
                content: m['message'] ?? '',
                time: (DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now())
                    .add(const Duration(hours: 7)),
                isOwn: isOwn,
                avatarUrl: isOwn ? null : widget.targetAvatar,
              );
            }).toList();
          }
        } catch (e) {
          debugPrint("❌ Load messages error: $e");
        } finally {
          setState(() => _loading = false);
          _scrollToBottom();
        }
      }

      DateTime parseSafeDate(String? dateStr) {
        try {
          return DateTime.parse(dateStr ?? '').toLocal();
        } catch (_) {
          return DateTime.now();
        }
      }

      Future<void> _sendMessage() async {
        final text = controller.text.trim();
        if (text.isEmpty || sending) return;

        sending = true;
        controller.clear();

        final tempMsg = _Message(
          id: "local_${DateTime.now().millisecondsSinceEpoch}",
          senderId: widget.userId,
          content: text,
          time: DateTime.now(),
          isOwn: true,
        );

// Gán list mới để ValueNotifier phát hiện thay đổi chắc chắn
        messages.value = List<_Message>.from(messages.value)..add(tempMsg);
        messages.notifyListeners();
        _scrollToBottom();



        try {
          await _pushWithRetry("send_message", {
            "sender_id": widget.userId,
            "receiver_id": widget.targetId,
            "content": text,
          });


          await http.post(
            Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/send-message"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "sender_id": widget.userId,
              "receiver_id": widget.targetId,
              "message": text,
            }),
          );
        } catch (e) {
          debugPrint("❌ Send message error: $e");
        } finally {
          sending = false;
        }
      }

      void _handleIncomingMessage(dynamic data) {
        final msgId = data["id"]?.toString();
        if (msgId != null && messages.value.any((m) => m.id == msgId)) return;

        final senderId = data["sender_id"];
        final isOwn = senderId == widget.userId;

        final msg = _Message(
          id: msgId ?? "local_${DateTime.now().millisecondsSinceEpoch}",
          senderId: senderId,
          content: data["message"] ?? data["content"]?.toString() ?? '',
          time: parseSafeDate(data["created_at"] ?? data["time"]),
          isOwn: isOwn,
          avatarUrl: isOwn ? null : widget.targetAvatar,
        );

        // Gán list mới (không mutate in-place)
        final newList = List<_Message>.from(messages.value)..add(msg);
        messages.value = newList;

        debugPrint("✅ Incoming message added. total=${messages.value.length} id=${msg.id}");
        _scrollToBottom();
      }

      // ---------------- TYPING ----------------
      void _onTextChanged(String text) {
        if (!isTyping) {
          setState(() => isTyping = true);
          _sendTypingEvent("typing");
        }

        typingTimer?.cancel();
        typingTimer = Timer(const Duration(seconds: 2), () {
          if (isTyping) {
            setState(() => isTyping = false);
            _sendTypingEvent("stop_typing");
          }
        });
      }

      Future<void> _sendTypingEvent(String type) async {
        if (!_channelReady) return;
        final event = type == "typing" ? "typing" : "stop_typing";

        final payload = {
          "sender_id": widget.userId,
          "target_id": widget.targetId,
          "username": widget.username ?? "kiwi", // ⚡ bắt buộc
        };

        debugPrint("⚡ Sending $event payload: $payload"); // ✅ log payload

        await _pushWithRetry(event, payload);
      }



      // ---------------- UI ----------------
      void _scrollToBottom() {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await Future.delayed(const Duration(milliseconds: 50)); // cho render xong
          if (!mounted) return;
          if (scrollController.hasClients) {
            try {
              // reverse: true => bottom is minScrollExtent (0). Use min safe.
              final target = scrollController.position.minScrollExtent;
              scrollController.animateTo(
                target,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            } catch (e) {
              // fallback: jumpTo 0
              try {
                scrollController.jumpTo(scrollController.position.minScrollExtent);
              } catch (_) {}
            }
          }
        });
      }


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
                // ---------------- AppBar ----------------
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
                ),

                // ---------------- Typing indicator ----------------
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: typingUser != null
                      ? Builder(builder: (_) {
                    debugPrint("🔥 build typingUser = $typingUser");
                    return Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        "$typingUser đang gõ...",
                        style: TextStyle(
                          fontSize: 12,
                          color: accentOrange,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    );
                  })
                      : const SizedBox.shrink(),
                ),

                // ---------------- Message list ----------------
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: _loading
                        ? _buildLoadingList()
                        : ValueListenableBuilder<List<_Message>>(
                      valueListenable: messages,
                      builder: (_, msgs, __) {
                        final list = msgs.reversed.toList();
                        return ListView.builder(
                          key: const ValueKey("msgList"),
                          controller: scrollController,
                          reverse: true,
                          padding: const EdgeInsets.all(8),
                          itemCount: list.length,
                          itemBuilder: (_, i) => _MessageBubble(
                            list[i],
                            primaryBlue,
                            accentOrange,
                            currentUserId: widget.userId, // truyền user đang login
                          ),
                        );
                      },
                    ),
                  ),
                ),

                // ---------------- Input box ----------------
                _buildInputBox(),
              ],
            ),
          ),
        );
      }


      Widget _buildLoadingList() {
        return ListView.builder(
          key: const ValueKey("loadingList"),
          itemCount: 6,
          padding: const EdgeInsets.all(12),
          itemBuilder: (_, i) => Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            alignment: i.isEven ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 800),
              width: 180 + (i % 3) * 20,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.grey.shade300.withOpacity(0.5),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        );
      }

      Widget _buildInputBox() {
        return Container(
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
                    controller: controller,
                    onChanged: _onTextChanged,
                    onSubmitted: (_) => _sendMessage(),
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
                  onPressed: sending ? null : _sendMessage,
                )
              ],
            ),
          ),
        );
      }
    }

    // ---------------- MESSAGE MODEL + UI ----------------
    class _Message {
      final String id;
      final int senderId;
      final String content;
      final DateTime time;
      final bool isOwn;
      final String? avatarUrl;

      _Message({
        required this.id,
        required this.senderId,
        required this.content,
        required this.time,
        required this.isOwn,
        this.avatarUrl,
      });
    }

    class _MessageBubble extends StatelessWidget {
      final _Message msg;
      final Color primaryBlue;
      final Color accentOrange;
      final int currentUserId; // thêm dòng này

      const _MessageBubble(
          this.msg,
          this.primaryBlue,
          this.accentOrange, {
            required this.currentUserId, // bắt buộc
            super.key,
          });

      String _formatMessageTime(DateTime time) {
        final now = DateTime.now();
        final isToday = time.year == now.year &&
            time.month == now.month &&
            time.day == now.day;
        final isThisYear = time.year == now.year;

        if (isToday) {
          return DateFormat('HH:mm').format(time);
        } else if (isThisYear) {
          return DateFormat('dd/MM HH:mm').format(time);
        } else {
          return DateFormat('dd/MM/yyyy HH:mm').format(time);
        }
      }

      @override
      Widget build(BuildContext context) {
        final isOwn = msg.isOwn;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            mainAxisAlignment: isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!isOwn)
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => UserInfoPage(
                          userId: currentUserId,           // người login
                          targetUserId: msg.senderId,      // người nhận click
                          username: "User",           // username target
                          avatarUrl: msg.avatarUrl ?? '',
                        ),
                      ),
                    );
                  },
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: accentOrange,
                    backgroundImage: msg.avatarUrl != null && msg.avatarUrl!.isNotEmpty
                        ? NetworkImage(msg.avatarUrl!)
                        : null,
                    child: (msg.avatarUrl == null || msg.avatarUrl!.isEmpty)
                        ? Text(
                      msg.senderId.toString()[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    )
                        : null,
                  ),
                ),
              if (!isOwn) const SizedBox(width: 6),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isOwn
                          ? [primaryBlue.withOpacity(0.9), primaryBlue]
                          : [accentOrange.withOpacity(0.9), accentOrange],
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
                      Text(
                        msg.content,
                        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _formatMessageTime(msg.time),
                        style: const TextStyle(fontSize: 10, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }
