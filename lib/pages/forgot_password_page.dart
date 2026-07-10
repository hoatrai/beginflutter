import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import 'login_page.dart';

/// Flow "Quên mật khẩu":
/// Bước 1: nhập username/email -> gọi /forgot-password -> server gửi OTP qua email.
/// Bước 2: nhập OTP + mật khẩu mới -> gọi /reset-password -> xong quay về Login.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final TextEditingController _identifierController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  bool _loading = false;
  bool _otpSent = false; // đã chuyển sang bước 2 chưa
  bool _showPassword = false;
  String? _errorMessage;
  String? _infoMessage;

  Future<void> _requestOtp() async {
    final identifier = _identifierController.text.trim();
    if (identifier.isEmpty) {
      setState(() => _errorMessage = "⚠️ Vui lòng nhập tên đăng nhập hoặc email");
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/forgot-password"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"username_or_email": identifier}),
      );

      if (response.statusCode == 200) {
        setState(() {
          _otpSent = true;
          _infoMessage = "📩 Nếu tài khoản tồn tại, mã xác nhận đã được gửi tới email của bạn.";
        });
      } else {
        setState(() => _errorMessage = "❌ Không thể gửi yêu cầu. Vui lòng thử lại.");
      }
    } catch (e) {
      setState(() => _errorMessage = "⚠️ Lỗi kết nối: $e");
    }

    setState(() => _loading = false);
  }

  Future<void> _resetPassword() async {
    final otp = _otpController.text.trim();
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

    if (otp.isEmpty || newPassword.isEmpty) {
      setState(() => _errorMessage = "⚠️ Vui lòng nhập mã xác nhận và mật khẩu mới");
      return;
    }
    if (newPassword.length < 6) {
      setState(() => _errorMessage = "⚠️ Mật khẩu mới tối thiểu 6 ký tự");
      return;
    }
    if (newPassword != confirmPassword) {
      setState(() => _errorMessage = "⚠️ Mật khẩu xác nhận không khớp");
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/reset-password"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "username_or_email": _identifierController.text.trim(),
          "otp": otp,
          "new_password": newPassword,
        }),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        if (!mounted) return;
        setState(() => _infoMessage = "✅ Đặt lại mật khẩu thành công! Đang chuyển về đăng nhập...");
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
        return;
      } else {
        setState(() => _errorMessage = "❌ ${data['message'] ?? 'Mã xác nhận không đúng hoặc đã hết hạn.'}");
      }
    } catch (e) {
      setState(() => _errorMessage = "⚠️ Lỗi kết nối: $e");
    }

    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SizedBox.expand(
            child: Image.asset("assets/images/background.png", fit: BoxFit.cover),
          ),
          Container(color: Colors.black.withOpacity(0.3)),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _otpSent ? "Nhập mã xác nhận" : "Quên mật khẩu",
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _otpSent
                        ? "Kiểm tra email và nhập mã 6 số cùng mật khẩu mới."
                        : "Nhập tên đăng nhập hoặc email đã đăng ký, hệ thống sẽ gửi mã xác nhận tới email của bạn.",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 24),

                  if (!_otpSent) ...[
                    TextField(
                      controller: _identifierController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "Tên đăng nhập hoặc Email",
                        labelStyle: TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "Mã xác nhận (6 số)",
                        labelStyle: TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: OutlineInputBorder(),
                        counterStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _newPasswordController,
                      obscureText: !_showPassword,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Mật khẩu mới",
                        labelStyle: const TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility, color: Colors.white),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmPasswordController,
                      obscureText: !_showPassword,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "Nhập lại mật khẩu mới",
                        labelStyle: TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),
                  if (_errorMessage != null)
                    Text(_errorMessage!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  if (_infoMessage != null)
                    Text(_infoMessage!, style: const TextStyle(color: Colors.greenAccent), textAlign: TextAlign.center),
                  const SizedBox(height: 20),

                  ElevatedButton(
                    onPressed: _loading ? null : (_otpSent ? _resetPassword : _requestOtp),
                    style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                    child: _loading
                        ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                        : Text(_otpSent ? "Đặt lại mật khẩu" : "Gửi mã xác nhận"),
                  ),

                  if (_otpSent) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () => setState(() {
                        _otpSent = false;
                        _errorMessage = null;
                        _infoMessage = null;
                      }),
                      child: const Text("Gửi lại mã / đổi email khác", style: TextStyle(color: Colors.white)),
                    ),
                  ],

                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const LoginPage()),
                      );
                    },
                    child: const Text("← Quay lại đăng nhập", style: TextStyle(color: Colors.white)),
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