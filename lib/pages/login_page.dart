import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:local_auth/local_auth.dart';
import '../helpers/storage_helper.dart';
import 'register_page.dart';
import '../main.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';
import 'forgot_password_page.dart';
import '../services/admin_activity_service.dart';



class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final LocalAuthentication _auth = LocalAuthentication();

  bool _loading = false;
  bool _showPassword = false;
  String? _errorMessage;


  Future<void> sendFcmTokenAfterLogin(int userId) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;

    await http.post(
      Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/save-fcm-token"),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        "user_id": userId,
        "fcm_token": token,
        "device": "flutter"
      }),
    );

    print("✅ FCM token sent for user $userId");
  }


  // 🔹 Login bằng username/password
  Future<void> _login() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/jwt-auth/v1/token"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "username": _usernameController.text.trim(),
          "password": _passwordController.text.trim(),
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final userData = {
          "email": data["user_email"] ?? "",
          "slug": data["user_nicename"] ?? "",
          "name": data["username"] ?? "",
        };

        await StorageHelper.write("jwt_token", data["token"]);
        await StorageHelper.write("token_time", DateTime.now().toIso8601String());
        await StorageHelper.write("user_data", jsonEncode(userData));

// 🔹 Trích user_id trực tiếp từ JWT và lưu vào Storage
        final token = data["token"];
        final parts = token.split('.');
        if (parts.length == 3) {
          final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
          final Map<String, dynamic> payloadMap = json.decode(payload);
          final userId = payloadMap['data']['user']['id'].toString();
          await StorageHelper.write("user_id", userId);
          debugPrint('>>> [DEBUG] Extracted user_id = $userId');

          // luu token firebase
          await sendFcmTokenAfterLogin(int.parse(userId));

          // 🆕 Xin thêm 1 refresh_token (hạn 30 ngày) để dành cho đăng
          // nhập vân tay/Face ID sau này — không đổi gì luồng đăng nhập
          // mật khẩu ở trên, chỉ gọi thêm 1 API kèm JWT vừa nhận được.
          try {
            final resRefresh = await http.post(
              Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/issue-refresh-token"),
              headers: {"Authorization": "Bearer $token"},
            );
            if (resRefresh.statusCode == 200) {
              final refreshData = jsonDecode(resRefresh.body);
              if (refreshData["refresh_token"] != null) {
                await StorageHelper.write("refresh_token", refreshData["refresh_token"]);
              }
            }
          } catch (e) {
            debugPrint("issue-refresh-token lỗi (bỏ qua, không chặn đăng nhập): $e");
          }




          // ✅ Chỗ này là viết đoạn gọi API user full
          final resUser = await http.get(
            Uri.parse("${AppConfig.webDomain}/wp-json/custom/v1/user/$userId"),
            headers: {"Authorization": "Bearer $token"},
          );

          if (resUser.statusCode == 200) {
            final userFullData = jsonDecode(resUser.body);
            await StorageHelper.write("user_data", jsonEncode(userFullData));
          }

        }


        if (!mounted) return;
        AdminActivityService().connect(); // không cần await
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainPage()),
        );
      }else {
        setState(() {
          _errorMessage = "❌ Sai tên đăng nhập hoặc mật khẩu!";
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = "⚠️ Lỗi kết nối: $e";
      });
    }

    setState(() {
      _loading = false;
    });
  }

  Widget _buildShimmerButton() {
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: shimmer.Shimmer.fromColors(
        baseColor: Colors.orange.shade300,
        highlightColor: Colors.orange.shade100,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.orange,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            "Đang đăng nhập...",
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  // 🔹 Login bằng vân tay/Face ID
  Future<void> _loginWithBiometrics() async {
    try {
      final didAuthenticate = await _auth.authenticate(
        localizedReason: 'Xác thực bằng vân tay/Face ID để đăng nhập',
        options: const AuthenticationOptions(biometricOnly: true),
      );

      if (!didAuthenticate) return;

      final refreshToken = await StorageHelper.read("refresh_token");
      if (refreshToken == null) {
        setState(() {
          _errorMessage = "⚠️ Chưa có phiên đăng nhập trên máy này. Vui lòng đăng nhập bằng tài khoản trước.";
        });
        return;
      }

      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/refresh-token"),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"refresh_token": refreshToken}),
      );

      if (response.statusCode != 200) {
        setState(() {
          _errorMessage = "⚠️ Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại bằng tài khoản.";
        });
        return;
      }

      final data = json.decode(response.body);
      await StorageHelper.write("jwt_token", data["token"]);
      await StorageHelper.write("token_time", DateTime.now().toIso8601String());

      if (!mounted) return;
      AdminActivityService().connect(); // không cần await
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MainPage()),
      );
    } catch (e) {
      setState(() {
        _errorMessage = "⚠️ Lỗi xác thực: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1️⃣ Background
          SizedBox.expand(
            child: Image.asset(
              "assets/images/background.png",
              fit: BoxFit.cover,
            ),
          ),
          // 2️⃣ Overlay mờ
          Container(color: Colors.black.withOpacity(0.3)),
          // 3️⃣ Form login
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    "Đăng nhập",
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
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _loading
                          ? null
                          : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
                        );
                      },
                      child: const Text(
                        "Quên mật khẩu?",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (_errorMessage != null)
                    Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _loading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    child: _loading
                        ? shimmer.Shimmer.fromColors(
                      baseColor: Colors.white,
                      highlightColor: Colors.white.withOpacity(0.4),
                      child: const Text(
                        "Đang đăng nhập...",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    )
                        : const Text("Đăng nhập"),

                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white),
                    ),
                    icon: const Icon(Icons.fingerprint, size: 28),
                    label: const Text("Đăng nhập bằng vân tay / Face ID"),
                    onPressed: _loginWithBiometrics,
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const RegisterPage()),
                      );
                    },
                    child: const Text(
                      "👉 Chưa có tài khoản? Đăng ký ngay",
                      style: TextStyle(color: Colors.white),
                    ),
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