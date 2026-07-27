import 'dart:convert';
import 'package:flutter/material.dart';
import '../helpers/storage_helper.dart';

class AppNotification {
  final String id;
  final String title;
  final String body;
  final DateTime time;
  final String? type; // chat, invite, system...
  final Map<String, dynamic>? data;

  bool isRead;

  AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.time,
    this.type,
    this.data,
    this.isRead = false,
  });

  // ✅ Phục vụ lưu/khôi phục lịch sử noti xuống máy (xem NotificationStore).
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'time': time.toIso8601String(),
        'type': type,
        'data': data,
        'isRead': isRead,
      };

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.now(),
      type: json['type']?.toString(),
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : null,
      isRead: json['isRead'] == true,
    );
  }
}

class NotificationStore {
  static final List<AppNotification> items = [];

  // 👇 số chưa đọc
  static final ValueNotifier<int> unreadCount = ValueNotifier(0);

  // 👇 tín hiệu "danh sách vừa thay đổi" (thêm/xoá/đọc...) để UI đang mở
  // (vd NotificationPage) có thể lắng nghe và tự rebuild realtime, thay vì
  // chỉ cập nhật khi user tự tay tương tác (tap/pull-to-refresh).
  static final ValueNotifier<int> revision = ValueNotifier(0);
  static void _bump() => revision.value++;

  // ✅ Lưu lịch sử noti xuống máy (qua StorageHelper) để mất app / restart
  // máy vẫn còn xem lại được, thay vì chỉ nằm trong RAM như trước đây.
  static const String _storageKey = 'app_notifications_v1';
  // Giới hạn số lượng lưu để tránh phình to file lưu trữ vô hạn theo thời gian.
  static const int _maxStored = 200;
  static bool _loaded = false;

  /// Gọi 1 LẦN lúc app khởi động (main.dart, trước runApp) để khôi phục lại
  /// lịch sử thông báo đã lưu từ lần chạy trước. An toàn khi gọi nhiều lần
  /// — chỉ thực sự load lần đầu.
  static Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await StorageHelper.read(_storageKey);
      if (raw == null || raw.isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is List) {
        items
          ..clear()
          ..addAll(
            decoded
                .whereType<Map>()
                .map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e))),
          );
        unreadCount.value = items.where((n) => !n.isRead).length;
        _bump();
      }
    } catch (e) {
      debugPrint('⚠️ NotificationStore.init: lỗi đọc lịch sử noti đã lưu: $e');
    }
  }

  /// Lưu lại toàn bộ danh sách hiện tại xuống máy — gọi sau MỌI thay đổi
  /// (add/remove/markRead/markAllRead/clearAll). Chạy ngầm (không await ở
  /// nơi gọi) để không làm chậm UI.
  static Future<void> _persist() async {
    try {
      final encoded = jsonEncode(
        items.take(_maxStored).map((e) => e.toJson()).toList(),
      );
      await StorageHelper.write(_storageKey, encoded);
    } catch (e) {
      debugPrint('⚠️ NotificationStore: lỗi lưu lịch sử noti: $e');
    }
  }

  // 👇 thêm notification
  static void add({
    required String title,
    required String body,
    String? type,
    Map<String, dynamic>? data,
  }) {
    // 🔥 Chặn tận gốc: không cho tạo notification nếu cả title lẫn body
    // đều rỗng — dù caller nào gọi vào đây cũng không lọt được "thông
    // báo rỗng" vào danh sách.
    if (title.trim().isEmpty && body.trim().isEmpty) {
      return;
    }

    items.insert(
      0,
      AppNotification(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        body: body,
        time: DateTime.now(),
        type: type,
        data: data,
      ),
    );
    // Cắt bớt nếu vượt giới hạn lưu (list hiển thị vẫn có thể dài hơn trong
    // phiên hiện tại, chỉ giới hạn khi PERSIST xuống máy ở _persist()).
    if (items.length > _maxStored * 2) {
      items.removeRange(_maxStored * 2, items.length);
    }

    unreadCount.value++;
    _bump();
    _persist();
  }

  // 👇 đánh dấu đã đọc tất cả
  static void markAllRead() {
    for (final n in items) {
      n.isRead = true;
    }
    unreadCount.value = 0;
    _bump();
    _persist();
  }

  // 👇 mark từng cái
  static void markRead(String id) {
    final item = items.firstWhere((e) => e.id == id);
    if (!item.isRead) {
      item.isRead = true;
      unreadCount.value = unreadCount.value - 1;
    }
    _bump();
    _persist();
  }

  // 👇 xoá 1 thông báo (vuốt để xoá)
  static void remove(String id) {
    final index = items.indexWhere((e) => e.id == id);
    if (index == -1) return;
    final wasUnread = !items[index].isRead;
    items.removeAt(index);
    if (wasUnread && unreadCount.value > 0) {
      unreadCount.value = unreadCount.value - 1;
    }
    _bump();
    _persist();
  }

  // 👇 xoá toàn bộ
  static void clearAll() {
    items.clear();
    unreadCount.value = 0;
    _bump();
    _persist();
  }
}
