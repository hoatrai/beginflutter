import 'package:flutter/material.dart';

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
}

class NotificationStore {
  static final List<AppNotification> items = [];

  // 👇 số chưa đọc
  static final ValueNotifier<int> unreadCount = ValueNotifier(0);

  // 👇 thêm notification
  static void add({
    required String title,
    required String body,
    String? type,
    Map<String, dynamic>? data,
  }) {
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

    unreadCount.value++;
  }

  // 👇 đánh dấu đã đọc tất cả
  static void markAllRead() {
    for (final n in items) {
      n.isRead = true;
    }
    unreadCount.value = 0;
  }

  // 👇 mark từng cái
  static void markRead(String id) {
    final item = items.firstWhere((e) => e.id == id);
    if (!item.isRead) {
      item.isRead = true;
      unreadCount.value = unreadCount.value - 1;
    }
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
  }

  // 👇 xoá toàn bộ
  static void clearAll() {
    items.clear();
    unreadCount.value = 0;
  }
}