import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'storage_helper.dart';

class UserHelper {
  static Future<Map<String, dynamic>> getCurrentUser() async {
    final userDataRaw = await StorageHelper.read("user_data");
    if (userDataRaw == null) return {};

    try {
      final Map<String, dynamic> userData = jsonDecode(userDataRaw);

      return {
        "id": userData["id"]?.toString() ?? "N/A",
        "username": userData["display_name"] ?? "-",         // giống ProfilePage "username"
        "display_name": userData["display_name"] ?? "-",     // giống ProfilePage "name"
        "email": userData["email"] ?? "-",
        "avatar_url": userData["avatar_url"] ?? "",  // nếu backend trả avatar
      };
    } catch (e) {
      debugPrint(">>> [DEBUG] UserHelper decode error: $e");
      return {};
    }
  }
}
