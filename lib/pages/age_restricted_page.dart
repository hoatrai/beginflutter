import 'package:flutter/material.dart';
import '../helpers/storage_helper.dart';
import 'login_page.dart';

/// 🆕 AGE-GATE: hiện khi `/me` trả `age_restricted: true` (tài khoản đã
/// khai DOB và dưới 18 tuổi). Tự xoá phiên đăng nhập hiện tại (jwt_token
/// + refresh_token) NGAY khi vào trang này, để dù có bấm "Đăng nhập lại"
/// hay đăng nhập vân tay cũng không quay lại MainPage được — server vẫn
/// luôn trả age_restricted=true cho tài khoản này ở mọi lần đăng nhập
/// tiếp theo.
class AgeRestrictedPage extends StatefulWidget {
  const AgeRestrictedPage({super.key});

  @override
  State<AgeRestrictedPage> createState() => _AgeRestrictedPageState();
}

class _AgeRestrictedPageState extends State<AgeRestrictedPage> {
  @override
  void initState() {
    super.initState();
    _wipeSession();
  }

  Future<void> _wipeSession() async {
    await StorageHelper.delete("jwt_token");
    await StorageHelper.delete("refresh_token");
    await StorageHelper.delete("user_id");
    await StorageHelper.delete("user_data");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.no_drinks_outlined, color: Colors.redAccent, size: 64),
                const SizedBox(height: 20),
                const Text(
                  "Không đủ điều kiện sử dụng",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  "Ứng dụng có nội dung liên quan đến rượu bia và chỉ dành cho người từ 18 tuổi trở lên. "
                      "Tài khoản này không thể tiếp tục sử dụng ứng dụng.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 28),
                OutlinedButton(
                  onPressed: () {
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                          (route) => false,
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white38),
                    foregroundColor: Colors.white70,
                  ),
                  child: const Text("Về màn hình đăng nhập"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}