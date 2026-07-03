import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'login_page.dart';
import '../helpers/storage_helper.dart';
import 'edit_profile_page.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';


class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

// -----------------------------
// 🔹 Avatar load sau
// -----------------------------
class AvatarWidget extends StatefulWidget {
  final String? avatarUrl;
  final String displayName;
  final Color primaryBlue;
  final Color accentOrange;

  const AvatarWidget({
    super.key,
    this.avatarUrl,
    required this.displayName,
    required this.primaryBlue,
    required this.accentOrange,
  });

  @override
  State<AvatarWidget> createState() => _AvatarWidgetState();
}

class _AvatarWidgetState extends State<AvatarWidget> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty) {
      final image = NetworkImage(widget.avatarUrl!);
      image.resolve(const ImageConfiguration()).addListener(
        ImageStreamListener((_, __) {
          if (mounted) {
            setState(() {
              _loaded = true;
            });
          }
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.avatarUrl == null || widget.avatarUrl!.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [widget.primaryBlue, widget.accentOrange],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: CircleAvatar(
          radius: 50,
          backgroundColor: Colors.transparent,
          child: Text(
            widget.displayName.isNotEmpty
                ? widget.displayName[0].toUpperCase()
                : "U",
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [widget.primaryBlue, widget.accentOrange],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
        ),
        AnimatedOpacity(
          opacity: _loaded ? 1 : 0,
          duration: const Duration(milliseconds: 500),
          child: CircleAvatar(
            radius: 50,
            backgroundColor: Colors.transparent,
            backgroundImage: NetworkImage(widget.avatarUrl!),
          ),
        ),
      ],
    );
  }
}

// -----------------------------
class _ProfilePageState extends State<ProfilePage> {
  Map<String, dynamic>? _userData;
  bool _loading = true;
  String? _errorMessage;

  // Theme colors
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

  Future<void> _fetchUserData() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

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

      setState(() {
        _userData = {
          "id": data['id']?.toString() ?? "N/A",
          "username": data['username']?.toString() ?? "-",
          "name": data['display_name']?.toString() ?? "-",
          "first_name": data['first_name']?.toString() ?? "-",
          "last_name": data['last_name']?.toString() ?? "-",
          "email": data['email']?.toString() ?? "-",
          "url": data['url']?.toString() ?? "-",
          "description": data['description']?.toString() ?? "-",
          "roles": data['roles'] != null
              ? (data['roles'] is List
              ? (data['roles'] as List).join(", ")
              : data['roles'].toString())
              : "-",
          "registered_date": data['registered_date']?.toString() ?? "-",
          "avatar_url": data['avatar_url'] ?? "",
        };
        _loading = false;
      });
    } catch (e) {
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

  Widget _buildSkeletonProfile() {
    final baseColor = Colors.white.withOpacity(0.12);
    final highlightColor = Colors.white.withOpacity(0.28);

    return shimmer.Shimmer.fromColors(
      baseColor: baseColor,
      highlightColor: highlightColor,
      period: const Duration(milliseconds: 1200),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Avatar
            Container(
              width: 100,
              height: 100,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),

            const SizedBox(height: 16),

            // Name
            Container(height: 20, width: 120, color: Colors.white),
            const SizedBox(height: 8),

            // Username
            Container(height: 16, width: 80, color: Colors.white),

            const SizedBox(height: 30),

            // Info lines
            ...List.generate(
              6,
                  (index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Container(
                  height: 18,
                  width: double.infinity,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileInfo() {
    if (_userData == null) return const SizedBox.shrink();

    final infoItems = <Map<String, dynamic>>[];

    void addIfNotEmpty(IconData icon, String label, String? value) {
      if (value != null &&
          value.isNotEmpty &&
          value != "-" &&
          value != "N/A") {
        infoItems.add({"icon": icon, "label": label, "value": value});
      }
    }

    addIfNotEmpty(Icons.badge, "ID", _userData!["id"]);
    addIfNotEmpty(Icons.person, "Tên đăng nhập", _userData!["username"]);
    addIfNotEmpty(Icons.account_circle, "Tên hiển thị", _userData!["name"]);
    //addIfNotEmpty(Icons.account_box, "Tên", _userData!["first_name"]);
    //addIfNotEmpty(Icons.account_box_outlined, "Họ", _userData!["last_name"]);
    addIfNotEmpty(Icons.email, "Email", _userData!["email"]);
    addIfNotEmpty(Icons.link, "Website", _userData!["url"]);
    addIfNotEmpty(Icons.description, "Mô tả", _userData!["description"]);
    addIfNotEmpty(Icons.security, "Vai trò", _userData!["roles"]);
    addIfNotEmpty(
        Icons.calendar_today, "Ngày đăng ký", _userData!["registered_date"]);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Avatar load sau
          AvatarWidget(
            avatarUrl: _userData?["avatar_url"],
            displayName: _userData?["name"] ?? "U",
            primaryBlue: primaryBlue,
            accentOrange: accentOrange,
          ),
          const SizedBox(height: 12),
          Text(
            _userData!["name"] ?? "User",
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            "@${_userData!["username"] ?? "user"}",
            style: const TextStyle(fontSize: 16, color: Colors.white70),
          ),
          const SizedBox(height: 24),

          if (infoItems.isNotEmpty)
            Container(
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
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 18),
              child: Column(
                children: List.generate(infoItems.length, (index) {
                  final item = infoItems[index];
                  final isLast = index == infoItems.length - 1;
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: _infoRow(item["icon"], item["label"], item["value"]),
                      ),
                      if (!isLast)
                        Divider(
                          color: Colors.white.withOpacity(0.15),
                          height: 1,
                          thickness: 1,
                        ),
                    ],
                  );
                }),
              ),
            ),
          const SizedBox(height: 30),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [primaryBlue, accentOrange],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const EditProfilePage()),
                        );
                      },
                      icon: const Icon(Icons.edit),
                      label: const Text("Cập nhật profile"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: textWhite,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [accentOrange, primaryBlue],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout),
                      label: const Text("Đăng xuất"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: textWhite,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Cột trái: icon + label
        Expanded(
          flex: 4,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [primaryBlue.withOpacity(0.6), accentOrange.withOpacity(0.6)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Icon(icon, color: textWhite, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withOpacity(0.75),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Cột phải: value
        Expanded(
          flex: 5,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  Widget _buildAnimatedProfileInfo() {
    return AnimatedOpacity(
      opacity: _loading ? 0.0 : 1.0,
      duration: const Duration(milliseconds: 600),
      child: _buildProfileInfo(),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget bodyContent;

    if (_loading) {
      bodyContent = _buildSkeletonProfile();
    } else if (_errorMessage != null) {
      bodyContent = Center(
        child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
      );
    } else {
      bodyContent = _buildAnimatedProfileInfo();
    }

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 20),
              const Text(
                "Thông tin tài khoản",
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(child: bodyContent),
            ],
          ),
        ),
      ),
    );
  }
}
