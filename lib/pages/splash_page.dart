import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../helpers/storage_helper.dart';
import '../app_globals.dart';
import 'login_page.dart';
import '../main.dart';
import 'set_password_page.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';
import '../services/admin_activity_service.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  bool _showRetry = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _goSetPassword() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const SetPasswordPage()),
    );
  }

  Future<void> _init() async {
    if (mounted) {
      setState(() => _showRetry = false);
    }

    final token = await StorageHelper.read("jwt_token");

    if (token != null) {
      final response = await fetchMeSafe();

      switch (response.result) {
        case MeResult.success:
          final me = response.data!;

          // ✅ LƯU LẠI USER STATE (RẤT QUAN TRỌNG)
          await StorageHelper.write("user_id", me['id'].toString());
          await StorageHelper.write("user_data", jsonEncode(me));

          if (me['must_set_password'] == true) {
            _goSetPassword();
            return;
          }

          _goMain(
            userData: me,
            userId: int.tryParse(me['id'].toString()) ?? 0,
          );
          return;

        case MeResult.unauthorized:
        // Token thực sự hết hạn/invalid -> chỉ trường hợp này mới xoá & bắt login lại
        // ⚠️ KHÔNG dùng StorageHelper.clear() ở đây vì nó xoá SẠCH toàn bộ
        // secure storage, kể cả refresh_token (dùng cho đăng nhập vân tay).
        // Chỉ xoá đúng các key thuộc phiên JWT hiện tại.
          await StorageHelper.delete("jwt_token");
          await StorageHelper.delete("user_id");
          await StorageHelper.delete("user_data");
          _goLogin();
          return;

        case MeResult.networkError:
        // Lỗi mạng/server tạm thời -> KHÔNG xoá token.
        // Nếu có cache user_data từ trước, vẫn cho vào app để không làm phiền user.
          final cachedUserData = await StorageHelper.read("user_data");
          if (cachedUserData != null) {
            debugPrint("⚠️ fetchMe lỗi mạng tạm thời, dùng cache để vào app.");
            Map<String, dynamic>? cachedMap;
            try {
              final decoded = jsonDecode(cachedUserData);
              if (decoded is Map<String, dynamic>) cachedMap = decoded;
            } catch (_) {}
            final cachedIdString = await StorageHelper.read("user_id");
            _goMain(
              userData: cachedMap,
              userId: int.tryParse(cachedIdString ?? '') ?? 0,
            );
          } else {
            debugPrint("⚠️ fetchMe lỗi mạng tạm thời, không có cache -> hiện nút thử lại.");
            if (mounted) {
              setState(() => _showRetry = true);
            }
          }
          return;
      }
    }

    // ❗ CHỈ guest-login khi KHÔNG có token
    final ok = await _guestLogin();
    if (ok) {
      final guestUserData = await StorageHelper.read("user_data");
      final guestUserId = await StorageHelper.read("user_id");
      Map<String, dynamic>? guestMap;
      try {
        final decoded = jsonDecode(guestUserData ?? '');
        if (decoded is Map<String, dynamic>) guestMap = decoded;
      } catch (_) {}
      _goMain(
        userData: guestMap,
        userId: int.tryParse(guestUserId ?? '') ?? 0,
      );
    } else {
      _goLogin();
    }
  }

  Future<bool> _guestLogin() async {
    try {
      final res = await http
          .post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/guest-login"),
      )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return false;

      final data = jsonDecode(res.body);

      if (data['token'] == null || data['user_id'] == null) return false;

      await StorageHelper.write("jwt_token", data['token']);
      await StorageHelper.write("user_id", data['user_id'].toString());
      await StorageHelper.write("user_data", jsonEncode(data['user']));
      await StorageHelper.write("is_guest", data['is_guest'].toString());

      return true;
    } catch (e) {
      debugPrint("guestLogin error: $e");
      return false;
    }
  }

  void _goMain({Map<String, dynamic>? userData, int? userId}) {
    if (!mounted) return;
    // ✅ Auto-login qua token cũ (cách adminroot vào app hầu hết mọi lần)
    // cũng phải khởi động AdminActivityService — không chỉ lúc gõ tay
    // username/password. Nếu user hiện tại không phải admin, service tự
    // no-op (WordPress trả 403 lúc xin vé) nên gọi vô điều kiện là an toàn.
    AdminActivityService().connect(); // không cần await
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MainPage(
          // 🆕 Truyền thẳng data đã có sẵn ở đây để MainPage khỏi phải
          // đọc lại storage lần 2 -> bỏ hẳn chớp trắng lúc mới vào app.
          initialUserData: userData,
          initialUserId: userId,
        ),
      ),
    );
  }

  void _goLogin() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  Widget _buildLoadingShimmer() {
    return shimmer.Shimmer.fromColors(
      baseColor: Colors.grey.shade800,
      highlightColor: Colors.grey.shade600,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: 160,
            height: 18,
            color: Colors.white,
          ),
          const SizedBox(height: 12),
          Container(
            width: 120,
            height: 14,
            color: Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _buildRetryUI() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.wifi_off, color: Colors.white70, size: 48),
        const SizedBox(height: 16),
        const Text(
          "Không thể kết nối tới máy chủ.\nVui lòng kiểm tra mạng và thử lại.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _init,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            foregroundColor: Colors.white,
          ),
          child: const Text("Thử lại"),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: _showRetry ? _buildRetryUI() : _buildLoadingShimmer(),
      ),
    );
  }
}