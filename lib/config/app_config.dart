class AppConfig {
  static const String webDomain = 'https://spiritwebs.okinawanew.com';
  static const String socketDomain = 'https://socket.okinawanew.com';

  static const String websocketUrl =
      'wss://${'socket.okinawanew.com'}/socket/websocket';

  static const String apiUrl = '$webDomain/wp-json';
  static const String socketApi = '$socketDomain/api';
}