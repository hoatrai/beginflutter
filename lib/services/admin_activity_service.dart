// lib/services/admin_activity_service.dart
//
// ============================================================
// 🆕 ADMIN ACTIVITY NOTIFICATION (không lộ nội dung chat)
//
// Chỉ dùng khi user hiện tại đang đăng nhập bằng tài khoản admin.
// Không cần thêm package nào — dùng đúng phoenix_socket đã có sẵn
// trong pubspec.yaml (0.7.6), và navigatorKey có sẵn trong
// services/socket_service.dart để hiện SnackBar toàn app.
//
// Luồng:
//   1. Xin vé (ticket) từ WordPress — POST /nhau/v1/admin/socket-ticket
//      WordPress tự kiểm tra current_user_can('administrator'); nếu
//      không phải admin sẽ trả 403 và service này tự dừng, không kết nối.
//   2. Kết nối Phoenix socket, join channel "admin:activity" bằng vé đó.
//   3. Lắng nghe event "new_message" (chỉ có sender_id/receiver_id/
//      created_at — KHÔNG có nội dung tin nhắn) → hiện SnackBar cho
//      admin biết "có ai vừa nhắn cho ai".
//
// 🆕 FIX (2026-07-20): Ticket dùng 1 lần + TTL 60s. Trước đây connect()
// chỉ xin vé + join ĐÚNG 1 LẦN lúc login. Nếu socket bị rớt bất kỳ lúc
// nào sau đó (mất mạng, app vào nền, server Phoenix restart...), thư
// viện phoenix_socket tự động RECONNECT + tự REJOIN lại channel bằng
// đúng "ticket" cũ đã lưu trong params — nhưng ticket đó đã bị Redis
// GETDEL (dùng 1 lần) hoặc đã hết hạn, nên join luôn bị REFUSED vĩnh
// viễn cho tới khi user tắt app mở lại. Log thực tế đã xác nhận đúng
// hiện tượng này: cùng 1 ticket bị "REFUSED JOIN" lặp lại hàng chục lần.
//
// Cách fix: không dựa vào cơ chế tự rejoin của thư viện nữa. Thay vào
// đó, lắng nghe `socket.openStream` (bắn mỗi khi kết nối MỞ — kể cả lần
// đầu lẫn mọi lần reconnect sau này) → mỗi lần đó đều chủ động xin 1
// ticket MỚI rồi tự join lại channel bằng ticket mới đó.
//
// 🆕 DEBUG (2026-07-20 v2): Thêm log ở đầu connect() + log status code
// / body khi xin ticket thất bại, để xác định chính xác điểm đứt khi
// im lặng hoàn toàn không có log nào cả.
// ============================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:phoenix_socket/phoenix_socket.dart';

import '../config/app_config.dart';
import '../helpers/storage_helper.dart';
import 'socket_service.dart' show navigatorKey; // GlobalKey<NavigatorState> đã có sẵn

class AdminActivityService {
  static final AdminActivityService _instance = AdminActivityService._internal();
  factory AdminActivityService() => _instance;
  AdminActivityService._internal();

  PhoenixSocket? _socket;
  PhoenixChannel? _channel;
  StreamSubscription? _openSub;
  StreamSubscription? _messagesSub;
  bool _connecting = false; // tránh join chồng nếu openStream bắn liên tiếp

  /// Gọi sau khi admin đăng nhập thành công (ví dụ ngay sau
  /// Navigator.pushReplacement trong login_page.dart, hoặc trong
  /// splash_page.dart nếu app auto-login bằng token đã lưu).
  /// Tự động không làm gì nếu user hiện tại không phải admin (WordPress
  /// sẽ trả 403 ở bước xin vé).
  Future<void> connect() async {
    // 🆕 Log đầu tiên: xác nhận connect() có thực sự được gọi hay không,
    // để không phải phụ thuộc vào việc console có bị cuộn mất log cũ.
    debugPrint("🟢 AdminActivityService.connect() ĐƯỢC GỌI");
    _debugToast("🟢 connect() được gọi");

    if (_socket != null) {
      debugPrint("ℹ️ AdminActivityService: đã có socket từ trước, bỏ qua connect() lần này.");
      return; // đã có socket + đang tự lo reconnect qua openStream
    }

    try {
      _socket = PhoenixSocket(AppConfig.websocketUrl);

      // 🆕 Mỗi lần kết nối MỞ (lần đầu hoặc sau khi rớt mạng/restart server
      // rồi tự reconnect), xin ticket MỚI + join lại từ đầu — không tin
      // tưởng cơ chế tự rejoin bằng ticket cũ của thư viện.
      _openSub = _socket!.openStream.listen((_) {
        debugPrint("🔌 AdminActivityService: socket OPENED, xin ve moi + join lai");
        _joinWithFreshTicket();
      });

      await _socket!.connect();
    } catch (e) {
      debugPrint("❌ AdminActivityService connect error: $e");
      await disconnect();
    }
  }

