import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../helpers/storage_helper.dart';

/// Global navigator key — dùng để navigate từ bất kỳ đâu (service, FCM handler...)
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Flag: ChatPage đang mở hay không (để GlobalCallService biết bỏ qua FCM call)
bool isChatPageOpen = false;

/// ID của người đang chat — null nếu không có ChatPage nào mở.
/// Dùng để lọc FCM notification: không hiện banner nếu đang chat đúng người đó.
int? currentChatTargetId;

/// Kết quả của fetchMeSafe(), phân biệt rõ 3 trường hợp:
/// - success: lấy thông tin user thành công
/// - unauthorized: token thực sự hết hạn/invalid (server trả 401/403)
/// - networkError: lỗi tạm thời (mất mạng, timeout, server 500/502/503...)
///   KHÔNG được coi là "chưa đăng nhập" và không nên xoá token trong trường hợp này.
enum MeResult { success, unauthorized, networkError }

class FetchMeResponse {
  final MeResult result;
  final Map<String, dynamic>? data;
  FetchMeResponse(this.result, this.data);
}

/// Fetch thông tin user hiện tại từ API — phiên bản an toàn, phân biệt rõ
/// lỗi "hết hạn token" (401/403) với lỗi mạng/server tạm thời.
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
      // Token thực sự không hợp lệ / hết hạn
      return FetchMeResponse(MeResult.unauthorized, null);
    }

    if (res.statusCode != 200) {
      // Lỗi server tạm thời (500, 502, 503...) — không phải lỗi token
      debugPrint("fetchMe: server error ${res.statusCode}");
      return FetchMeResponse(MeResult.networkError, null);
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return FetchMeResponse(MeResult.success, data);
  } catch (e) {
    // Mất mạng, timeout, DNS lỗi, JSON lỗi... đều coi là lỗi tạm thời
    debugPrint("fetchMe error: $e");
    return FetchMeResponse(MeResult.networkError, null);
  }
}

/// Giữ lại hàm cũ (trả về Map? hoặc null) để các chỗ khác trong code
/// (ví dụ main.dart -> _openChatFromData) không cần sửa lại cách gọi.
/// Lưu ý: hàm này KHÔNG phân biệt được lỗi mạng với hết hạn token,
/// nên chỉ nên dùng ở những nơi không cần logic đăng xuất tự động.
/// Với SplashPage, hãy dùng fetchMeSafe() thay vì hàm này.
Future<Map<String, dynamic>?> fetchMe() async {
  final response = await fetchMeSafe();
  return response.data;
}