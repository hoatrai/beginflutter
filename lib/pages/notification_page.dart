import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'notification_store.dart';
import '../main.dart'
    show unreadNotiVN, openInviteById, openChatFromData, openGroupChatFromData;

const _kNavy = Color(0xFF1E3A8A);
const _kOrange = Color(0xFFFF7F50);

/// Mô tả icon/màu riêng cho từng loại thông báo — giúp người dùng
/// nhận diện ngay loại thông báo (chat / kèo / nhóm...) chỉ bằng ánh mắt.
class _NotiVisual {
  final IconData icon;
  final Color color;
  const _NotiVisual(this.icon, this.color);
}

_NotiVisual _visualFor(String? type) {
  switch (type) {
    case 'chat_message':
      return const _NotiVisual(Icons.chat_bubble_rounded, Color(0xFF3B82F6));
    case 'group_chat_message':
      return const _NotiVisual(Icons.groups_rounded, Color(0xFF14B8A6));
    case 'invite_keo':
      return const _NotiVisual(Icons.local_bar_rounded, _kOrange);
    case 'new_product':
      return const _NotiVisual(Icons.celebration_rounded, Color(0xFFF59E0B));
    case 'user_joined':
      return const _NotiVisual(Icons.person_add_alt_1_rounded, Color(0xFF22C55E));
    case 'user_left':
      return const _NotiVisual(Icons.logout_rounded, Color(0xFF9CA3AF));
    case 'user_kicked':
      return const _NotiVisual(Icons.remove_circle_rounded, Color(0xFFEF4444));
    case 'video_call':
      return const _NotiVisual(Icons.videocam_rounded, Color(0xFF8B5CF6));
    default:
      return const _NotiVisual(Icons.notifications_rounded, _kNavy);
  }
}

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  /// 0 = Tất cả, 1 = Chưa đọc — lọc theo tab đang chọn.
  int _tab = 0;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final all = NotificationStore.items;
    final unread = all.where((n) => !n.isRead).toList();
    final visible = _tab == 0 ? all : unread;
    final grouped = _groupByDate(visible);

    return Scaffold(
      extendBody: true,
      backgroundColor: _kNavy,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xF01E3A8A), Color(0xD8FF7F50)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(all.length, unread.length),
              _buildTabs(all.length, unread.length),
              const SizedBox(height: 4),
              Expanded(
                child: visible.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        color: _kOrange,
                        backgroundColor: Colors.white,
                        onRefresh: () async {
                          // Danh sách đang được đồng bộ realtime qua FCM /
                          // socket ngay khi có push tới, "kéo để làm mới"
                          // ở đây chủ yếu tạo cảm giác phản hồi tức thời.
                          await Future.delayed(const Duration(milliseconds: 400));
                          setState(() {});
                        },
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                          itemCount: _flattenCount(grouped),
                          itemBuilder: (_, flatIndex) =>
                              _buildFlatItem(grouped, flatIndex),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================= APPBAR =================

  Widget _buildAppBar(int total, int unreadCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Thông báo",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  unreadCount > 0
                      ? "$unreadCount thông báo chưa đọc"
                      : "Bạn đã xem hết thông báo",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.75),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
            color: const Color(0xFF25417F),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            onSelected: (value) {
              if (value == 'read_all') _markAllRead();
              if (value == 'clear_all') _confirmClearAll();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'read_all',
                enabled: unreadCount > 0,
                child: const Row(
                  children: [
                    Icon(Icons.done_all_rounded, color: Colors.white, size: 18),
                    SizedBox(width: 10),
                    Text('Đánh dấu tất cả đã đọc',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'clear_all',
                enabled: total > 0,
                child: const Row(
                  children: [
                    Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 18),
                    SizedBox(width: 10),
                    Text('Xoá tất cả', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ================= TABS =================

  Widget _buildTabs(int total, int unreadCount) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _tabChip("Tất cả", total, 0),
          const SizedBox(width: 10),
          _tabChip("Chưa đọc", unreadCount, 1),
        ],
      ),
    );
  }

  Widget _tabChip(String label, int count, int index) {
    final selected = _tab == index;
    return GestureDetector(
      onTap: () => setState(() => _tab = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withOpacity(selected ? 0 : 0.25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? _kNavy : Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: selected ? _kOrange : Colors.white.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  count > 99 ? "99+" : "$count",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ================= EMPTY STATE =================

  Widget _buildEmptyState() {
    final isUnreadTab = _tab == 1;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.12),
            ),
            child: Icon(
              isUnreadTab
                  ? Icons.mark_email_read_rounded
                  : Icons.notifications_off_rounded,
              color: Colors.white70,
              size: 42,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isUnreadTab ? "Không còn thông báo chưa đọc" : "Chưa có thông báo nào",
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isUnreadTab
                ? "Bạn đã xem hết mọi thông báo rồi"
                : "Thông báo về kèo, chat, nhóm... sẽ hiện ở đây",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ================= LIST GROUPING =================

  /// Nhóm thông báo theo "Hôm nay / Hôm qua / Cũ hơn" để dễ quét mắt.
  Map<String, List<dynamic>> _groupByDate(List<dynamic> items) {
    final now = DateTime.now();
    final today = <dynamic>[];
    final yesterday = <dynamic>[];
    final earlier = <dynamic>[];

    for (final n in items) {
      final t = n.time as DateTime;
      final isToday = t.year == now.year && t.month == now.month && t.day == now.day;
      final y = now.subtract(const Duration(days: 1));
      final isYesterday = t.year == y.year && t.month == y.month && t.day == y.day;

      if (isToday) {
        today.add(n);
      } else if (isYesterday) {
        yesterday.add(n);
      } else {
        earlier.add(n);
      }
    }

    final map = <String, List<dynamic>>{};
    if (today.isNotEmpty) map["Hôm nay"] = today;
    if (yesterday.isNotEmpty) map["Hôm qua"] = yesterday;
    if (earlier.isNotEmpty) map["Trước đó"] = earlier;
    return map;
  }

  int _flattenCount(Map<String, List<dynamic>> grouped) {
    var count = 0;
    for (final entry in grouped.entries) {
      count += 1 + entry.value.length; // 1 header + N items
    }
    return count;
  }

  Widget _buildFlatItem(Map<String, List<dynamic>> grouped, int flatIndex) {
    var cursor = 0;
    for (final entry in grouped.entries) {
      if (flatIndex == cursor) {
        return _sectionHeader(entry.key);
      }
      cursor++;
      final localIndex = flatIndex - cursor;
      if (localIndex < entry.value.length) {
        return _notificationTile(entry.value[localIndex]);
      }
      cursor += entry.value.length;
    }
    return const SizedBox.shrink();
  }

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 8),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withOpacity(0.8),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  // ================= NOTIFICATION TILE =================

  Widget _notificationTile(dynamic n) {
    final visual = _visualFor(n.type as String?);

    return Dismissible(
      key: ValueKey(n.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.85),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
      ),
      onDismissed: (_) {
        setState(() => NotificationStore.remove(n.id as String));
        unreadNotiVN.value = NotificationStore.unreadCount.value;
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _busy ? null : () => _handleTap(n),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: n.isRead ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.14),
                border: Border.all(
                  color: n.isRead
                      ? Colors.white.withOpacity(0.10)
                      : Colors.white.withOpacity(0.28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ================= ICON =================
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: visual.color.withOpacity(0.9),
                    ),
                    child: Icon(visual.icon, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),

                  // ================= TEXT =================
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          n.title as String,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: n.isRead ? FontWeight.w600 : FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          n.body as String,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.75),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _formatTime(n.time as DateTime),
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.55),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (!(n.isRead as bool)) ...[
                    const SizedBox(width: 8),
                    Container(
                      width: 9,
                      height: 9,
                      margin: const EdgeInsets.only(top: 4),
                      decoration: const BoxDecoration(
                        color: _kOrange,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ================= ACTIONS =================

  void _markAllRead() {
    NotificationStore.markAllRead();
    unreadNotiVN.value = 0;
    setState(() {});
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF25417F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Xoá tất cả thông báo?",
            style: TextStyle(color: Colors.white)),
        content: const Text(
          "Toàn bộ thông báo hiện tại sẽ bị xoá và không thể khôi phục.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Huỷ", style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Xoá tất cả", style: TextStyle(color: _kOrange)),
          ),
        ],
      ),
    );

    if (ok == true) {
      NotificationStore.clearAll();
      unreadNotiVN.value = 0;
      setState(() {});
    }
  }

  /// Mở đúng trang tương ứng khi bấm vào 1 thông báo, dựa theo `type`
  /// được lưu lúc nhận push (xem main.dart -> NotificationStore.add và
  /// lib/phoenix_socket/notifications.ex phía backend để biết type/data
  /// nào tương ứng payload nào):
  ///   - invite_keo / new_product / user_joined / user_left / user_kicked
  ///     -> trang chi tiết "kèo" (ProductDetailPage)
  ///   - chat_message      -> trang chat 1-1 (ChatPage)
  ///   - group_chat_message -> trang chat nhóm (GroupChatPage)
  Future<void> _handleTap(dynamic n) async {
    NotificationStore.markRead(n.id as String);
    unreadNotiVN.value = NotificationStore.unreadCount.value;
    setState(() {});

    final type = n.type as String?;
    final data = n.data as Map<String, dynamic>?;

    setState(() => _busy = true);
    try {
      bool ok = false;
      String failMessage = "Không thể mở thông báo này. Vui lòng thử lại.";

      switch (type) {
        case 'invite_keo':
        case 'new_product':
        case 'user_joined':
        case 'user_left':
        case 'user_kicked':
          final keoId = (data?['keo_id'] ?? data?['product_id'])?.toString();
          if (keoId == null || keoId.isEmpty) {
            failMessage = "Thông báo này thiếu thông tin kèo.";
          } else {
            ok = await openInviteById(keoId);
            failMessage = "Không tìm thấy kèo này (có thể đã bị xoá).";
          }
          break;

        case 'chat_message':
          if (data == null) {
            failMessage = "Thông báo này thiếu dữ liệu người gửi.";
          } else {
            ok = await openChatFromData(data);
            failMessage = "Không thể mở đoạn chat. Kiểm tra lại kết nối mạng.";
          }
          break;

        case 'group_chat_message':
          if (data == null) {
            failMessage = "Thông báo này thiếu dữ liệu nhóm.";
          } else {
            ok = await openGroupChatFromData(data);
            failMessage = "Không thể mở nhóm chat. Kiểm tra lại kết nối mạng.";
          }
          break;

        default:
          // type khác (hoặc null) -> chỉ mark-read, không navigate.
          ok = true;
          break;
      }

      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(failMessage),
            backgroundColor: const Color(0xFF25417F),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hiển thị giờ:phút nếu noti trong hôm nay, "Hôm qua" nếu hôm qua,
  /// còn lại hiện ngày/tháng để khỏi gây hiểu nhầm là noti mới.
  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final isToday = t.year == now.year && t.month == now.month && t.day == now.day;

    if (isToday) {
      return "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
    }

    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = t.year == yesterday.year &&
        t.month == yesterday.month &&
        t.day == yesterday.day;

    if (isYesterday) return "Hôm qua";

    return DateFormat("dd/MM").format(t);
  }
}
