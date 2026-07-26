import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'storage_helper.dart';

class UserHelper {
  static Future<Map<String, dynamic>> getCurrentUser() async {
    final userDataRaw = await StorageHelper.read("user_data");
    if (userDataRaw == null) return {};

    try {
      final Map<String, dynamic> userData = jsonDecode(userDataRaw);

      // 🆕 user_data giờ luôn được login_page.dart ghi theo đúng 1 schema
      // chuẩn: {id, username, display_name, email, avatar_url}. Vẫn giữ
      // fallback chéo (display_name <-> username) phòng trường hợp đọc
      // phải dữ liệu cache cũ (từ trước khi sửa) chưa được ghi đè lại.
      final displayName = (userData["display_name"] ?? userData["username"] ?? "Người dùng").toString();
      final username = (userData["username"] ?? userData["display_name"] ?? "Người dùng").toString();

      return {
        "id": userData["id"]?.toString() ?? "0",
        "username": username,
        "display_name": displayName,
        "email": userData["email"] ?? "",
        "avatar_url": userData["avatar_url"] ?? "",
      };
    } catch (e) {
      debugPrint(">>> [DEBUG] UserHelper decode error: $e");
      return {};
    }
  }
}
