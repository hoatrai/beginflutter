import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Cổng xin quyền vị trí DÙNG CHUNG CHO TOÀN APP (không riêng 1 page).
///
/// 🔧 FIX 2 popup "bật định vị" chồng nhau lúc mới mở app: trước đây mỗi
/// nơi cần vị trí (ShopPage, PresenceService, near_pub.dart...) tự gọi
/// thẳng Geolocator.requestPermission() / getCurrentPosition() riêng —
/// ShopPage có dedupe nội bộ nhưng PresenceService lại chạy song song,
/// hoàn toàn không biết gì về nhau. Hai luồng cùng đụng Geolocator gần
/// như đồng thời lúc app vừa mở -> hệ điều hành xếp chồng 2 dialog.
///
/// Giải pháp: MỌI nơi trong app xin quyền vị trí đều gọi qua
/// `LocationPermissionGate.ensure(...)` — chỉ 1 request chạy tại 1 thời
/// điểm cho toàn app, các lệnh gọi đến sau sẽ CHỜ kết quả của lệnh gọi
/// đang chạy thay vì tự bắn request riêng.
class LocationPermissionGate {
  LocationPermissionGate._();

  static Future<bool>? _inFlight;

  /// [openSettingsDirectly] = true  -> hành vi "bắt buộc": tự mở thẳng
  ///   Cài đặt (Location Settings / App Settings) nếu thiếu quyền/GPS.
  /// [openSettingsDirectly] = false -> hành vi "nhẹ nhàng": chỉ trả về
  ///   false nếu thiếu quyền, KHÔNG tự mở Cài đặt (dùng cho các tác vụ
  ///   chạy ngầm lúc mới vào app, không nên làm phiền user).
  /// [onNeedGps] cho phép nơi gọi tự hiện UI của riêng mình khi thiếu GPS
  ///   thay vì gọi thẳng Settings (chỉ áp dụng khi openSettingsDirectly=false).
  static Future<bool> ensure({
    required bool openSettingsDirectly,
    VoidCallback? onNeedGps,
  }) {
    return _inFlight ??= _run(
      openSettingsDirectly: openSettingsDirectly,
      onNeedGps: onNeedGps,
    );
  }

  static Future<bool> _run({
    required bool openSettingsDirectly,
    VoidCallback? onNeedGps,
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (openSettingsDirectly) {
          await Geolocator.openLocationSettings();
        } else {
          onNeedGps?.call();
        }
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return false;
      }

      if (permission == LocationPermission.deniedForever) {
        if (openSettingsDirectly) {
          await Geolocator.openAppSettings();
        }
        return false;
      }

      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } finally {
      // Reset ngay sau khi xong — chỉ dedupe những request đến CÙNG LÚC,
      // lần xin quyền tiếp theo (vd user bấm lại nút) vẫn kiểm tra lại
      // bình thường.
      _inFlight = null;
    }
  }
}