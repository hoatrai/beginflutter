import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shimmer/shimmer.dart' as shimmer;

import '../helpers/storage_helper.dart';
import '../config/app_config.dart';

// ============================================================
// 🆕 UserListPage — trang quản lý user dành riêng cho admin.
//
// - Danh sách: GET /wp-json/wp/v2/users (endpoint gốc của WordPress,
//   trả đầy đủ email/roles khi gọi bằng token admin — vì user_list
//   page chỉ hiện cho admin nên không cần route riêng).
// - Thêm user: POST /wp-json/wp/v2/users/register — ĐÚNG endpoint mà
//   register_page.dart dùng cho user thật, nên user admin tạo ra đi
//   qua đúng luồng đăng ký thật (age-gate, hook, v.v.) rồi mới patch
//   thêm role/tên hiển thị nếu khác mặc định.
// - Sửa user: POST /wp-json/wp/v2/users/{id} (native WP, cần quyền
//   edit_users) cho email/roles/mật khẩu/tên hiển thị.
// - Avatar: multipart POST /wp-json/profile/v1/user/{id} — ĐÚNG
//   endpoint + field 'avatar' mà edit_profile_page.dart dùng cho user
//   tự sửa avatar của mình, chỉ khác userId là của user được quản lý
//   thay vì "chính mình".
//   ⚠️ LƯU Ý BACKEND: nếu route profile/v1/user/{id} phía PHP đang
//   giới hạn "chỉ được sửa chính mình" thì cần nới permission_callback
//   cho phép thêm điều kiện current_user_can('edit_users') để admin
//   upload avatar hộ user khác — không có quyền này sẽ bị 403.
// ============================================================

class UserListPage extends StatefulWidget {
  const UserListPage({super.key});

  @override
  State<UserListPage> createState() => _UserListPageState();
}

class _UserListPageState extends State<UserListPage> {
  final Color primaryBlue = const Color(0xFF0D47A1);
  final Color accentOrange = const Color(0xFFF57C00);

  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String? _errorMessage;
  String _search = "";
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<String?> _token() => StorageHelper.read("jwt_token");

  Future<void> _fetchUsers() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final token = await _token();
      final query = _search.isNotEmpty
          ? "&search=${Uri.encodeQueryComponent(_search)}"
          : "";
      // 🆕 FIX 404: route gốc wp/v2/users (danh sách) bị chặn chủ đích ở
      // backend (functions.php: add_filter('rest_endpoints', ...) unset
      // '/wp/v2/users') để tránh lộ danh sách user qua REST cho public.
      // Đổi sang route riêng nhau/v1/admin/users — tự check admin ở
      // backend, response cùng format (id, name, slug, email, roles,
      // avatar_urls) nên không cần sửa gì thêm bên dưới.
      final response = await http.get(
        Uri.parse(
            "${AppConfig.webDomain}/wp-json/nhau/v1/admin/users?per_page=100$query"),
        headers: {if (token != null) "Authorization": "Bearer $token"},
      );

      if (response.statusCode != 200) {
        throw Exception(
            "Không lấy được danh sách user (${response.statusCode})");
      }

