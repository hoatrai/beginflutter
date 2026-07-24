import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart' as shimmer;

import '../helpers/storage_helper.dart';
import '../main.dart';
import '../config/app_config.dart';
import 'age_restricted_page.dart';

/// 🆕 AGE-GATE: dành cho tài khoản CŨ (tạo trước khi có tính năng này),
/// chưa từng khai ngày sinh. Splash điều hướng vào đây khi `/me` trả
/// `must_set_dob: true`. Không cho vào MainPage cho tới khi khai DOB
/// thành công; nếu <18 tuổi thì chuyển sang AgeRestrictedPage (chặn
/// vĩnh viễn), không cho quay lại thử DOB khác.
class SetDobPage extends StatefulWidget {
  const SetDobPage({super.key});

  @override
  State<SetDobPage> createState() => _SetDobPageState();
}

class _SetDobPageState extends State<SetDobPage> {
  DateTime? _dateOfBirth;
  bool loading = false;

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
      lastDate: now,
      helpText: "Chọn ngày sinh",
    );
    if (picked != null) {
      setState(() => _dateOfBirth = picked);
    }
  }

  Future<void> _showError(String message) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 30),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.blue.shade900.withOpacity(.95),
                  Colors.orange.shade700.withOpacity(.9),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.4),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                )
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 48),
                const SizedBox(height: 12),
                const Text(
                  "Có lỗi xảy ra",
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Colors.orange, Colors.red]),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text("ĐÓNG", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> submit() async {
    if (_dateOfBirth == null) {
      await _showError("Vui lòng chọn ngày sinh");
      return;
    }

    setState(() => loading = true);

    final token = await StorageHelper.read("jwt_token");

    http.Response res;
    try {
      res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/set-dob"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({"date_of_birth": _formatDob(_dateOfBirth!)}),
      );
    } catch (_) {
      if (mounted) setState(() => loading = false);
      await _showError("Không kết nối được máy chủ");
      return;
    }

    if (!mounted) return;
    setState(() => loading = false);

    if (res.statusCode == 200) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MainPage()),
      );
      return;
    }

    String errorCode = '';
    String msg = "Lỗi không xác định";
    try {
      final data = jsonDecode(res.body);
      msg = data['message'] ?? msg;
      errorCode = data['code'] ?? data['error_code'] ?? '';
    } catch (_) {}

    // 🆕 Dưới 18 tuổi -> chặn vĩnh viễn, không cho quay lại nhập DOB khác.
    if (res.statusCode == 403 || errorCode == 'underage') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AgeRestrictedPage()),
      );
      return;
    }

    await _showError(msg);
  }

  Widget _buildButton() {
    if (!loading) {
      return GestureDetector(
        onTap: submit,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Colors.orange, Colors.red]),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Text(
            "XÁC NHẬN",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
      );
    }

    return shimmer.Shimmer.fromColors(
      baseColor: Colors.white.withOpacity(.2),
      highlightColor: Colors.white.withOpacity(.4),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.3),
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.blue.shade900.withOpacity(.9),
              Colors.orange.shade700.withOpacity(.8),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Card(
                elevation: 8,
                color: Colors.white.withOpacity(.15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(
                        child: Icon(Icons.cake_outlined, color: Colors.white, size: 40),
                      ),
                      const SizedBox(height: 12),
                      const Center(
                        child: Text(
                          "Xác nhận ngày sinh",
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Ứng dụng có nội dung liên quan đến rượu bia, chỉ dành cho người từ 18 tuổi trở lên. "
                            "Vui lòng xác nhận ngày sinh để tiếp tục sử dụng.",
                        style: TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 24),
                      GestureDetector(
                        onTap: loading ? null : _pickDateOfBirth,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.calendar_today, color: Colors.white70, size: 18),
                              const SizedBox(width: 10),
                              Text(
                                _dateOfBirth == null
                                    ? "Chọn ngày sinh"
                                    : _displayDob(_dateOfBirth!),
                                style: TextStyle(
                                  color: _dateOfBirth == null ? Colors.white70 : Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildButton(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}