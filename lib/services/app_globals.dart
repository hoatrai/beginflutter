import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../helpers/storage_helper.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

bool isChatPageOpen = false;
int? currentChatTargetId;

// ✅ thêm mới — theo dõi màn hình chat nhóm đang mở
bool isGroupChatPageOpen = false;
int? currentGroupChatId;
/// ✅ Avatar của user hiện tại — nguồn chuẩn duy nhất cho toàn app.
/// Được set mỗi khi fetchMeSafe() thành công (app start, sau login, v.v.)
String currentUserAvatar = '';

enum MeResult { success, unauthorized, networkError }

class FetchMeResponse {
  final MeResult result;
  final Map<String, dynamic>? data;
  FetchMeResponse(this.result, this.data);
}

Future<FetchMeResponse> fetchMeSafe() async {
  try {
    final token = await StorageHelper.read("jwt_token");

    final res = await http
        .get(
      Uri.parse("https://spiritwebs.com/wp-json/spiritwebs/v1/me"),
      headers: {"Authorization": "Bearer $token"},
    )
        .timeout(const Duration(seconds: 10));

    if (res.statusCode == 401 || res.statusCode == 403) {
      return FetchMeResponse(MeResult.unauthorized, null);
    }

    if (res.statusCode != 200) {
      debugPrint("fetchMe: server error ${res.statusCode}");
      return FetchMeResponse(MeResult.networkError, null);
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;

    // ✅ Đồng bộ avatar toàn cục ngay khi /me trả về thành công
    if (data['avatar_url'] != null && data['avatar_url'].toString().isNotEmpty) {
      currentUserAvatar = data['avatar_url'].toString();
      debugPrint("✅ Synced currentUserAvatar: $currentUserAvatar");
    }

    return FetchMeResponse(MeResult.success, data);
  } catch (e) {
    debugPrint("fetchMe error: $e");
    return FetchMeResponse(MeResult.networkError, null);
  }
}

Future<Map<String, dynamic>?> fetchMe() async {
  final response = await fetchMeSafe();
  return response.data;
}