      final List<dynamic> data = jsonDecode(response.body);
      setState(() {
        _users = data
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = "Lỗi tải danh sách user: $e";
        _loading = false;
      });
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red.shade700 : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openEditor({Map<String, dynamic>? user}) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UserEditSheet(
        user: user,
        primaryBlue: primaryBlue,
        accentOrange: accentOrange,
      ),
    );

    if (result == true) {
      _fetchUsers();
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> user) async {
    final name = (user['name'] ?? user['slug'] ?? 'user này').toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _GlassAlertDialog(
        icon: Icons.warning_amber_rounded,
        iconColor: Colors.redAccent,
        title: "Xóa user \"$name\"?",
        content: "Tài khoản này sẽ bị xóa vĩnh viễn và KHÔNG THỂ khôi phục.",
        cancelLabel: "Hủy",
        confirmLabel: "Xóa",
        confirmColors: const [Color(0xFFEF4444), Color(0xFFB91C1C)],
        primaryBlue: primaryBlue,
        accentOrange: accentOrange,
        onCancel: () => Navigator.pop(ctx, false),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );

    if (confirmed != true) return;

    try {
      final token = await _token();
      final id = user['id'];
      // 🆕 FIX "xóa thất bại": WordPress core BẮT BUỘC phải có param
      // `reassign` khi gọi DELETE /wp/v2/users/{id} (khai báo
      // `required => true` trong schema gốc của route) — thiếu nó,
      // WP trả lỗi 400 "Missing parameter(s): reassign" chứ không xoá
      // được gì cả. Truyền reassign=0 để báo "không gán nội dung cho
      // ai khác" (0 rơi vào nhánh falsy nên WP không coi là 1 user ID
      // thật để validate) mà vẫn thoả điều kiện "có truyền tham số".
      final response = await http.delete(
        Uri.parse(
            "${AppConfig.webDomain}/wp-json/wp/v2/users/$id?force=true&reassign=0"),
        headers: {if (token != null) "Authorization": "Bearer $token"},
      );

      if (response.statusCode == 200) {
        _showSnack("Đã xóa user");
        _fetchUsers();
      } else {
        final data = jsonDecode(response.body);
        _showSnack(
          "Xóa thất bại: ${data['message'] ?? response.statusCode}",
          isError: true,
        );
      }
    } catch (e) {
      _showSnack("Lỗi kết nối: $e", isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
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
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        "Quản lý user",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      onPressed: _fetchUsers,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  onSubmitted: (v) {
                    _search = v.trim();
                    _fetchUsers();
                  },
                  decoration: InputDecoration(
                    hintText: "Tìm theo tên / username / email...",
                    hintStyle: const TextStyle(color: Colors.white60),
                    prefixIcon: const Icon(Icons.search, color: Colors.white60),
                    suffixIcon: _search.isNotEmpty
                        ? IconButton(
                      icon: const Icon(Icons.close, color: Colors.white60),
                      onPressed: () {
                        _searchController.clear();
                        _search = "";
                        _fetchUsers();
                      },
                    )
                        : null,
                    filled: true,
                    fillColor: Colors.black.withOpacity(0.15),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: accentOrange,
        onPressed: () => _openEditor(),
        child: const Icon(Icons.person_add, color: Colors.white),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return _buildLoadingSkeleton();
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_users.isEmpty) {
      return const Center(
        child: Text("Không có user nào", style: TextStyle(color: Colors.white70)),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchUsers,
      color: primaryBlue,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
        itemCount: _users.length,
        itemBuilder: (context, index) {
          final user = _users[index];
          final roles = (user['roles'] is List)
              ? (user['roles'] as List).join(", ")
              : "";
          final avatarUrls = user['avatar_urls'];
          String? avatarUrl;
          if (avatarUrls is Map && avatarUrls.isNotEmpty) {
            avatarUrl = (avatarUrls['96'] ?? avatarUrls.values.last)?.toString();
          }

          return Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              leading: _MiniAvatar(
                avatarUrl: avatarUrl,
                name: (user['name'] ?? "?").toString(),
                primaryBlue: primaryBlue,
                accentOrange: accentOrange,
              ),
              title: Text(
                (user['name'] ?? user['slug'] ?? "Không tên").toString(),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                [
                  if ((user['email'] ?? '').toString().isNotEmpty) user['email'],
                  if (roles.isNotEmpty) roles,
                ].join(" • "),
                style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
                    onPressed: () => _openEditor(user: user),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.redAccent, size: 20),
                    onPressed: () => _confirmDelete(user),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // 🆕 Thay CircularProgressIndicator quay quay bằng shimmer skeleton —
  // vừa đúng tông màu/period đang dùng ở profile_page.dart (baseColor/
  // highlightColor cùng opacity, period 1200ms), vừa cho người dùng thấy
  // trước hình dạng của list (avatar tròn + 2 dòng text) thay vì chỉ
  // 1 vòng quay vô nghĩa ở giữa màn hình.
  Widget _buildLoadingSkeleton() {
    final baseColor = Colors.white.withOpacity(0.12);
    final highlightColor = Colors.white.withOpacity(0.28);

    return shimmer.Shimmer.fromColors(
      baseColor: baseColor,
      highlightColor: highlightColor,
      period: const Duration(milliseconds: 1200),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
        itemCount: 8,
        itemBuilder: (context, index) {
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        height: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 140,
                        height: 12,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(width: 20, height: 20, color: Colors.white),
                const SizedBox(width: 12),
                Container(width: 20, height: 20, color: Colors.white),
              ],
            ),
          );
        },
      ),
    );
  }
}

// -----------------------------
// 🔹 Avatar nhỏ cho list tile
// -----------------------------
class _MiniAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String name;
  final Color primaryBlue;
  final Color accentOrange;

  const _MiniAvatar({
    required this.avatarUrl,
    required this.name,
    required this.primaryBlue,
    required this.accentOrange,
  });

  @override
  Widget build(BuildContext context) {
    final hasAvatar = avatarUrl != null &&
        avatarUrl!.isNotEmpty &&
        (Uri.tryParse(avatarUrl!)?.isAbsolute ?? false);

    return CircleAvatar(
      radius: 22,
      backgroundColor: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [primaryBlue, accentOrange],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        width: 44,
        height: 44,
        child: ClipOval(
          child: hasAvatar
              ? Image.network(
            avatarUrl!,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _initials(),
          )
              : _initials(),
        ),
      ),
    );
  }

  Widget _initials() {
    return Center(
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : "U",
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    );
  }
}

