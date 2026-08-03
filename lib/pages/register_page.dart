import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'login_page.dart';
import '../config/app_config.dart';
import 'beer_background.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();

  bool _loading = false;
  bool _showPassword = false;
  bool _showConfirm = false;
  String? _errorMessage;
  String? _successMessage;

  // GlobalKey để gọi thẳng BlackHoleBackgroundState.kickAt(...) từ Listener
  // ngoài cùng — form đăng ký (TextField, nút, vùng cuộn) nằm đè lên trên
  // nên bình thường sẽ nuốt hết mọi sự kiện chạm trước khi nó lọt xuống
  // GestureDetector bên trong background.
  final GlobalKey<BlackHoleBackgroundState> _bgKey =
  GlobalKey<BlackHoleBackgroundState>();

  // 🆕 AGE-GATE: ngày sinh bắt buộc, app xoay quanh nhậu/rượu bia nên
  // phải xác minh tuổi trước khi tạo tài khoản (yêu cầu Apple/Google).
  DateTime? _dateOfBirth;

  String _formatDob(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return "${d.year}-$mm-$dd";
  }

  String _displayDob(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return "$dd/$mm/${d.year}";
  }

  Future<void> _pickDateOfBirth() async {
    final now = DateTime.now();
    final initial = DateTime(now.year - 18, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? initial,
      firstDate: DateTime(now.year - 100),
      lastDate: now, // không cho chọn ngày tương lai
      helpText: "Chọn ngày sinh",
    );
    if (picked != null) {
      setState(() => _dateOfBirth = picked);
    }
  }

  Future<void> _register() async {
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final confirm = _confirmController.text.trim();

    if (username.isEmpty || email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = "⚠️ Vui lòng nhập đầy đủ thông tin");
      return;
    }

    if (password != confirm) {
      setState(() => _errorMessage = "⚠️ Mật khẩu xác nhận không khớp");
      return;
    }

    // 🆕 AGE-GATE
    if (_dateOfBirth == null) {
      setState(() => _errorMessage = "⚠️ Vui lòng chọn ngày sinh");
      return;
    }

    final age = DateTime.now().difference(_dateOfBirth!).inDays / 365.25;
    if (age < 18) {
      setState(() => _errorMessage = "🔞 Ứng dụng chỉ dành cho người từ 18 tuổi trở lên.");
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final url = Uri.parse("${AppConfig.webDomain}/wp-json/wp/v2/users/register");

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        "username": username,
        "email": email,
        "password": password,
        "date_of_birth": _formatDob(_dateOfBirth!),
      }),
    );

    debugPrint(">>> [DEBUG] Register Response: ${response.statusCode} - ${response.body}");

    if (response.statusCode == 200 || response.statusCode == 201) {
      setState(() {
        _successMessage = "✅ Đăng ký thành công! Vui lòng đăng nhập.";
      });

      await Future.delayed(const Duration(seconds: 2));

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    } else {
      String msg = "❌ Lỗi đăng ký. Vui lòng thử lại.";
      try {
        final data = jsonDecode(response.body);
        // 🆕 error_code == 'underage' -> hiện rõ lý do bị từ chối thay vì
        // thông báo lỗi chung chung, để user hiểu ngay không phải do nhập sai.
        if (data["error_code"] == "underage") {
          msg = "🔞 " + (data["message"] ?? "Ứng dụng chỉ dành cho người từ 18 tuổi trở lên.");
        } else {
          msg = data["message"] ?? msg;
        }
      } catch (_) {}
      setState(() {
        _errorMessage = msg;
      });
    }

    setState(() {
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _bgKey.currentState?.kickAt(event.position),
        onPointerMove: (event) =>
            _bgKey.currentState?.kickAt(event.position, strength: 0.4),
        child: Stack(
          children: [
            // 1️⃣ Background — animated starfield + drifting black hole
            Positioned.fill(
              child: BlackHoleBackground(key: _bgKey),
            ),
            // 2️⃣ Overlay mờ
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF0D47A1).withOpacity(0.55),
                    const Color(0xFFF57C00).withOpacity(0.45),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            // 3️⃣ Form đăng ký
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Đăng ký",
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 30),
                    TextField(
                      controller: _usernameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "Tên đăng nhập",
                        labelStyle: TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _emailController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: "Email",
                        labelStyle: TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 🆕 AGE-GATE: chọn ngày sinh, bắt buộc
                    GestureDetector(
                      onTap: _pickDateOfBirth,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          border: Border.all(color: Colors.white54),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.cake_outlined, color: Colors.white70, size: 20),
                            const SizedBox(width: 10),
                            Text(
                              _dateOfBirth == null
                                  ? "Ngày sinh (bắt buộc, từ 18 tuổi)"
                                  : "Ngày sinh: ${_displayDob(_dateOfBirth!)}",
                              style: TextStyle(
                                color: _dateOfBirth == null ? Colors.white70 : Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      obscureText: !_showPassword,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Mật khẩu",
                        labelStyle: const TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _showPassword ? Icons.visibility_off : Icons.visibility,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              _showPassword = !_showPassword;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmController,
                      obscureText: !_showConfirm,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Nhập lại mật khẩu",
                        labelStyle: const TextStyle(color: Colors.white),
                        filled: true,
                        fillColor: Colors.white24,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _showConfirm ? Icons.visibility_off : Icons.visibility,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            setState(() {
                              _showConfirm = !_showConfirm;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_errorMessage != null)
                      Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
                    if (_successMessage != null)
                      Text(_successMessage!, style: const TextStyle(color: Colors.green)),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _loading ? null : _register,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: _loading
                          ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                          : const Text("Đăng ký"),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (_) => const LoginPage()),
                        );
                      },
                      child: const Text(
                        "Đã có tài khoản? Đăng nhập",
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}