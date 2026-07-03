import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../helpers/storage_helper.dart';
//import 'chat_page_phoenix.dart';
import 'chat_page.dart';
import 'flutter_map.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';
import 'package:intl/intl.dart';
//import 'package:flutter_secure_storage/flutter_secure_storage.dart';


class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  List<Map<String, dynamic>> chatList = [];
  bool loading = true;

  // 🎨 Màu chủ đạo đồng bộ với ProfilePage
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    _fetchChatList();
    // chỉ dùng test/debug
    //resetAllJoins();
  }
  /*Future<void> resetAllJoins() async {
    const storage = FlutterSecureStorage();
    final all = await storage.readAll(); // ✅ lấy tất cả key
    for (var key in all.keys) {
      if (key.startsWith("joined_")) {
        await StorageHelper.delete(key); // dùng StorageHelper để xóa
        debugPrint("Deleted $key");
      }
    }
    debugPrint("✅ Reset tất cả join done");
  }*/

  Future<void> _fetchChatList() async {
    setState(() => loading = true);

    try {
      final userId = await StorageHelper.read("user_id");
      if (userId == null) return;

      final url = Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/get-chat-list");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"user_id": int.parse(userId)}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data.containsKey("chats")) {
          final allChats = List<Map<String, dynamic>>.from(data["chats"]);

          // loại trùng target_id
          final Map<String, Map<String, dynamic>> uniqueChats = {};
          for (var chat in allChats) {
            final targetId = chat["target_id"]?.toString() ?? "";
            if (!uniqueChats.containsKey(targetId)) {
              uniqueChats[targetId] = chat;
            }
          }

          setState(() {
            chatList = uniqueChats.values.toList();
          });
        }
      } else {
        debugPrint("❌ Lỗi load danh sách chat: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("❌ Lỗi khi tải danh sách chat: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  // 🌟 Card chat đẹp mắt
  Widget _buildChatCard(Map<String, dynamic> chat) {
    final targetName = chat["target_name"] ?? "Ẩn danh 2";
    final targetId = chat["target_id"]?.toString() ?? "0";
    final lastMessage = chat["last_message"] ?? "";
    final updatedAt = chat["updated_at"] ?? "";
    final targetAvatar = chat["avatar_url"] ?? ""; // ✅ thêm dòng này

    return GestureDetector(
      onTap: () async {
        final userDataStr = await StorageHelper.read("user_data");
        final userData = userDataStr != null ? jsonDecode(userDataStr) : {};
        final myName = userData["username"] ?? "Ẩn danh";
        final myId = await StorageHelper.read("user_id") ?? "0";

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatPage(
              username: myName,
              userId: int.parse(myId),
              targetUser: targetName,
              targetId: int.parse(targetId),
              targetAvatar: targetAvatar,
              serverUrl: AppConfig.websocketUrl,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Colors.white.withOpacity(0.15),
              Colors.white.withOpacity(0.08),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black26.withOpacity(0.1),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: accentOrange,
              backgroundImage: chat["avatar_url"] != null && chat["avatar_url"].toString().isNotEmpty
                  ? NetworkImage(chat["avatar_url"])
                  : null,
              child: (chat["avatar_url"] == null || chat["avatar_url"].toString().isEmpty)
                  ? Text(
                targetName.isNotEmpty ? targetName[0].toUpperCase() : "?",
                style: const TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              )
                  : null,
            ),

            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    targetName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    lastMessage.isNotEmpty ? lastMessage : "(Chưa có tin nhắn)",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Icon(Icons.access_time, color: Colors.white70, size: 14),
                const SizedBox(height: 4),
                Text(
                  updatedAt,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ✨ Skeleton load giả lập khi đang tải
  Widget _buildSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      itemBuilder: (_, __) {
        return shimmer.Shimmer.fromColors(
          baseColor: Colors.white.withOpacity(0.10),
          highlightColor: Colors.white.withOpacity(0.45),
          period: const Duration(milliseconds: 1100),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                // Avatar fake
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    shape: BoxShape.circle,
                  ),
                ),

                const SizedBox(width: 14),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: 120,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.25),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        height: 12,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Nền gradient đồng bộ với ProfilePage
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // AppBar custom
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  "Danh sách trò chuyện",
                  style: TextStyle(
                    color: textWhite,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: loading
                    ? _buildSkeleton()
                    : chatList.isEmpty
                    ? const Center(
                  child: Text(
                    "Chưa có cuộc trò chuyện nào",
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                )
                    : RefreshIndicator(
                  color: accentOrange,
                  backgroundColor: Colors.white,
                  onRefresh: _fetchChatList,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: chatList.length,
                    itemBuilder: (context, index) =>
                        _buildChatCard(chatList[index]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

      // FAB map bạn bè quanh đây
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: accentOrange,
        icon: const Icon(Icons.map, color: Colors.white),
        label: const Text(
          "Bạn quanh đây",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        onPressed: () async {
          final username = await StorageHelper.read("username") ?? "Visitor";
          final userIdStr = await StorageHelper.read("user_id") ?? "0";
          final userIdInt = int.tryParse(userIdStr) ?? 0;
          final email = await StorageHelper.read("user_email") ?? "";
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MapPage(
                username: username,
                userId: userIdInt,
                email: email,
              ),
            ),
          );
        },
      ),
    );
  }
}
class Shimmer extends StatefulWidget {
  final Widget child;

  const Shimmer({
    super.key,
    required this.child,
  });

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer>
    with SingleTickerProviderStateMixin {

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment(-2 + 4 * _controller.value, 0),
              end: Alignment(-1 + 4 * _controller.value, 0),
              colors: const [
                Color(0x00FFFFFF),
                Color(0x66FFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: const [0.3, 0.5, 0.7],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}