  Future<void> _joinWithFreshTicket() async {
    if (_connecting) return;
    _connecting = true;

    try {
      final ticket = await _fetchTicket();
      if (ticket == null) {
        debugPrint("ℹ️ AdminActivityService: không phải admin hoặc xin vé thất bại, bỏ qua.");
        return;
      }

      // Dọn channel cũ (nếu còn) trước khi join lại bằng ticket mới,
      // tránh giữ 2 channel cùng topic cùng lúc.
      await _messagesSub?.cancel();
      _messagesSub = null;
      try {
        await _channel?.leave();
      } catch (_) {}
      _channel = null;

      if (_socket == null || !(_socket!.isConnected)) {
        debugPrint("⚠️ AdminActivityService: socket chưa sẵn sàng, bỏ qua lần join này.");
        return;
      }

      _channel = _socket!.addChannel(
        topic: 'admin:activity',
        parameters: {'ticket': ticket},
      );

      await _channel!.join().future;
      debugPrint("✅ AdminActivityService: joined admin:activity (ticket mới)");
      _debugToast("✅ ĐÃ JOIN admin:activity thành công!");

      _messagesSub = _channel!.messages.listen((event) {
        if (event.event.toString() == 'new_message') {
          final payload = Map<String, dynamic>.from(event.payload as Map? ?? {});
          _showActivitySnackBar(payload);
        }
      });
    } catch (e) {
      debugPrint("❌ AdminActivityService join error: $e");
      _debugToast("❌ Join LỖI: $e");
      _channel = null;
    } finally {
      _connecting = false;
    }
  }

  Future<String?> _fetchTicket() async {
    final token = await StorageHelper.read("jwt_token");
    if (token == null) {
      debugPrint("⚠️ AdminActivityService: KHÔNG có jwt_token trong storage, bỏ qua xin ticket.");
      return null;
    }

    try {
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/admin/socket-ticket"),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      // 🆕 Log rõ status + body mỗi khi KHÔNG phải 200, để biết chính xác
      // WordPress trả về lỗi gì (403 = không phải admin, 404 = route chưa
      // đăng ký, 500 = lỗi PHP, 502 = Phoenix không phản hồi...).
      if (res.statusCode != 200) {
        debugPrint("⚠️ AdminActivityService: xin ticket THẤT BẠI, status=${res.statusCode}, body=${res.body}");
        _debugToast("⚠️ Xin ticket THẤT BẠI: HTTP ${res.statusCode}");
        return null;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final ticket = data['ticket'] as String?;
      debugPrint("🎫 AdminActivityService: đã nhận ticket = $ticket");
      _debugToast("🎫 Đã nhận ticket, đang join...");
      return ticket;
    } catch (e) {
      debugPrint("❌ AdminActivityService fetchTicket error: $e");
      return null;
    }
  }

  // 🆕 DEBUG TẠM THỜI: hiện thẳng lên màn hình từng bước của luồng
  // connect → xin ticket → join, để khỏi cần mở console/terminal khi
  // test trên điện thoại thật. Xoá hàm này (và các chỗ gọi nó) sau khi
  // đã xác nhận tính năng chạy ổn định.
  void _debugToast(String text) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint("⚠️ _debugToast: navigatorKey.currentContext null, không hiện được: $text");
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: Colors.deepPurple,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showActivitySnackBar(Map<String, dynamic> payload) {
    final senderId = payload['sender_id'];
    final receiverId = payload['receiver_id'];

    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint("⚠️ AdminActivityService: navigatorKey.currentContext null, không hiện được SnackBar.");
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("💬 User $senderId vừa nhắn cho User $receiverId"),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Gọi khi admin logout (chỗ đang xoá jwt_token/user_data trong
  /// StorageHelper lúc logout), để không tiếp tục nhận sự kiện sau khi
  /// đã thoát tài khoản admin.
  Future<void> disconnect() async {
    await _openSub?.cancel();
    _openSub = null;

    await _messagesSub?.cancel();
    _messagesSub = null;

    try {
      await _channel?.leave();
    } catch (_) {}
    _channel = null;

    _socket?.dispose();
    _socket = null;
  }
}

// ============================================================
// CÁCH GẮN VÀO APP (2 chỗ cần sửa) — không đổi so với trước:
//
// 1) pages/login_page.dart — trong _login(), NGAY SAU dòng:
//      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainPage()));
//    thêm phía trên nó:
//      AdminActivityService().connect();
//    (không cần await — chạy nền, không chặn màn hình chuyển trang)
//
// 2) Chỗ xử lý logout hiện có của app (tìm StorageHelper.clear() hoặc
//    StorageHelper.delete("jwt_token")) — thêm ngay trước/sau đó:
//      await AdminActivityService().disconnect();
//
// Không cần sửa gì ở splash_page.dart trừ khi anh muốn tự động connect
// lại mỗi khi app mở lên mà token cũ vẫn còn hạn (auto-login) — nếu
// muốn, thêm AdminActivityService().connect(); vào ngay sau đoạn
// auto-login thành công trong splash_page.dart.
// ============================================================