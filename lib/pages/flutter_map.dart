import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

class MapPage extends StatefulWidget {
  final String username;
  final String email;

  const MapPage({super.key, required this.username, required this.email});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  LatLng? _currentPosition; // nullable
  final MapController _mapController = MapController();

  PhoenixSocket? _socket;
  PhoenixChannel? _onlineChannel;
  Map<String, Map<String, dynamic>> presenceUsers = {};
  static const double maxDistanceKm = 20.0;

  @override
  void initState() {
    super.initState();
    _initLocationAndConnect();
  }

  @override
  void dispose() {
    _disconnectSocket();
    super.dispose();
  }

  Future<void> _initLocationAndConnect() async {
    await _disconnectSocket();

    // Kiểm tra GPS bật chưa
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text("Vị trí chưa bật"),
            content: const Text("Vui lòng bật GPS để xem bản đồ."),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
      return; // dừng nếu GPS chưa bật
    }

    // Kiểm tra quyền truy cập vị trí
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text("Quyền vị trí bị từ chối"),
              content: const Text("Vui lòng cấp quyền vị trí để xem bản đồ."),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("OK"),
                ),
              ],
            ),
          );
        }
        return; // dừng nếu quyền bị từ chối
      }
    }

    // Lấy vị trí hiện tại
    Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    _currentPosition = LatLng(pos.latitude, pos.longitude);

    // --- Thêm đoạn này để test user khác ---
    presenceUsers['user2@example.com'] = {
      'username': 'user2',
      'latitude': _currentPosition!.latitude + 0.010,
      'longitude': _currentPosition!.longitude + 0.001,
      'online_at': DateTime.now().toString(),
    };
    presenceUsers['user3@example.com'] = {
      'username': 'user3',
      'latitude': _currentPosition!.latitude - 0.001,
      'longitude': _currentPosition!.longitude - 0.010,
      'online_at': DateTime.now().toString(),
    };
    setState(() {});
    // --- Kết thúc test ---

    // Kết nối Phoenix
    await _connectPhoenix();

    // Lắng nghe GPS realtime
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((p) {
      _currentPosition = LatLng(p.latitude, p.longitude);
      _updatePresence();
      if (mounted) setState(() {});
    });

    if (mounted) setState(() {}); // render map lần đầu
  }


  Future<void> _disconnectSocket() async {
    await _onlineChannel?.leave();
    _socket?.close();
    _onlineChannel = null;
    _socket = null;
  }

  Future<void> _connectPhoenix() async {
    _socket = PhoenixSocket("wss://socket.spiritwebs.com/socket/websocket");
    await _socket!.connect();

    _onlineChannel = _socket!.addChannel(topic: "online_users:lobby");

    try {
      await _onlineChannel!.join();
      _updatePresence();
      print("✅ Joined online_users:lobby: ${widget.username}");
    } catch (e) {
      print("❌ Join failed: $e");
    }

    _onlineChannel!.messages.listen((msg) {
      if (msg.event == "presence_state" && msg.payload is Map) {
        _handlePresenceState(Map<String, dynamic>.from(msg.payload as Map));
      }
      if (msg.event == "presence_diff" && msg.payload is Map) {
        _handlePresenceDiff(Map<String, dynamic>.from(msg.payload as Map));
      }
    });
  }

  void _updatePresence() {
    if (_currentPosition == null) return; // đảm bảo đã có vị trí
    _onlineChannel?.push("update_presence", {
      "user_id": widget.email,
      "username": widget.username,
      "latitude": _currentPosition!.latitude,
      "longitude": _currentPosition!.longitude,
    });
  }

  void _handlePresenceState(Map<String, dynamic> payload) {
    presenceUsers.clear();
    payload.forEach((key, value) {
      final meta = (value['metas'] as List).first;
      presenceUsers[key] = {
        'username': meta['username'] ?? 'Visitor',
        'latitude': meta['latitude'] ?? 0.0,
        'longitude': meta['longitude'] ?? 0.0,
        'online_at': meta['online_at']
      };
    });
    _fitBounds();
    if (mounted) setState(() {});
  }

  void _handlePresenceDiff(Map<String, dynamic> payload) {
    payload['joins']?.forEach((key, value) {
      final meta = (value['metas'] as List).first;
      presenceUsers[key] = {
        'username': meta['username'] ?? 'Visitor',
        'latitude': meta['latitude'] ?? 0.0,
        'longitude': meta['longitude'] ?? 0.0,
        'online_at': meta['online_at']
      };
    });

    payload['leaves']?.forEach((key, _) {
      presenceUsers.remove(key);
    });

    _fitBounds();
    if (mounted) setState(() {});
  }

  void _fitBounds() {
    if (_currentPosition == null || presenceUsers.isEmpty) return;

    final nearbyUsers = presenceUsers.values.where((u) {
      final distance = Geolocator.distanceBetween(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
        u['latitude'],
        u['longitude'],
      );
      return distance / 1000 <= maxDistanceKm;
    }).toList();

    if (nearbyUsers.isEmpty) return;

    final points =
    nearbyUsers.map((u) => LatLng(u['latitude'], u['longitude'])).toList();
    points.add(_currentPosition!);

    final minLat = points.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    final maxLat = points.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
    final minLng = points.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    final maxLng = points.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

    final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
    _mapController.fitBounds(bounds, options: FitBoundsOptions(padding: EdgeInsets.all(50)));
  }

  List<Marker> buildMarkers() {
    if (_currentPosition == null) return [];

    final markers = <Marker>[
      Marker(
        point: _currentPosition!,
        width: 50,
        height: 50,
        builder: (ctx) =>
        const Icon(Icons.person_pin_circle, color: Colors.red, size: 40),
      ),
    ];

    presenceUsers.values.forEach((user) {
      final lat = user['latitude'];
      final lng = user['longitude'];
      if (lat == 0.0 && lng == 0.0) return;

      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 40,
          height: 40,
          builder: (ctx) => GestureDetector(
            onTap: () {
              showDialog(
                context: ctx,
                builder: (_) => AlertDialog(
                  title: Text(user['username']),
                  content: Text(
                      "Vị trí: ${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}\nOnline at: ${user['online_at']}"),
                ),
              );
            },
            child:
            const Icon(Icons.person_pin_circle, color: Colors.blue, size: 30),
          ),
        ),
      );
    });

    return markers;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentPosition == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("User Online gần đây")),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(center: _currentPosition!, zoom: 14, minZoom: 3),
        children: [
          TileLayer(
            urlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
            subdomains: const ['a', 'b', 'c'],
          ),
          MarkerLayer(markers: buildMarkers()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          _updatePresence();
          if (mounted) setState(() {});
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
