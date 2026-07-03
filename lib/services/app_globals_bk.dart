import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../helpers/storage_helper.dart';

/// Global navigator key — dùng để navigate từ bất kỳ đâu (service, FCM handler...)
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Flag: ChatPage đang mở hay không (để GlobalCallService biết bỏ qua FCM call)
bool isChatPageOpen = false;

/// Fetch thông tin user hiện tại từ API
Future<Map<String, dynamic>?> fetchMe() async {
  try {
    final token = await StorageHelper.read("jwt_token");
    final res = await http.get(
      Uri.parse("https://spiritwebs.com/wp-json/spiritwebs/v1/me"),
      headers: {"Authorization": "Bearer $token"},
    );
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  } catch (e) {
    debugPrint("fetchMe error: $e");
    return null;
  }
}