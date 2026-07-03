import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../helpers/storage_helper.dart';
import 'login_page.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  Map<String, dynamic>? _userData;
  bool _loading = true;
  bool _saving = false;
  bool _generatingAvatar = false;
  bool _generatingBio = false;
  bool _generatingInterests = false;
  String? _errorMessage;
  XFile? _avatarFile;

  // Danh sách sở thích cố định
  final List<String> allInterests = const ["Nhậu", "Karaoke", "Bar/Pub", "Beer Club"];
  List<String> selectedInterests = [];

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

  Future<void> _fetchUserData() async {
    try {
      final token = await StorageHelper.read("jwt_token");
      final userId = await StorageHelper.read("user_id");

      if (token == null || userId == null) {
        await _logout();
        return;
      }

      final response = await http.get(
        Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/user/$userId"),
        headers: {"Authorization": "Bearer $token"},
      );

      if (response.statusCode != 200) {
        throw Exception("Không lấy được thông tin user");
      }

      final data = json.decode(response.body);

      if (!mounted) return;
      setState(() {
        _userData = {
          "id": data['id']?.toString() ?? "N/A",
          "username": data['username']?.toString() ?? "-",
          "name": data['display_name']?.toString() ?? "-",
          "first_name": data['first_name']?.toString() ?? "-",
          "last_name": data['last_name']?.toString() ?? "-",
          "email": data['email']?.toString() ?? "-",
          "description": data['description']?.toString() ?? "-",
          "roles": data['roles'] != null
              ? (data['roles'] is List
              ? (data['roles'] as List).join(", ")
              : data['roles'].toString())
              : "-",
          "registered_date": data['registered_date']?.toString() ?? "-",
          "avatar_url": data['avatar_url'] ?? "",
          "interests": List<String>.from(data['interests'] ?? []),
        };
        // Chỉ giữ những sở thích cũ còn hợp lệ trong 4 lựa chọn mới
        selectedInterests = List<String>.from(_userData!['interests'] ?? [])
            .where((e) => allInterests.contains(e))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "Lỗi đọc dữ liệu user: $e";
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  Future<void> _pickAvatar() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image =
    await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (image != null) {
      setState(() => _avatarFile = image);
    }
  }

  Future<void> _generateAIAvatar() async {
    setState(() => _generatingAvatar = true);
    try {
      const prompt = "Avatar vui nhộn, phong cách hoạt hình, cho người thích nhậu";
      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/api/ai/avatar"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"prompt": prompt}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newAvatarUrl = data['avatar_url'];
        if (newAvatarUrl != null && newAvatarUrl.isNotEmpty) {
          setState(() {
            _avatarFile = null;
            _userData!['avatar_url'] =
            "$newAvatarUrl?t=${DateTime.now().millisecondsSinceEpoch}";
          });
        } else {
          _showSnack("AI Avatar trả về rỗng");
        }
      } else {
        _showSnack("AI Avatar lỗi: ${response.statusCode}");
      }
    } catch (e) {
      _showSnack("AI Avatar lỗi: $e");
    } finally {
      if (mounted) setState(() => _generatingAvatar = false);
    }
  }

  Future<void> _generateAIBio() async {
    setState(() => _generatingBio = true);
    try {
      final interests = selectedInterests.join(", ");
      final prompt = "Viết tiểu sử ngắn, vui vẻ cho người thích: $interests";

      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/api/ai/bio"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"prompt": prompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _userData!['description'] = data['bio']);
      } else {
        _showSnack("AI Bio lỗi: ${response.statusCode}");
      }
    } catch (e) {
      _showSnack("AI Bio lỗi: $e");
    } finally {
      if (mounted) setState(() => _generatingBio = false);
    }
  }

  Future<void> _generateAIInterests() async {
    setState(() => _generatingInterests = true);
    try {
      const prompt = "Gợi ý sở thích cho người thích nhậu, vui vẻ";

      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/api/ai/interests"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"prompt": prompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final suggested = List<String>.from(data['interests'] ?? []);
        setState(() {
          // Chỉ nhận gợi ý nằm trong 4 lựa chọn cố định
          selectedInterests =
              suggested.where((e) => allInterests.contains(e)).toList();
        });
      } else {
        _showSnack("AI Interests lỗi: ${response.statusCode}");
      }
    } catch (e) {
      _showSnack("AI Interests lỗi: $e");
    } finally {
      if (mounted) setState(() => _generatingInterests = false);
    }
  }

  Future<void> _updateProfile() async {
    setState(() => _saving = true);
    try {
      final token = await StorageHelper.read("jwt_token");
      final userId = await StorageHelper.read("user_id");
      if (token == null || userId == null) return;

      var uri = Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/user/$userId");
      var request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token';

      request.fields['display_name'] = _userData!['name'] ?? "";
      request.fields['first_name'] = _userData!['first_name'] ?? "";
      request.fields['last_name'] = _userData!['last_name'] ?? "";
      request.fields['description'] = _userData!['description'] ?? "";

      if (selectedInterests.isNotEmpty) {
        request.fields['interests'] = jsonEncode(selectedInterests);
      }

      if (_avatarFile != null) {
        request.files
            .add(await http.MultipartFile.fromPath('avatar', _avatarFile!.path));
      }

      var response = await request.send();
      var responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        await _fetchUserData();
        _showSnack("Cập nhật thành công");
      } else {
        throw Exception("Lỗi cập nhật profile ($responseBody)");
      }
    } catch (e) {
      _showSnack("Lỗi: $e");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------------- UI helpers ----------------

  Widget _sectionCard({required String title, IconData? icon, required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: accentOrange, size: 18),
                const SizedBox(width: 8),
              ],
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildTextField(
      String label, String initialValue, ValueChanged<String> onChanged,
      {int maxLines = 1, IconData? prefixIcon}) {
    return TextFormField(
      initialValue: initialValue,
      maxLines: maxLines,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
        prefixIcon:
        prefixIcon != null ? Icon(prefixIcon, color: Colors.white60, size: 20) : null,
        filled: true,
        fillColor: Colors.black.withOpacity(0.15),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: accentOrange, width: 1.4),
        ),
      ),
      onChanged: onChanged,
    );
  }

  IconData _interestIcon(String interest) {
    switch (interest) {
      case "Nhậu":
        return Icons.sports_bar;
      case "Karaoke":
        return Icons.mic;
      case "Bar/Pub":
        return Icons.local_bar;
      case "Beer Club":
        return Icons.celebration;
      default:
        return Icons.favorite;
    }
  }

  Widget _buildInterestChips() {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: allInterests.map((interest) {
        final isSelected = selectedInterests.contains(interest);
        return GestureDetector(
          onTap: () {
            setState(() {
              if (isSelected) {
                selectedInterests.remove(interest);
              } else {
                selectedInterests.add(interest);
              }
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              gradient: isSelected
                  ? LinearGradient(colors: [primaryBlue, accentOrange])
                  : null,
              color: isSelected ? null : Colors.black.withOpacity(0.15),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: isSelected ? Colors.transparent : Colors.white.withOpacity(0.25),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_interestIcon(interest), size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  interest,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    fontSize: 13.5,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildAvatar() {
    final String? avatarUrl = _userData?['avatar_url'];
    final bool hasValidAvatar = avatarUrl != null &&
        avatarUrl.isNotEmpty &&
        (Uri.tryParse(avatarUrl)?.isAbsolute ?? false);

    Widget avatarImage;
    if (_avatarFile != null) {
      avatarImage = Image.file(File(_avatarFile!.path),
          width: 112, height: 112, fit: BoxFit.cover);
    } else if (hasValidAvatar) {
      avatarImage = Image.network(
        avatarUrl,
        width: 112,
        height: 112,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const Center(
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2));
        },
        errorBuilder: (context, error, stackTrace) => Image.asset(
          'assets/avatar_placeholder.png',
          width: 112,
          height: 112,
          fit: BoxFit.cover,
        ),
      );
    } else {
      avatarImage = Image.asset('assets/avatar_placeholder.png',
          width: 112, height: 112, fit: BoxFit.cover);
    }

    return Center(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [primaryBlue, accentOrange],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: ClipOval(
              child: SizedBox(
                width: 112,
                height: 112,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: Colors.white24),
                    avatarImage,
                    if (_generatingAvatar)
                      Container(
                        color: Colors.black45,
                        child: const Center(
                          child:
                          CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -2,
            right: -2,
            child: GestureDetector(
              onTap: _pickAvatar,
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: accentOrange,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileSkeleton() {
    final baseColor = Colors.white.withOpacity(0.12);
    final highlightColor = Colors.white.withOpacity(0.28);

    return shimmer.Shimmer.fromColors(
      baseColor: baseColor,
      highlightColor: highlightColor,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SizedBox(height: 20),
            const CircleAvatar(radius: 55, backgroundColor: Colors.white),
            const SizedBox(height: 20),
            Container(
              height: 42,
              width: 160,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(height: 24),
            _skeletonInput(),
            const SizedBox(height: 12),
            _skeletonInput(),
            const SizedBox(height: 12),
            _skeletonInput(),
            const SizedBox(height: 12),
            Container(
              height: 90,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(
                4,
                    (i) => Container(
                  height: 32,
                  width: 80,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 30),
            Row(
              children: [
                Expanded(child: _skeletonButton()),
                const SizedBox(width: 12),
                Expanded(child: _skeletonButton()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _skeletonInput() {
    return Container(
      height: 48,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }

  Widget _skeletonButton() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget bodyContent;

    if (_loading) {
      bodyContent = _buildProfileSkeleton();
    } else if (_errorMessage != null) {
      bodyContent = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_errorMessage!,
              style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
        ),
      );
    } else {
      bodyContent = SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        child: Column(
          children: [
            _buildAvatar(),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _generatingAvatar ? null : _generateAIAvatar,
              icon: _generatingAvatar
                  ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
                  : const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
              label: Text(
                _generatingAvatar ? "Đang tạo..." : "Tạo avatar bằng AI",
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
              style: TextButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.12),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
            ),
            const SizedBox(height: 24),
            _sectionCard(
              title: "Thông tin cá nhân",
              icon: Icons.person_outline,
              child: Column(
                children: [
                  _buildTextField("Tên hiển thị", _userData!['name'],
                          (v) => _userData!['name'] = v,
                      prefixIcon: Icons.account_circle_outlined),
                  const SizedBox(height: 12),
                  _buildTextField("Tên", _userData!['first_name'],
                          (v) => _userData!['first_name'] = v,
                      prefixIcon: Icons.badge_outlined),
                  const SizedBox(height: 12),
                  _buildTextField("Họ", _userData!['last_name'],
                          (v) => _userData!['last_name'] = v,
                      prefixIcon: Icons.badge_outlined),
                ],
              ),
            ),
            _sectionCard(
              title: "Tiểu sử",
              icon: Icons.notes_outlined,
              child: Column(
                children: [
                  _buildTextField("Giới thiệu bản thân", _userData!['description'],
                          (v) => _userData!['description'] = v,
                      maxLines: 3),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _generatingBio ? null : _generateAIBio,
                      icon: _generatingBio
                          ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                          : Icon(Icons.auto_awesome, size: 16, color: accentOrange),
                      label: Text(
                        _generatingBio ? "Đang tạo..." : "Viết bằng AI",
                        style: TextStyle(color: accentOrange, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _sectionCard(
              title: "Sở thích",
              icon: Icons.favorite_outline,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildInterestChips(),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _generatingInterests ? null : _generateAIInterests,
                      icon: _generatingInterests
                          ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                          : Icon(Icons.auto_awesome, size: 16, color: accentOrange),
                      label: Text(
                        _generatingInterests ? "Đang gợi ý..." : "Gợi ý bằng AI",
                        style: TextStyle(color: accentOrange, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [primaryBlue, accentOrange]),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _updateProfile,
                      icon: _saving
                          ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                          : const Icon(Icons.check),
                      label: Text(_saving ? "Đang lưu..." : "Lưu thay đổi"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.3)),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout),
                      label: const Text("Đăng xuất"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Chỉnh sửa tài khoản"),
        titleTextStyle:
        const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold),
        iconTheme: const IconThemeData(color: Colors.white),
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue, accentOrange],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(child: bodyContent),
      ),
    );
  }
}