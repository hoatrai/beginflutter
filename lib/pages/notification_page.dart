import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'notification_store.dart';
import '../main.dart' show unreadNotiVN, openInviteById, openChatFromData;

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  @override
  void initState() {
    super.initState();

    // Vào màn hình là reset cả trạng thái đọc của từng item
    // và badge tổng ở bottom nav / shop page.
    NotificationStore.markAllRead();
    unreadNotiVN.value = 0;
  }

  void _markAllRead() {
    NotificationStore.markAllRead();
    unreadNotiVN.value = 0; // phòng trường hợp có noti mới tới trong lúc đang mở trang
    setState(() {});
  }

  /// Mở đúng trang tương ứng (kèo/chat) khi bấm vào 1 thông báo,
  /// dựa theo type được lưu lúc nhận push (xem main.dart -> NotificationStore.add).
  Future<void> _handleTap(dynamic n) async {
    NotificationStore.markRead(n.id);
    setState(() {});

    final type = n.type;
    final data = n.data as Map<String, dynamic>?;

    if (type == 'invite_keo') {
      final keoId = data?['keo_id']?.toString();
      if (keoId != null && keoId.isNotEmpty) {
        await openInviteById(keoId);
      }
    } else if (type == 'chat_message') {
      if (data != null) {
        await openChatFromData(data);
      }
    }
    // type khác (hoặc null) -> chỉ mark-read, không navigate.
  }

  /// Hiển thị giờ:phút nếu noti trong hôm nay, "Hôm qua" nếu hôm qua,
  /// còn lại hiện ngày/tháng để khỏi gây hiểu nhầm là noti mới.
  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final isToday =
        t.year == now.year && t.month == now.month && t.day == now.day;

    if (isToday) {
      return "${t.hour.toString().padLeft(2, '0')}:"
          "${t.minute.toString().padLeft(2, '0')}";
    }

    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = t.year == yesterday.year &&
        t.month == yesterday.month &&
        t.day == yesterday.day;

    if (isYesterday) return "Hôm qua";

    return DateFormat("dd/MM").format(t);
  }

  @override
  Widget build(BuildContext context) {
    final items = NotificationStore.items;

    return Scaffold(
      extendBody: true,
      backgroundColor: const Color(0xFF1E3A8A), // thay vì Colors.transparent
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF1E3A8A).withOpacity(0.95),
              const Color(0xFFFF7F50).withOpacity(0.85),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            // ================= APPBAR =================
            SafeArea(
              child: Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Thông báo",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check_circle_outline,
                          color: Colors.white),
                      onPressed: _markAllRead,
                    ),
                  ],
                ),
              ),
            ),

            // ================= BODY =================
            Expanded(
              child: items.isEmpty
                  ? const Center(
                child: Text(
                  "Không có thông báo",
                  style: TextStyle(color: Colors.white70),
                ),
              )
                  : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final n = items[i];

                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _handleTap(n),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: n.isRead
                            ? LinearGradient(
                          colors: [
                            Colors.white.withOpacity(0.08),
                            Colors.white.withOpacity(0.04),
                          ],
                        )
                            : LinearGradient(
                          colors: [
                            const Color(0xFFFF7F50)
                                .withOpacity(0.25),
                            const Color(0xFF1E3A8A)
                                .withOpacity(0.25),
                          ],
                        ),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.12),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          // ================= ICON =================
                          Container(
                            width: 44,
                            height: 44,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: [
                                  Color(0xFFFF7F50),
                                  Color(0xFF1E3A8A),
                                ],
                              ),
                            ),
                            child: Icon(
                              n.isRead
                                  ? Icons.notifications_none
                                  : Icons.notifications_active,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),

                          // ================= TEXT =================
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                              CrossAxisAlignment.start,
                              children: [
                                Text(
                                  n.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  n.body,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                    Colors.white.withOpacity(0.75),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),

                          // ================= TIME =================
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _formatTime(n.time),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withOpacity(0.6),
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (!n.isRead)
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}