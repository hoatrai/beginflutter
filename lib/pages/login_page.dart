import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:local_auth/local_auth.dart';
import 'profile_page.dart';
import 'shop_page.dart';
import '../helpers/storage_helper.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final LocalAuthentication auth = LocalAuthentication();

  bool _loading = false;
  String? _errorMessage;

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    debugPrint(">>> [DEBUG] Bắt đầu login bằng username/password");

    final url = Uri.parse("https://spiritwebs.com/wp-json/jwt-auth/v1/token");
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        "username": _usernameController.text.trim(),
        "password": _passwordController.text.trim(),
      }),
    );

    debugPrint(">>> [DEBUG] Response status: ${response.statusCode}");
    debugPrint(">>> [DEBUG] Response body: ${response.body}");

    if (response.statusCode == 200) {
      final data = json.decode(response.body);

      // ✅ Lưu token + thông tin user
      await StorageHelper.write("jwt_token", data["token"]);
      await StorageHelper.write("token_time", DateTime.now().toIso8601String());

      // ✅ Lưu thêm email + username (nicename) + display_name
      await StorageHelper.write("user_email", data["user_email"] ?? "");
      await StorageHelper.write("user_nicename", data["user_nicename"] ?? "");
      await StorageHelper.write("user_display_name", data["user_display_name"] ?? "");


      debugPrint(">>> [DEBUG] Đã lưu token + email + username");

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ProfilePage()),
      );
    } else {
      setState(() {
        _errorMessage = "❌ Sai username hoặc password!";
      });
    }

    setState(() {
      _loading = false;
    });
  }

  Future<void> _loginWithBiometrics() async {
    try {
      debugPrint(">>> [DEBUG] Bắt đầu login bằng vân tay/Face ID");

      final didAuthenticate = await auth.authenticate(
        localizedReason: 'Xác thực bằng vân tay/Face ID để đăng nhập',
        options: const AuthenticationOptions(biometricOnly: true),
      );

      debugPrint(">>> [DEBUG] Kết quả authenticate: $didAuthenticate");
      if (!didAuthenticate) return;

      final token = await StorageHelper.read("jwt_token");
      final tokenTime = await StorageHelper.read("token_time");

      debugPrint(">>> [DEBUG] Token đọc từ storage: $token");
      debugPrint(">>> [DEBUG] Token time đọc từ storage: $tokenTime");

      if (token == null || tokenTime == null) {
        setState(() {
          _errorMessage = "⚠️ Chưa có token. Vui lòng login bằng tài khoản trước.";
        });
        return;
      }

      final createdAt = DateTime.tryParse(tokenTime);
      if (createdAt == null) {
        setState(() {
          _errorMessage = "⚠️ Thời gian token không hợp lệ. Vui lòng login lại.";
        });
        return;
      }

      if (DateTime.now().difference(createdAt).inHours >= 1) {
        setState(() {
          _errorMessage = "⚠️ Token đã hết hạn. Vui lòng login lại bằng tài khoản.";
        });
        return;
      }

      // Token hợp lệ -> chuyển sang ProfilePage
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ProfilePage()),
      );

    } catch (e) {
      setState(() {
        _errorMessage = "Lỗi xác thực: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blue.shade50,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Login",
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 30),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: "Username"),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: "Password"),
              ),
              const SizedBox(height: 20),
              if (_errorMessage != null)
                Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _loading ? null : _login,
                child: _loading
                    ? const CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2)
                    : const Text("Login"),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.fingerprint, size: 28),
                label: const Text("Login with Fingerprint / Face ID"),
                onPressed: _loginWithBiometrics,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
