import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import '../config/app_config.dart';
import 'location_permission_gate.dart';

/// PresenceService: connect socket + track vị trí 1 LẦN DUY NHẤT cho toàn app.
/// Gọi `PresenceService.instance.start(...)` ngay sau khi login thành công
/// (ở tầng trên Navigator, ví dụ trong main.dart / HomeShell), KHÔNG gọi
/// trong MapPage. Nhờ vậy user vẫn "hiện diện" realtime dù đang ở bất kỳ
/// trang nào trong app, miễn là GPS đang bật.
class PresenceService {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  PhoenixSocket? _socket;
  PhoenixChannel? _channel;
  StreamSubscription<Position>? _posStream;
  StreamSubscription<ServiceStatus>? _serviceStatusSub;
  DateTime? _lastUpdate;

  int? _userId;
  String _username = "";
  double? _lastLat;
  double? _lastLng;

  bool _started = false;
  bool get isConnected => _channel != null;

  /// UI (MapPage hoặc bất kỳ widget nào) lắng nghe cái này để vẽ marker.
  final ValueNotifier<Map<String, Map<String, dynamic>>> presenceUsers =
  ValueNotifier({});

  /// Gọi 1 lần sau khi có userId/username (ví dụ ngay sau login).
  /// An toàn khi gọi nhiều lần — chỉ start thật sự lần đầu.
  Future<void> start({required int userId, required String username}) async {
    if (_started) return;
    _started = true;
    _userId = userId;
    _username = username;

    await _connect();

    if (!kIsWeb) {
      _serviceStatusSub = Geolocator.getServiceStatusStream().listen((status) {
        if (status == ServiceStatus.enabled) {
          debugPrint('✅ GPS vừa được bật -> reconnect presence');
          _connect();
        } else {
          debugPrint('⚠️ GPS bị tắt');
        }
      });
    }

    // 🔧 Xin quyền qua cổng dùng chung (không tự bắn request riêng, tránh
    // đè lên dialog mà ShopPage/page khác có thể đang xin cùng lúc lúc
    // app vừa mở). openSettingsDirectly: false vì đây là tác vụ chạy
    // ngầm — nếu chưa có quyền thì âm thầm bỏ qua, không làm phiền user.
    final granted = await LocationPermissionGate.ensure(openSettingsDirectly: false);
    if (!granted) {
      debugPrint('⚠️ [PresenceService] Chưa có quyền vị trí, bỏ qua tracking vị trí (vẫn kết nối socket khi GPS bật lại).');
      return;
    }

    _posStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 50,
      ),
    ).listen((p) {
      final now = DateTime.now();
      if (_lastUpdate == null ||
          now.difference(_lastUpdate!) > const Duration(seconds: 5)) {
        _lastUpdate = now;
        _lastLat = p.latitude;
        _lastLng = p.longitude;
        _pushPresence(p.latitude, p.longitude, status: "online");
      }
    });
  }

  Future<void> _connect() async {
    if (_channel != null) return; // đã kết nối rồi, không connect lại
    try {
      // 🔧 Cũng đi qua cổng dùng chung thay vì gọi Geolocator trực tiếp —
      // nếu chưa có quyền, chờ granted thay vì tự bắn request riêng.
      final granted = await LocationPermissionGate.ensure(openSettingsDirectly: false);
      if (!granted) return;

      final pos =
      await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _lastLat = pos.latitude;
      _lastLng = pos.longitude;

      _socket = PhoenixSocket(AppConfig.websocketUrl);
      await _socket!.connect();

      _channel = _socket!.addChannel(
        topic: "online_users:lobby",
        parameters: {
          "user_id": _userId,
          "username": _username.isNotEmpty ? _username : "guest",
          "latitude": pos.latitude,
          "longitude": pos.longitude,
        },
      );

      await _channel!.join();
      debugPrint("✅ [PresenceService] Joined online_users:lobby");

      _channel!.messages.listen((event) {
        final name = event.event.toString().toLowerCase();
        if (name.contains("presence_state")) {
          try {
            _handleState(Map<String, dynamic>.from(event.payload as Map));
          } catch (e) {
            debugPrint("❌ presence_state error: $e");
          }
        } else if (name.contains("presence_diff")) {
          try {
            _handleDiff(Map<String, dynamic>.from(event.payload as Map));
          } catch (e) {
            debugPrint("❌ presence_diff error: $e");
          }
        }
      });

      _pushPresence(pos.latitude, pos.longitude, status: "online");
    } catch (e) {
      debugPrint("❌ [PresenceService] connect error: $e");
      _channel = null;
      _socket = null;
    }
  }

  void _pushPresence(double lat, double lng, {required String status}) {
    _channel?.push("update_presence", {
      "user_id": _userId,
      "username": _username,
      "latitude": lat,
      "longitude": lng,
      "status": status,
      "updated_at": DateTime.now().toIso8601String(),
    });
  }

  /// Gọi khi app chuyển background/resume (didChangeAppLifecycleState ở tầng
  /// app, ví dụ trong 1 widget bọc ngoài toàn app). KHÔNG disconnect socket
  /// khi background — chỉ đổi trạng thái để user khác biết là "away".
  void setAppStatus(String status) {
    if (_channel == null || _lastLat == null || _lastLng == null) return;
    _pushPresence(_lastLat!, _lastLng!, status: status);
  }

  void _handleState(Map<String, dynamic> payload) {
    final map = <String, Map<String, dynamic>>{};
    payload.forEach((key, value) {
      final metas = value['metas'] as List?;
      if (metas == null || metas.isEmpty) return;
      final m = metas.first;
      map[key] = {
        'user_id': key,
        'username': m['username'] ?? '',
        'latitude': _toDouble(m['latitude']),
        'longitude': _toDouble(m['longitude']),
        'status': m['status'] ?? 'online',
        'online_at': m['online_at'],
      };
    });
    presenceUsers.value = map;
  }

  void _handleDiff(Map<String, dynamic> payload) {
    final joins = payload['joins'] as Map<String, dynamic>? ?? {};
    final leaves = payload['leaves'] as Map<String, dynamic>? ?? {};
    final current = Map<String, Map<String, dynamic>>.from(presenceUsers.value);

    joins.forEach((key, value) {
      final metas = (value['metas'] as List?) ?? [];
      if (metas.isEmpty) return;
      final m = metas.first;
      current[key.toString()] = {
        'user_id': key.toString(),
        'username': m['username'] ?? '',
        'latitude': _toDouble(m['latitude']),
        'longitude': _toDouble(m['longitude']),
        'status': m['status'] ?? 'online',
        'online_at': m['online_at'],
      };
      debugPrint("📡 [PresenceService] JOIN -> $key");
    });

    leaves.forEach((key, _) {
      current.remove(key.toString());
      debugPrint("📴 [PresenceService] LEAVE -> $key");
    });

    presenceUsers.value = current;
  }

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  /// Chỉ gọi khi user LOGOUT thật sự — không gọi khi rời khỏi MapPage.
  Future<void> stop() async {
    _started = false;
    await _posStream?.cancel();
    await _serviceStatusSub?.cancel();
    try {
      _channel?.leave();
      _socket?.close();
    } catch (_) {}
    _channel = null;
    _socket = null;
    presenceUsers.value = {};
  }
}