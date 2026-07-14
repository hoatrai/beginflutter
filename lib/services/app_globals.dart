import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../helpers/storage_helper.dart';
import '../config/app_config.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 🆕 Dữ liệu 1 cuộc gọi đã được NGƯỜI DÙNG BẤM "NGHE" trên màn hình
/// CallKit native (Android full-screen Activity / iOS CallKit), nhưng
/// chưa thể mở `VideoCallPage` ngay vì `MainPage` chưa kịp mount (trường
/// hợp app vừa được Android tự mở lại từ trạng thái BỊ KILL HẲN).
///
/// 🐛 BUG ĐÃ SỬA: trước đây `GlobalCallService.acceptCallFromNative()` tự
/// retry push `VideoCallPage` thẳng lên `navigatorKey.currentState` mỗi
/// 200ms — luồng này CHẠY SONG SONG và ĐỘC LẬP với `SplashPage._init()`
/// (splash tự gọi API `/me` rồi `Navigator.pushReplacement` sang
/// MainPage/LoginPage). Vì `pushReplacement` thay thế ĐÚNG route đang ở
/// đỉnh navigator tại thời điểm gọi, nếu `VideoCallPage` đã kịp được đẩy
/// lên TRƯỚC (rất hay xảy ra vì retry ở trên gần như chạy ngay, còn Splash
/// phải chờ HTTP `/me`), `pushReplacement` sẽ XOÁ MẤT `VideoCallPage` và
/// thay bằng `MainPage` → user bấm "Nghe" nhưng lại thấy màn hình chính.
///
/// Cách sửa: nếu navigator CHƯA sẵn sàng lúc accept, KHÔNG tự push nữa —
/// lưu vào biến này, để `MainPage._openPendingNativeCall()` (main.dart)
/// tự mở `VideoCallPage` SAU KHI Splash đã điều hướng xong, y hệt pattern
/// `_pendingCallData` sẵn có cho luồng tap FCM notification.
class PendingNativeCall {
  final WebSocketChannel socket;
  final String topic;
  final String callType;
  final String? targetName;
  final String? targetAvatar;

  const PendingNativeCall({
    required this.socket,
    required this.topic,
    required this.callType,
    this.targetName,
    this.targetAvatar,
  });
}

PendingNativeCall? pendingNativeCall;

bool isChatPageOpen = false;
int? currentChatTargetId;

// ✅ thêm mới — theo dõi màn hình chat nhóm đang mở
bool isGroupChatPageOpen = false;
int? currentGroupChatId;

// ✅ thêm mới — theo dõi trang chi tiết "kèo" (invite) đang mở, để
// không hiện banner FCM trùng lặp khi user đang xem đúng trang đó
// (trang đó đã tự hiện SnackBar realtime qua socket rồi).
bool isInviteDetailOpen = false;
int? currentInviteId;
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
      Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/me"),
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