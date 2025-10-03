import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'login_page.dart';
import 'market_page.dart';
import 'blog_page.dart';
import 'shop_page.dart';
import 'flutter_map.dart';
import '../helpers/storage_helper.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  Map<String, dynamic>? _userData;
  bool _loading = true;
  String? _errorMessage;

  int _selectedIndex = 2; // Profile mặc định

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
      if (token == null) {
        await _logout();
        return;
      }

      // Gọi API lấy thông tin user hiện tại
      final response = await http.get(
        Uri.parse("https://spiritwebs.com/wp-json/wp/v2/users/me"),
        headers: {"Authorization": "Bearer $token"},
      );

      if (response.statusCode != 200) {
        throw Exception("Không lấy được thông tin user");
      }

      final data = json.decode(response.body);

      // Convert id sang String
      final id = (data["id"] ?? "N/A").toString();
      final email = await StorageHelper.read("user_email") ?? "-";
      final username = data["slug"] ?? "-";
      final displayName = data["name"] ?? "-";

      // Lưu vào StorageHelper
      await StorageHelper.write("user_id", id);
      //await StorageHelper.write("user_email", email);
      await StorageHelper.write("user_nicename", username);
      await StorageHelper.write("user_display_name", displayName);


      // Set userData
      setState(() {
        _userData = {
          "id": id,
          "email": email,
          "slug": username,
          "name": displayName,
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

  // Build danh sách các tab, MapPage cần userData
  List<Widget> _pages() {
    return [
      const MarketPage(),
      (_userData != null)
          ? MapPage(
        username: _userData!['slug'] ?? 'Visitor',
        email: _userData!['email'] ?? '',
      )
          : const SizedBox.shrink(), // loading Map tạm
      const SizedBox.shrink(), // Profile build riêng
      const BlogPage(),
      const ShopPage(),
    ];
  }

  Widget _buildProfileInfo() {
    if (_userData == null) return const SizedBox.shrink();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          CircleAvatar(
            radius: 50,
            backgroundColor: Colors.blue.shade100,
            child: Text(
              _userData!["name"]?.toString().substring(0, 1).toUpperCase() ?? "U",
              style: const TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _userData!["name"] ?? "User",
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            "@${_userData!["slug"] ?? "user"}",
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
          const SizedBox(height: 24),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 4,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _infoRow(Icons.badge, "ID", _userData!["id"].toString()),
                  const SizedBox(height: 12),
                  _infoRow(Icons.email, "Email", _userData!["email"] ?? "-"),
                  const SizedBox(height: 12),
                  _infoRow(Icons.person, "Username", _userData!["slug"] ?? "-"),
                ],
              ),
            ),
          ),
          const SizedBox(height: 30),
          SizedBox(
            width: 200,
            child: ElevatedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text("Đăng xuất"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.blue),
        const SizedBox(width: 12),
        Text("$label:", style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(value, style: const TextStyle(color: Colors.black87)),
        ),
      ],
    );
  }

  void _onTabTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget bodyContent;
    if (_selectedIndex == 2) {
      // Profile tab
      if (_loading) {
        bodyContent = const Center(child: CircularProgressIndicator());
      } else if (_errorMessage != null) {
        bodyContent = Center(
          child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
        );
      } else {
        bodyContent = _buildProfileInfo();
      }
    } else {
      bodyContent = _pages()[_selectedIndex];
    }

    return Scaffold(
      body: bodyContent,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onTabTapped,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.blue,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white70,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: "Market"),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: "Map"),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: "Profile"),
          BottomNavigationBarItem(icon: Icon(Icons.article), label: "Blog"),
          BottomNavigationBarItem(icon: Icon(Icons.shopping_cart), label: "Shop"),
        ],
      ),
    );
  }
}
