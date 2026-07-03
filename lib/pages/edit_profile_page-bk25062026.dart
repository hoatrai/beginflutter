import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../helpers/storage_helper.dart';
import 'login_page.dart';
import 'package:shimmer/shimmer.dart' as shimmer;

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  Map<String, dynamic>? _userData;
  bool _loading = true;
  String? _errorMessage;
  XFile? _avatarFile;

  final List<String> allInterests = ["Bia", "BBQ", "Karaoke", "Pub", "Cocktail"];
  List<String> selectedInterests = [];

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
  }

  /// Load user data từ server
  Future<void> _fetchUserData() async {
    print(">>> [DEBUG] Fetching user data...");
    try {
      final token = await StorageHelper.read("jwt_token");
      final userId = await StorageHelper.read("user_id");
      print(">>> [DEBUG] token=$token, userId=$userId");

      if (token == null || userId == null) {
        print(">>> [DEBUG] token hoặc userId null, logout");
        await _logout();
        return;
      }

      final response = await http.get(
        Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/user/$userId"),
        headers: {"Authorization": "Bearer $token"},
      );
      print(">>> [DEBUG] HTTP status: ${response.statusCode}");
      print(">>> [DEBUG] HTTP body: ${response.body}");

      if (response.statusCode != 200) {
        throw Exception("Không lấy được thông tin user");
      }

      final data = json.decode(response.body);
      print(">>> [DEBUG] user data: $data");

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
              ? (data['roles'] is List ? (data['roles'] as List).join(", ") : data['roles'].toString())
              : "-",
          "registered_date": data['registered_date']?.toString() ?? "-",
          "avatar_url": data['avatar_url'] ?? "",
          "interests": List<String>.from(data['interests'] ?? []),
        };
        selectedInterests = List<String>.from(_userData!['interests'] ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = "Lỗi đọc dữ liệu user: $e";
        _loading = false;
      });
      print(">>> [DEBUG] Error fetching user: $e");
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
      setState(() {
        _avatarFile = image;
      });
    }
  }

  /// AI Avatar
  Future<void> _generateAIAvatar() async {
    try {
      setState(() => _loading = true);
      final prompt = "Avatar vui nhộn, phong cách hoạt hình, cho người thích nhậu";
      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/api/ai/avatar"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"prompt": prompt}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newAvatarUrl = data['avatar_url'];
        print(">>> AI Avatar URL: $newAvatarUrl"); // debug
        if (newAvatarUrl != null && newAvatarUrl.isNotEmpty) {
          setState(() {
            _avatarFile = null;
            _userData!['avatar_url'] =
            "$newAvatarUrl?t=${DateTime.now().millisecondsSinceEpoch}";
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("AI Avatar trả về rỗng")));
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("AI Avatar lỗi: $e")));
    } finally {
      setState(() => _loading = false);
    }
  }

  /// AI Bio
  Future<void> _generateAIBio() async {
    try {
      setState(() => _loading = true);
      final interests = selectedInterests.join(", ");
      final prompt = "Viết tiểu sử ngắn, vui vẻ cho người thích: $interests";

      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/api/ai/bio"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"prompt": prompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _userData!['description'] = data['bio'];
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("AI Bio lỗi: $e")));
    } finally {
      setState(() => _loading = false);
    }
  }

  /// AI Interests
  Future<void> _generateAIInterests() async {
    try {
      setState(() => _loading = true);
      final prompt = "Gợi ý 3-5 sở thích cho người thích nhậu, vui vẻ";

      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/api/ai/interests"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"prompt": prompt}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          selectedInterests = List<String>.from(data['interests']);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("AI Interests lỗi: $e")));
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Upload & update profile
  Future<void> _updateProfile() async {
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
        request.files.add(await http.MultipartFile.fromPath(
          'avatar',
          _avatarFile!.path,
        ));
      }

      var response = await request.send();
      var responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        await _fetchUserData();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Cập nhật thành công")));
      } else {
        print("Status code: ${response.statusCode}");
        print("Response body: $responseBody");
        throw Exception("Lỗi cập nhật profile");
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  Widget _buildTextField(String label, String initialValue, ValueChanged<String> onChanged,
      {int maxLines = 1}) {
    return TextFormField(
      initialValue: initialValue,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: Colors.white.withOpacity(0.1),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      style: const TextStyle(color: Colors.white),
      onChanged: onChanged,
      maxLines: maxLines,
    );
  }

  Widget _buildAvatar() {
    final String? avatarUrl = _userData?['avatar_url'];
    final bool hasValidAvatar =
        avatarUrl != null && avatarUrl.isNotEmpty && (Uri.tryParse(avatarUrl)?.isAbsolute ?? false);


    return GestureDetector(
      onTap: _pickAvatar,
      child: CircleAvatar(
        radius: 55,
        backgroundColor: Colors.white24,
        child: _avatarFile != null
            ? ClipOval(
          child: Image.file(
            File(_avatarFile!.path),
            width: 110,
            height: 110,
            fit: BoxFit.cover,
          ),
        )
            : hasValidAvatar
            ? ClipOval(
          child: Image.network(
            avatarUrl,
            width: 110,
            height: 110,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: CircularProgressIndicator(color: Colors.white),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              print(">>> [DEBUG] Avatar load error: $error");
              return Image.asset(
                'assets/avatar_placeholder.png',
                width: 110,
                height: 110,
                fit: BoxFit.cover,
              );
            },
          ),

        )
            : Image.asset(
          'assets/avatar_placeholder.png',
          width: 110,
          height: 110,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  /// Skeleton loading
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

            // Avatar
            const CircleAvatar(
              radius: 55,
              backgroundColor: Colors.white,
            ),

            const SizedBox(height: 20),

            // Button fake
            Container(
              height: 42,
              width: 160,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
            ),

            const SizedBox(height: 24),

            // Input lines
            _skeletonInput(),
            const SizedBox(height: 12),
            _skeletonInput(),
            const SizedBox(height: 12),
            _skeletonInput(),
            const SizedBox(height: 12),

            // Bio multiline
            Container(
              height: 90,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
            ),

            const SizedBox(height: 20),

            // Chip row fake
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(
                5,
                    (i) => Container(
                  height: 32,
                  width: 70,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 30),

            // Buttons bottom
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
        child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
      );
    } else {
      bodyContent = SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildAvatar(),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _generateAIAvatar,
              style: ElevatedButton.styleFrom(
                  backgroundColor: accentOrange, foregroundColor: textWhite),
              child: const Text("Generate Avatar AI"),
            ),
            const SizedBox(height: 20),
            _buildTextField("Tên hiển thị", _userData!['name'], (val) => _userData!['name'] = val),
            const SizedBox(height: 12),
            _buildTextField("Tên", _userData!['first_name'], (val) => _userData!['first_name'] = val),
            const SizedBox(height: 12),
            _buildTextField("Họ", _userData!['last_name'], (val) => _userData!['last_name'] = val),
            const SizedBox(height: 12),
            _buildTextField(
              "Tiểu sử",
              _userData!['description'],
                  (val) => _userData!['description'] = val,
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _generateAIBio,
              style: ElevatedButton.styleFrom(
                backgroundColor: accentOrange,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text("Tạo bằng AI",
                  style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: const Text("Sở thích",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: allInterests.map((interest) {
                  final isSelected = selectedInterests.contains(interest);
                  return ChoiceChip(
                    label: Text(
                      interest,
                      style: TextStyle(
                        color: isSelected ? Colors.black87 : Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          selectedInterests.add(interest);
                        } else {
                          selectedInterests.remove(interest);
                        }
                      });
                    },
                    selectedColor: accentOrange,
                    backgroundColor: Colors.black45,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
                onPressed: _generateAIInterests,
                style: ElevatedButton.styleFrom(backgroundColor: accentOrange),
                child: const Text("Generate Sở thích AI")),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [primaryBlue, accentOrange],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _updateProfile,
                      icon: const Icon(Icons.edit),
                      label: const Text("Cập nhật profile"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
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
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
        titleTextStyle: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
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
        child: SafeArea(
          child: _loading
              ? Container(
            width: double.infinity,
            height: double.infinity,
            child: _buildProfileSkeleton(),
          )
              : bodyContent,


        ),
      ),
    );

  }


}
