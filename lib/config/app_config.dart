class AppConfig {
  static const String webDomain = 'https://spiritwebs.okinawanew.com';
  static const String socketDomain = 'https://socket.okinawanew.com';

  static const String websocketUrl =
      'wss://${'socket.okinawanew.com'}/socket/websocket';

  static const String apiUrl = '$webDomain/wp-json';
  static const String socketApi = '$socketDomain/api';

  // 🆕 Yêu cầu bắt buộc của App Store/Play Store: phải có trang
  // Chính sách bảo mật & Điều khoản sử dụng truy cập được trong app.
  // TODO: đổi thành đúng URL trang thật trên WordPress (tạo 2 page
  // "Chính sách bảo mật" / "Điều khoản sử dụng" trên $webDomain rồi dán
  // slug vào đây).
  static const String privacyPolicyUrl = '$webDomain/chinh-sach-bao-mat';
  static const String termsOfServiceUrl = '$webDomain/dieu-khoan-su-dung';
}