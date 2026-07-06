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
  bool hasError = false; // ✅ theo dõi trạng thái lỗi mạng/API

  // 🎨 Màu chủ đạo đồng bộ với ProfilePage
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    _fetchChatList();
  }

  /// ✅ Format thời gian: hôm nay -> giờ:phút, khác ngày -> dd/MM
  String _formatUpdatedAt(String rawDate) {
    if (rawDate.isEmpty) return "";
    try {
      final date = DateTime.parse(rawDate);
      final now = DateTime.now();
      final isToday = date.year == now.year &&
          date.month == now.month &&
          date.day == now.day;
      return isToday
          ? DateFormat('HH:mm').format(date)
          : DateFormat('dd/MM').format(date);
    } catch (_) {
      // Nếu server trả định dạng không parse được thì hiển thị nguyên văn
      return rawDate;
    }
  }

  Future<void> _fetchChatList() async {
    if (!mounted) return;
    setState(() {
      loading = true;
      hasError = false;
    });

    try {
      final userId = await StorageHelper.read("user_id");
      if (userId == null) {
        if (!mounted) return;
        setState(() {
          loading = false;
          hasError = true;
        });
        return;
      }

      final parsedUserId = int.tryParse(userId);
      if (parsedUserId == null) {
        if (!mounted) return;
        setState(() {
          loading = false;
          hasError = true;
        });
        return;
      }

      final url = Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/get-chat-list");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"user_id": parsedUserId}),
      );

      if (!mounted) return;

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

          final list = uniqueChats.values.toList();

          // ✅ Sắp xếp theo updated_at giảm dần (mới nhất lên đầu)
          list.sort((a, b) {
            final aDate = DateTime.tryParse(a["updated_at"]?.toString() ?? "");
            final bDate = DateTime.tryParse(b["updated_at"]?.toString() ?? "");
            if (aDate == null || bDate == null) return 0;
            return bDate.compareTo(aDate);
          });

          setState(() {
            chatList = list;
            hasError = false;
          });
        } else {
          setState(() => hasError = true);
        }
      } else {
        debugPrint("❌ Lỗi load danh sách chat: ${response.statusCode}");
        setState(() => hasError = true);
      }
    } catch (e) {
      debugPrint("❌ Lỗi khi tải danh sách chat: $e");
      if (mounted) setState(() => hasError = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // 🌟 Card chat đẹp mắt
  Widget _buildChatCard(Map<String, dynamic> chat) {
    final targetName = chat["target_name"] ?? "Ẩn danh 2";
    final targetId = chat["target_id"]?.toString() ?? "0";
    final lastMessage = chat["last_message"] ?? "";
    final updatedAt = chat["updated_at"]?.toString() ?? "";
    final targetAvatar = chat["avatar_url"] ?? "";
    final unreadCount = int.tryParse(chat["unread_count"]?.toString() ?? "") ?? 0; // ✅ badge chưa đọc (nếu API có trả)

    return GestureDetector(
      onTap: () async {
        final userDataStr = await StorageHelper.read("user_data");
        final userData = userDataStr != null ? jsonDecode(userDataStr) : {};
        final myName = userData["username"] ?? "Ẩn danh";
        final myId = await StorageHelper.read("user_id") ?? "0";
        final targetIdInt = int.tryParse(targetId) ?? 0;
        final myIdInt = int.tryParse(myId) ?? 0;

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatPage(
              username: myName,
              userId: myIdInt,
              targetUser: targetName,
              targetId: targetIdInt,
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
              backgroundImage: targetAvatar.toString().isNotEmpty
                  ? NetworkImage(targetAvatar) as ImageProvider
                  : null,
              onBackgroundImageError: targetAvatar.toString().isNotEmpty
                  ? (_, __) {
                // ✅ tránh crash / icon vỡ khi URL ảnh lỗi
                debugPrint("⚠️ Lỗi tải avatar: $targetAvatar");
              }
                  : null,
              child: targetAvatar.toString().isEmpty
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
                Text(
                  _formatUpdatedAt(updatedAt),
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 6),
                // ✅ Badge số tin nhắn chưa đọc
                if (unreadCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: accentOrange,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unreadCount > 99 ? "99+" : "$unreadCount",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                else
                  const Icon(Icons.access_time, color: Colors.white70, size: 14),
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

  // ✅ Trạng thái lỗi mạng/API — có nút thử lại
  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white70, size: 42),
          const SizedBox(height: 12),
          const Text(
            "Không thể tải danh sách trò chuyện",
            style: TextStyle(color: Colors.white70, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _fetchChatList,
            style: ElevatedButton.styleFrom(
              backgroundColor: accentOrange,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.refresh),
            label: const Text("Thử lại"),
          ),
        ],
      ),
    );
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
        child: SafeArea(
          child: Column(
            children: [
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
                    : hasError
                    ? _buildErrorState()
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
          if (!mounted) return;
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