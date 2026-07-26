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
import '../services/app_globals.dart';
import 'set_dob_page.dart';
import 'set_password_page.dart';
import 'age_restricted_page.dart';



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

  // 🆕 AGE-GATE: dùng chung cho cả đăng nhập mật khẩu lẫn vân tay/Face ID.
  // Trước đây 2 luồng này push thẳng MainPage sau khi có JWT, bỏ qua hẳn
  // bước check must_set_dob/age_restricted (chỉ Splash mới check) — nghĩa
  // là 1 tài khoản đã bị đánh dấu age_restricted vẫn login lại được nếu
  // gõ tay mật khẩu hoặc dùng vân tay. Gọi /me ở đây để chặn đúng chỗ.
  Future<void> _navigateAfterLogin() async {
    if (!mounted) return;

    final response = await fetchMeSafe();
    final me = response.data;

    if (!mounted) return;

    if (response.result == MeResult.success && me != null) {
      if (me['age_restricted'] == true) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const AgeRestrictedPage()),
        );
        return;
      }
      if (me['must_set_dob'] == true) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const SetDobPage()),
        );
        return;
      }
      if (me['must_set_password'] == true) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const SetPasswordPage()),
        );
        return;
      }
    }

    // Lỗi mạng tạm thời hoặc thiếu field -> vẫn cho vào MainPage như cũ,
    // để không chặn nhầm user hợp lệ chỉ vì /me lag; Splash lần mở app
    // kế tiếp sẽ check lại đầy đủ.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const MainPage()),
    );
  }


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


  /// 🆕 Gọi /wp-json/spiritwebs/v1/me và lưu "user_data" theo đúng 1 schema
  /// chuẩn duy nhất: {id, username, display_name, email, avatar_url}.
  /// Đây là hàm DUY NHẤT trong app nên dùng để cache lại thông tin user sau
  /// khi login — mọi nơi khác (UserHelper, MainPage, PresenceService...) chỉ
  /// cần đọc từ "user_data" theo đúng 5 field này, không tự map field khác
  /// nhau nữa (trước đây mỗi trang tự đọc display_name/name/username/slug
  /// riêng, dẫn tới hiện "-"/"Khách" không nhất quán giữa các màn hình).
  ///
  /// Nếu /me lỗi (mất mạng, timeout...), KHÔNG để user_data trống trơn —
  /// giữ lại tên tối thiểu đã có từ bước đăng nhập, để ít nhất còn hiện
  /// đúng tên thay vì "-".
  Future<void> _fetchAndCacheFullUser(
    String token, {
    required String fallbackId,
    required String fallbackName,
  }) async {
    try {
      final res = await http.get(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/me"),
        headers: {"Authorization": "Bearer $token"},
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final me = jsonDecode(res.body) as Map<String, dynamic>;
        if (me['logged_in'] == true) {
          await StorageHelper.write("user_data", jsonEncode({
            "id": (me['id'] ?? fallbackId).toString(),
            "username": me['username'] ?? '',
            "display_name": (me['nickname'] ?? fallbackName).toString(),
            "email": me['email'] ?? '',
            "avatar_url": me['avatar_url'] ?? '',
          }));
          return;
        }
      }
      debugPrint("⚠️ /me trả về không hợp lệ (status=${res.statusCode}), giữ nguyên user_data tạm.");
    } catch (e) {
      debugPrint("⚠️ Gọi /me sau login lỗi (giữ nguyên user_data tạm, không chặn đăng nhập): $e");
    }
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

        // 🆕 FIX (username/avatar lúc có lúc không ở chat/map/thông báo):
        // trước đây chỗ này ghi "user_data" TẠM 1 lần với field rời rạc
        // (email/slug/name, không có display_name/avatar_url), rồi mới ghi
        // đè lần 2 bằng /custom/v1/user/{id} — nhưng API đó KHÔNG trả
        // avatar_url, và nếu request lỗi/mất mạng thì app kẹt luôn ở bản
        // ghi tạm thiếu display_name. Mỗi trang trong app lại tự fallback
        // khác nhau -> chỗ hiện "-", chỗ hiện "Khách", chỗ hiện tên đúng.
        //
        // Giờ dùng 1 nguồn DUY NHẤT: token trước, rồi gọi thẳng
        // /wp-json/spiritwebs/v1/me (endpoint đã có sẵn avatar_url với ảnh
        // mặc định tử tế) và lưu xuống "user_data" theo đúng 1 schema cố
        // định: {id, username, display_name, email, avatar_url}. Mọi trang
        // khác (UserHelper, MainPage, PresenceService...) đều đọc từ đúng
        // schema này, không còn lệch nhau nữa.
        await StorageHelper.write("jwt_token", data["token"]);
        await StorageHelper.write("token_time", DateTime.now().toIso8601String());

        // Ghi tạm 1 bản tối thiểu ngay lập tức (phòng trường hợp app bị
        // tắt/crash trước khi gọi xong /me) — nhưng vẫn đủ 5 field theo
        // đúng schema chuẩn, không để thiếu display_name như code cũ.
        final fallbackName = (data["user_nicename"] ?? data["user_email"] ?? "Người dùng").toString();
        await StorageHelper.write("user_data", jsonEncode({
          "id": "",
          "username": data["user_nicename"] ?? "",
          "display_name": fallbackName,
          "email": data["user_email"] ?? "",
          "avatar_url": "",
        }));

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

          // ✅ Nguồn chuẩn duy nhất cho user_data: /me — có avatar_url với
          // fallback tử tế, và "nickname" (ưu tiên nickname riêng, fallback
          // display_name) dùng làm display_name cho app.
          await _fetchAndCacheFullUser(token, fallbackId: userId, fallbackName: fallbackName);
        }


        if (!mounted) return;
        AdminActivityService().connect(); // không cần await
        await _navigateAfterLogin();
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
      await _navigateAfterLogin();
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