// ============================================================
// 🔹 Bottom sheet Thêm / Sửa user
// ============================================================
class _UserEditSheet extends StatefulWidget {
  final Map<String, dynamic>? user; // null = thêm mới
  final Color primaryBlue;
  final Color accentOrange;

  const _UserEditSheet({
    required this.user,
    required this.primaryBlue,
    required this.accentOrange,
  });

  @override
  State<_UserEditSheet> createState() => _UserEditSheetState();
}

class _UserEditSheetState extends State<_UserEditSheet> {
  static const List<String> _roles = [
    "administrator",
    "editor",
    "author",
    "contributor",
    "subscriber",
  ];

  bool get _isEdit => widget.user != null;

  late final TextEditingController _usernameCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _descriptionCtrl;
  late String _role;
  DateTime? _dob;
  XFile? _avatarFile;
  String? _existingAvatarUrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _usernameCtrl = TextEditingController(text: (u?['slug'] ?? '').toString());
    _nameCtrl = TextEditingController(text: (u?['name'] ?? '').toString());
    _emailCtrl = TextEditingController(text: (u?['email'] ?? '').toString());
    _passwordCtrl = TextEditingController();
    _descriptionCtrl =
        TextEditingController(text: (u?['description'] ?? '').toString());
    final existingRoles = u?['roles'];
    _role = (existingRoles is List && existingRoles.isNotEmpty)
        ? existingRoles.first.toString()
        : "subscriber";
    if (!_roles.contains(_role)) _role = "subscriber";

