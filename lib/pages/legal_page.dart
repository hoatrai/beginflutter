import 'package:flutter/material.dart';

/// Một mục nội dung trong trang pháp lý (Chính sách bảo mật / Điều khoản).
/// - [heading]: tiêu đề mục (để trống nếu là đoạn giới thiệu đầu trang).
/// - [body]: nội dung, có thể xuống dòng bằng "\n".
class LegalSection {
  final String? heading;
  final String body;

  const LegalSection({this.heading, required this.body});
}

/// Trang hiển thị nội dung pháp lý (Chính sách bảo mật / Điều khoản sử dụng),
/// dùng chung tone màu & phong cách "glass" với ProfilePage: nền gradient
/// xanh navy → cam san hô, các khối nội dung dạng thẻ kính mờ bo góc.
class LegalPage extends StatelessWidget {
  final String title;
  final List<LegalSection> sections;

  // Cùng bộ màu với ProfilePage — nếu app có ThemeData/AppColors dùng chung,
  // có thể thay 2 dòng này bằng Theme.of(context) hoặc AppColors tương ứng.
  static const Color primaryBlue = Color(0xFF1E3A8A);
  static const Color accentOrange = Color(0xFFFF7F50);

  const LegalPage({
    super.key,
    required this.title,
    required this.sections,
  });

  // Đoạn đầu tiên (không có heading) được coi là phần giới thiệu.
  LegalSection? get _intro =>
      sections.isNotEmpty && sections.first.heading == null
          ? sections.first
          : null;

  List<LegalSection> get _body =>
      _intro == null ? sections : sections.sublist(1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue, accentOrange],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            primaryBlue.withOpacity(0.6),
                            accentOrange.withOpacity(0.6),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.25),
                        ),
                      ),
                      child: const Icon(Icons.shield_outlined,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (_intro != null) ...[
                  _GlassCard(
                    child: Text(
                      _intro!.body,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.6,
                        color: Colors.white.withOpacity(0.85),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                ..._body.asMap().entries.map((entry) {
                  final index = entry.key + 1;
                  final section = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (section.heading != null)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [primaryBlue, accentOrange],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                  ),
                                  child: Text(
                                    '$index',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      section.heading!,
                                      style: const TextStyle(
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          if (section.heading != null)
                            const SizedBox(height: 10),
                          Text(
                            section.body,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.65,
                              color: Colors.white.withOpacity(0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thẻ kính mờ (glass card) dùng chung, đồng bộ với khối thông tin
/// trong ProfilePage: nền trắng mờ 12%, viền trắng mờ 20%, bo góc 20.
class _GlassCard extends StatelessWidget {
  final Widget child;

  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withOpacity(0.12),
        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}