    final avatarUrls = u?['avatar_urls'];
    if (avatarUrls is Map && avatarUrls.isNotEmpty) {
      _existingAvatarUrl = (avatarUrls['96'] ?? avatarUrls.values.last)?.toString();
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (image != null) setState(() => _avatarFile = image);
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) setState(() => _dob = picked);
  }

  String _formatDob(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return "${d.year}-$mm-$dd";
  }

  Future<String?> _token() => StorageHelper.read("jwt_token");

  Future<void> _save() async {
    final username = _usernameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (!_isEdit && username.isEmpty) {
      setState(() => _error = "Vui lòng nhập username");
      return;
    }
    if (!_isEdit && email.isEmpty) {
      setState(() => _error = "Vui lòng nhập email");
      return;
    }
    if (!_isEdit && password.isEmpty) {
      setState(() => _error = "Vui lòng nhập mật khẩu");
      return;
    }
    if (!_isEdit && _dob == null) {
      setState(() => _error = "Vui lòng chọn ngày sinh");
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final token = await _token();
      final headers = {
        "Content-Type": "application/json",
        if (token != null) "Authorization": "Bearer $token",
      };

      dynamic userId = widget.user?['id'];

      if (!_isEdit) {
        // 🆕 Tạo user qua ĐÚNG endpoint đăng ký thật (giống register_page.dart)
        final regResponse = await http.post(
          Uri.parse("${AppConfig.webDomain}/wp-json/wp/v2/users/register"),
          headers: headers,
          body: jsonEncode({
            "username": username,
            "email": email,
            "password": password,
            "date_of_birth": _formatDob(_dob!),
          }),
        );

        if (regResponse.statusCode != 200 && regResponse.statusCode != 201) {
          final data = jsonDecode(regResponse.body);
          throw Exception(data['message'] ?? "Tạo user thất bại (${regResponse.statusCode})");
        }

        final regData = jsonDecode(regResponse.body);
        userId = regData['id'];
        if (userId == null) {
          throw Exception("Không lấy được id user vừa tạo");
        }
      }

      // Cập nhật tên hiển thị / email / role / mật khẩu qua WP REST chuẩn
      final Map<String, dynamic> updateBody = {};
      if (name.isNotEmpty) updateBody['name'] = name;
      if (_isEdit && email.isNotEmpty) updateBody['email'] = email;
      if (password.isNotEmpty) updateBody['password'] = password;
      updateBody['roles'] = [_role];

      final updateResponse = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/wp/v2/users/$userId"),
        headers: headers,
        body: jsonEncode(updateBody),
      );

      if (updateResponse.statusCode != 200) {
        final data = jsonDecode(updateResponse.body);
        throw Exception(data['message'] ??
            "Cập nhật thông tin thất bại (${updateResponse.statusCode})");
      }

      // Avatar + mô tả — dùng đúng endpoint multipart mà user thật dùng
      // để tự sửa avatar của chính họ (profile/v1/user/{id}).
      if (_avatarFile != null || _descriptionCtrl.text.trim().isNotEmpty) {
        final uri = Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/user/$userId");
        final request = http.MultipartRequest('POST', uri)
          ..headers['Authorization'] = 'Bearer $token';

        if (name.isNotEmpty) request.fields['display_name'] = name;
        request.fields['description'] = _descriptionCtrl.text.trim();

        if (_avatarFile != null) {
          request.files.add(
            await http.MultipartFile.fromPath('avatar', _avatarFile!.path),
          );
        }

        final avatarResponse = await request.send();
        if (avatarResponse.statusCode != 200) {
          final body = await avatarResponse.stream.bytesToString();
          // Không chặn toàn bộ luồng nếu chỉ avatar lỗi — user/role vẫn đã lưu.
          throw Exception("Lưu avatar/mô tả thất bại: $body");
        }
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = "$e");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              gradient: LinearGradient(
                colors: [widget.primaryBlue, widget.accentOrange],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isEdit ? "Sửa user" : "Thêm user mới",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Center(child: _buildAvatarPicker()),
                const SizedBox(height: 20),
                if (!_isEdit) ...[
                  _field("Username", _usernameCtrl, icon: Icons.person),
                  const SizedBox(height: 12),
                ],
                _field("Tên hiển thị", _nameCtrl, icon: Icons.badge),
                const SizedBox(height: 12),
                _field("Email", _emailCtrl,
                    icon: Icons.email, keyboardType: TextInputType.emailAddress),
                const SizedBox(height: 12),
                _field(
                  _isEdit ? "Mật khẩu mới (để trống nếu không đổi)" : "Mật khẩu",
                  _passwordCtrl,
                  icon: Icons.lock,
                  obscure: true,
                ),
                const SizedBox(height: 12),
                _field("Mô tả / bio", _descriptionCtrl,
                    icon: Icons.description, maxLines: 3),
                const SizedBox(height: 12),
                if (!_isEdit) ...[
                  _buildDobPicker(),
                  const SizedBox(height: 12),
                ],
                _buildRoleDropdown(),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      style: const TextStyle(color: Colors.yellowAccent, fontSize: 13)),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _saving ? null : () => Navigator.pop(context, false),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white70,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(color: Colors.white.withOpacity(0.3)),
                          ),
                        ),
                        child: const Text("Hủy"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: TextButton(
                          onPressed: _saving ? null : _save,
                          style: TextButton.styleFrom(
                            foregroundColor: widget.primaryBlue,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: _saving
                              ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: widget.primaryBlue,
                            ),
                          )
                              : Text(_isEdit ? "Lưu" : "Tạo user",
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildAvatarPicker() {
    Widget avatarImage;
    if (_avatarFile != null) {
      avatarImage = Image.file(File(_avatarFile!.path),
          width: 96, height: 96, fit: BoxFit.cover);
    } else if (_existingAvatarUrl != null && _existingAvatarUrl!.isNotEmpty) {
      avatarImage = Image.network(
        _existingAvatarUrl!,
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: 96,
          height: 96,
          color: Colors.white24,
          child: const Icon(Icons.person, color: Colors.white70, size: 40),
        ),
      );
    } else {
      avatarImage = Container(
        width: 96,
        height: 96,
        color: Colors.white24,
        child: const Icon(Icons.person, color: Colors.white70, size: 40),
      );
    }

    return GestureDetector(
      onTap: _pickAvatar,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: ClipOval(child: avatarImage),
          ),
          Positioned(
            bottom: -2,
            right: -2,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.accentOrange,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const Icon(Icons.camera_alt, color: Colors.white, size: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDobPicker() {
    return InkWell(
      onTap: _pickDob,
      borderRadius: BorderRadius.circular(14),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: "Ngày sinh",
          labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
          prefixIcon: const Icon(Icons.calendar_today, color: Colors.white60, size: 20),
          filled: true,
          fillColor: Colors.black.withOpacity(0.15),
          contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        child: Text(
          _dob != null ? _formatDob(_dob!) : "Chọn ngày sinh",
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
    );
  }

  Widget _buildRoleDropdown() {
    return DropdownButtonFormField<String>(
      value: _role,
      dropdownColor: widget.primaryBlue,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText: "Vai trò",
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
        prefixIcon: const Icon(Icons.security, color: Colors.white60, size: 20),
        filled: true,
        fillColor: Colors.black.withOpacity(0.15),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      items: _roles
          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
          .toList(),
      onChanged: (v) {
        if (v != null) setState(() => _role = v);
      },
    );
  }

  Widget _field(
      String label,
      TextEditingController controller, {
        IconData? icon,
        bool obscure = false,
        int maxLines = 1,
        TextInputType? keyboardType,
      }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
        prefixIcon: icon != null ? Icon(icon, color: Colors.white60, size: 20) : null,
        filled: true,
        fillColor: Colors.black.withOpacity(0.15),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: widget.accentOrange, width: 1.4),
        ),
      ),
    );
  }
}

// ============================================================
// 🔹 Dialog xác nhận kiểu "glass" — bản độc lập, cùng style với
// _GlassAlertDialog trong profile_page.dart nhưng tách riêng vì đó
// là class private của file khác, không import chéo được.
// ============================================================
class _GlassAlertDialog extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? content;
  final String cancelLabel;
  final String confirmLabel;
  final List<Color> confirmColors;
  final Color primaryBlue;
  final Color accentOrange;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _GlassAlertDialog({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.content,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.confirmColors,
    required this.primaryBlue,
    required this.accentOrange,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            colors: [primaryBlue, accentOrange],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: Colors.white.withOpacity(0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: iconColor.withOpacity(0.15),
                border: Border.all(color: iconColor.withOpacity(0.4)),
              ),
              child: Icon(icon, color: iconColor, size: 26),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (content != null) ...[
              const SizedBox(height: 10),
              Text(
                content!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 13.5,
                  height: 1.55,
                ),
              ),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: onCancel,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.white.withOpacity(0.2)),
                      ),
                    ),
                    child: Text(cancelLabel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        colors: confirmColors,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: TextButton(
                      onPressed: onConfirm,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(
                        confirmLabel,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}