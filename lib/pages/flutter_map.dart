import 'dart:async';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:http/http.dart' as http;
import '../services/wordpress_service.dart';
//import 'chat_page_phoenix.dart';
import 'chat_page.dart';
import 'product_detail_page.dart';
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';

IconData getIconByType(String type) {
  switch (type) {
    case 'Nhậu':   return Icons.liquor;   // chai rượu/bia
    case 'Bar/Pub':   return Icons.nightlife;           // bar đêm
    case 'Beer club': return Icons.sports_bar;          // ly bia
    case 'Karaoke':   return Icons.mic_external_on;   // mic cầm tay karaoke
    default:          return Icons.location_on;
  }
}

Color getColorByType(String type) {
  switch (type) {
    case 'Nhậu':       return Colors.deepOrange;
    case 'Bar/Pub':     return Colors.purple;
    case 'Beer club':   return Colors.amber;
    case 'Karaoke':      return Colors.pinkAccent;
    default:             return Colors.orangeAccent;
  }
}


class MapPage extends StatefulWidget {
  final int userId;
  final String username;
  final String email;

  const MapPage({
    super.key,
    required this.userId,
    required this.username,
    required this.email,
  });

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage>
    with WidgetsBindingObserver {
  LatLng? _currentPosition;
  bool _loadingPubs = false;
  bool _loading = true;
  bool enablePubs = false;



  final MapController _mapController = MapController();

  PhoenixSocket? _socket;
  PhoenixChannel? _onlineChannel;

  Map<String, Map<String, dynamic>> presenceUsers = {};
  List<Map<String, dynamic>> nearbyPubs = [];
  List<Map<String, dynamic>> nearbyDeals = [];

  StreamSubscription<Position>? _posStream;
  DateTime? _lastUpdate;

  late WordPressService wpService;
  String jwtToken = "";

  bool _boundsFitted = false;

  // =====> Đặt parseDouble ở đây
  double parseDouble(dynamic v) {
    if (v == null) return 0.0;

    if (v is double) return v;
    if (v is int) return v.toDouble();

    if (v is String) return double.tryParse(v) ?? 0.0;

    return 0.0;
  }


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initTokenAndLocation(); // vẫn giữ như cũ
    });

    // 👇 Thêm đoạn lắng nghe GPS
    if (!kIsWeb) {
      Geolocator.getServiceStatusStream().listen((status) {
        if (status == ServiceStatus.enabled) {
          print('✅ GPS vừa được bật');
          _initTokenAndLocation(); // gọi lại để load map ngay
        } else {
          print('⚠️ GPS bị tắt');
          setState(() {
            _loading = true;
          });
        }
      });
    }

  }


  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posStream?.cancel();
    _disconnectSocket();
    super.dispose();
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint("📱 App lifecycle: $state");

    if (state == AppLifecycleState.resumed) {
      _sendStatus("online");
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _sendStatus("background");
    }
  }

  void _sendStatus(String status) {
    if (_currentPosition == null) return;

    _onlineChannel?.push("update_presence", {
      "user_id": widget.userId,
      "username": widget.username,
      "latitude": _currentPosition!.latitude,
      "longitude": _currentPosition!.longitude,
      "status": status, // 👈 online | background
      "updated_at": DateTime.now().toIso8601String(),
    });

    debugPrint("🚦 Send status = $status");
  }



  void _moveCameraOnce() {
    if (_currentPosition == null) return; // tránh null-crash đã nói ở câu trước

    if (!_boundsFitted) {
      if (presenceUsers.isNotEmpty) {
        _fitBoundsOnce(); // tự set _boundsFitted = true bên trong
      } else {
        _boundsFitted = true;
        _mapController.move(_currentPosition!, 14);
      }
    }
    // nếu đã fitted rồi thì KHÔNG move/fit lại nữa
  }

  // ===== INIT TOKEN + LOCATION =====
  Future<void> _initTokenAndLocation() async {
    try {
      jwtToken = await _fetchToken();
      wpService = WordPressService("${AppConfig.webDomain}");
      await _initLocationAndConnect();
    } catch (e) {
      debugPrint("❌ Lỗi init: $e");
      if (mounted) await _showAlert("Lỗi", "Không thể khởi tạo token hoặc vị trí.");
    }
  }

  Future<String> _fetchToken() async {
    final url = Uri.parse("${AppConfig.webDomain}/api/get-jwt-token");
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['token'] ?? "";
    }
    throw Exception("Failed to fetch token (${response.statusCode})");
  }

  Future<void> loadNearbyDeals(double lat, double lng) async {
    final url = Uri.parse(
      "${AppConfig.webDomain}/wp-json/spiritwebs/v1/nearby-deals"
          "?lat=$lat&lng=$lng&radius=50",
    );

    final res = await http.get(url);

    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as List;

      final filtered = data.where((e) {
        final timeStr = e['time']?.toString();

        if (timeStr == null || timeStr.isEmpty) {
          return true;
        }

        final dealTime = DateTime.tryParse(timeStr);

        if (dealTime == null) {
          return true;
        }

        // ẩn sau 1 ngày kể từ giờ hẹn
        return DateTime.now().difference(dealTime).inHours < 24;
      }).toList();
      nearbyDeals = data.map<Map<String, dynamic>>((e) => {
        "id": e['ID'],
        "title": e['post_title'],
        "lat": parseDouble(e['lat']),
        "lng": parseDouble(e['lng']),
        "time": e['time'],
        "type": e['type'] ?? "",
      }).toList();

      setState(() {});
    }
  }


  Future<List<Map<String, dynamic>>> loadNearbyPubs(double lat, double lng) async {
    final url = Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/existing-pubs");
    final response = await http.get(url, headers: {"Authorization": "Bearer $jwtToken"});

    List<Map<String, dynamic>> pubsFromDB = [];
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as List;
      pubsFromDB = data.map<Map<String, dynamic>>((e) => {
        "name": e['name'] ?? "Chưa cập nhật",
        "type": e['type'] ?? "Chưa cập nhật",
        "address": e['address'] ?? "Chưa cập nhật",
        "image": e['image'] ?? "",
        "avg_rating": e['avg_rating'] ?? 0,
        "images": e['images'] ?? [],         // tất cả ảnh từ foody_data
        "open_time": e['open_time'] ?? "",   // giờ mở cửa
        "price_range": e['price_range'] ?? "", // giá
        "ratings": e['ratings'] ?? {},       // rating từng mục
        "lat": e['lat'] ?? 0,
        "lng": e['lng'] ?? 0,
      }).toList();
    }

    final pubsFromAPI = await fetchNearbyPubs(lat, lng);

    final allPubs = [...pubsFromDB];
    for (var pub in pubsFromAPI) {
      if (!allPubs.any((e) =>
      e['latitude'] == pub['latitude'] && e['longitude'] == pub['longitude'])) {
        allPubs.add(pub);
        await savePubsToServer([pub]);
      }
    }

    // ✅ Lọc quán trong bán kính 5km
    const radiusKm = 5.0;
    final Distance distance = const Distance();
    final nearbyOnly = allPubs.where((pub) {
      final p = LatLng(parseDouble(pub['latitude']), parseDouble(pub['longitude']));
      final d = distance.as(LengthUnit.Kilometer, LatLng(lat, lng), p);
      return d <= radiusKm;
    }).toList();

    return nearbyOnly;
  }



  // ===== FETCH PUBS =====
  Future<List<Map<String, dynamic>>> fetchNearbyPubs(double lat, double lng) async {
    final existingPubs = await fetchExistingPubs(); // set "lat_lng" đã tồn tại

    final overpassQuery = '''
[out:json][timeout:15];
node["amenity"~"pub|bar|biergarten"](around:500000,$lat,$lng);
out center tags;
''';

    final response = await http.post(
      Uri.parse("https://overpass-api.de/api/interpreter"),
      headers: {"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"},
      body: {'data': overpassQuery},
    );

    if (response.statusCode != 200) throw Exception('Fetch pubs failed: ${response.statusCode}');

    final decodedBody = utf8.decode(response.bodyBytes);
    final data = jsonDecode(decodedBody);
    final elements = (data['elements'] ?? []) as List;

    List<Map<String, dynamic>> pubs = [];
    int reverseCount = 0;

    for (var e in elements) {
      final tags = e['tags'] ?? {};
      final nodeLat = e['lat'] ?? e['center']?['lat'];
      final nodeLng = e['lon'] ?? e['center']?['lon'];
      if (nodeLat == null || nodeLng == null) continue;

      // Skip nếu đã tồn tại
      if (existingPubs.contains("${nodeLat}_${nodeLng}")) {
        debugPrint("✅ ${tags['name'] ?? 'Quán nhậu'} → exists, skip");
        continue;
      }

      final name = tags['name:vi'] ?? tags['name'] ?? '';
      final type = tags['amenity'] ?? 'Không rõ loại';

      // Lấy toàn bộ địa chỉ từ các tag bắt đầu bằng addr:
      String address = tags.entries
          .where((entry) => entry.key.startsWith('addr:') && entry.value.toString().isNotEmpty)
          .map((entry) => entry.value.toString())
          .join(', ');

      debugPrint("📍 Address from tags hung: $address");

      // Reverse geocoding nếu không có tag addr:* và chưa vượt quá 5 lần
      if (address.isEmpty && reverseCount < 5) {
        try {
          final reverseUrl = Uri.parse(
              "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$nodeLat&lon=$nodeLng&accept-language=vi");
          final reverseRes = await http.get(reverseUrl, headers: {
            "User-Agent": "SpiritWebsApp/1.0 (${widget.email})"
          });
          if (reverseRes.statusCode == 200) {
            final revData = jsonDecode(utf8.decode(reverseRes.bodyBytes));
            address = revData['display_name'] ?? "Chưa cập nhật";
          }
        } catch (_) {
          address = "Chưa cập nhật";
        }
        reverseCount++;
        await Future.delayed(const Duration(milliseconds: 150));
      }

      pubs.add({
        'name': name,
        'type': type,
        'address': address.isEmpty ? "Chưa cập nhật" : address,
        'latitude': nodeLat,
        'longitude': nodeLng,
      });
    }

    return pubs;
  }

  Future<Set<String>> fetchExistingPubs() async {
    final url = Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/existing-pubs");
    final response = await http.get(url, headers: {
      "Authorization": "Bearer $jwtToken",
    });
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as List;
      // Tạo set dạng "lat_lng" để check nhanh
      return data.map((e) => "${e['lat']}_${e['lng']}").toSet();
    }
    return {};
  }


  Future<void> savePubsToServer(List<Map<String, dynamic>> pubs) async {
    const apiUrl = "${AppConfig.webDomain}/wp-json/spiritwebs/v1/save-pub";
    for (var pub in pubs) {
      try {
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer $jwtToken",
          },
          body: jsonEncode({
            "name": pub['name'],
            "lat": pub['latitude'],
            "lng": pub['longitude'],
            "type": pub['type'],
            "address": pub['address'],
            "rating": 0,
            "osm_id": 0,
          }),
        );
        if (response.statusCode == 200) {
          final res = jsonDecode(response.body);
          debugPrint("✅ ${pub['name']} → ${res['status']}");
        } else {
          debugPrint("⚠️ Gửi thất bại (${response.statusCode}) cho ${pub['name']}");
        }
      } catch (e) {
        debugPrint("❌ Lỗi gửi quán ${pub['name']}: $e");
      }
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  // ===== LOCATION + SOCKET =====
  Future<void> _initLocationAndConnect() async {
    await _disconnectSocket();

    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!mounted) return;
      await _showAlert("Vị trí chưa bật", "Vui lòng bật GPS để xem bản đồ.");
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      await _showAlert("Quyền vị trí bị từ chối", "Vui lòng cấp quyền vị trí để xem bản đồ.");
      return;
    }

    final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    _currentPosition = LatLng(pos.latitude, pos.longitude);

    _currentPosition = LatLng(pos.latitude, pos.longitude);

    // 🟢 LOAD KÈO GẦN ĐÂY (từ wp_postmeta lat/lng)
    await loadNearbyDeals(
      pos.latitude,
      pos.longitude,
    );



    if (_currentPosition != null) {
      // 1️⃣ Lấy tất cả user thật từ presenceUsers
      List<Map<String, dynamic>> realUsers = presenceUsers.values
          .map((u) => {
        "user_id": u['user_id'],
        "username": u['username'],
        "latitude": u['latitude'],
        "longitude": u['longitude'],
        "online_at": u['online_at'],
      })
          .toList();

// 2️⃣ Test user
      List<Map<String, dynamic>> testUsers = [
        /*{
          "user_id": "2",
          "username": "User Two",
          "latitude": _currentPosition!.latitude + 0.0001,
          "longitude": _currentPosition!.longitude + 0.0001,
          "online_at": DateTime.now().toIso8601String(),
        }
        {
          "user_id": "3",
          "username": "User Three",
          "latitude": _currentPosition!.latitude - 0.015,
          "longitude": _currentPosition!.longitude - 0.015,
          "online_at": DateTime.now().toIso8601String(),
        },
        {
          "user_id": "4",
          "username": "User Four",
          "latitude": _currentPosition!.latitude + 0.02,
          "longitude": _currentPosition!.longitude - 0.01,
          "online_at": DateTime.now().toIso8601String(),
        },*/
      ];




      // Thêm user test
      for (var u in testUsers) {
        presenceUsers[u['user_id']] = u;
      }


      if (mounted) {
        setState(() {
          _boundsFitted = false; // reset để zoom lại
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _moveCameraOnce();
        });
      }
    }






    if (mounted) setState(() {
      _loadingPubs = true; // 🆕 Bật trạng thái loading
    });

// 🟢 Bước 1: Load nhanh từ DB (trong 7km)
    try {
      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/spiritwebs/v1/nearby-pubs"
            "?lat=${pos.latitude}&lng=${pos.longitude}&radius=7",
      );

      final response = await http.get(
        url,
        headers: {"Authorization": "Bearer $jwtToken"},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;

        nearbyPubs = data.map((e) => {
          "name": e['name'] ?? "Chưa cập nhật",
          "type": e['type'] ?? "Chưa cập nhật",
          "address": e['address'] ?? "Chưa cập nhật",
          "latitude": e['lat'],
          "longitude": e['lng'],
          "image": e['image'] ?? "",
          "images": e['images'] ?? [],
          "avg_rating": e['avg_rating'] ?? 0,
          "open_time": e['open_time'] ?? "",
          "price_range": e['price_range'] ?? "",
          "ratings": e['ratings'] ?? {},
          "distance": e['distance'], // optional
        }).toList();
      }

      if (mounted) setState(() { _loadingPubs = false; });
    } catch (e) {
      debugPrint("❌ Lỗi load DB: $e");
      if (mounted) setState(() { _loadingPubs = false; });
    }


// 🟣 Bước 2: Sau 3 giây, âm thầm cập nhật quán mới từ API
    /*Future.delayed(const Duration(seconds: 3), () async {
      try {
        final pubsFromAPI = await fetchNearbyPubs(pos.latitude, pos.longitude);
        int newCount = 0;

        for (var pub in pubsFromAPI) {
          bool exists = nearbyPubs.any((e) =>
          (parseDouble(e['latitude']) - parseDouble(pub['latitude'])).abs() < 0.0001 &&
              (parseDouble(e['longitude']) - parseDouble(pub['longitude'])).abs() < 0.0001);

          if (!exists) {
            await savePubsToServer([pub]);
            nearbyPubs.add(pub);
            newCount++;
          }
        }

        if (mounted && newCount > 0) {
          setState(() {});
          debugPrint("✅ Đã thêm $newCount quán mới trong 7km!");
        }
      } catch (e) {
        debugPrint("⚠️ Lỗi cập nhật quán mới: $e");
      }
    });*/




    await _connectPhoenix();

    _posStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 50,
      ),
    ).listen((p) {
      final now = DateTime.now();
      if (_lastUpdate == null || now.difference(_lastUpdate!) > const Duration(seconds: 5)) {
        _lastUpdate = now;
        _currentPosition = LatLng(p.latitude, p.longitude);
        _updatePresence();
        int userIdInt = widget.userId;
        updateUserLocation(
          jwtToken: jwtToken,
          userId: userIdInt,  // <- thêm dòng này
          latitude: p.latitude,
          longitude: p.longitude,
        );
        if (mounted) setState(() {});
      }
    });



  }


  Future<void> _showAlert(String title, String message) async {
    if (!mounted) return;
    return showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent, // để hiện gradient
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1E3A8A), Color(0xFFFF7F50)], // 💙🧡 giống ProfilePage
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                child: const Text("Đóng"),
              ),
            ],
          ),
        ),
      ),
    );
  }


  Future<void> _disconnectSocket() async {
    try {
      _onlineChannel?.leave();
      _socket?.close();
    } catch (_) {}
    _onlineChannel = null;
    _socket = null;
  }

  Future<void> _connectPhoenix() async {
    try {
      // Lấy vị trí hiện tại nếu null
      if (_currentPosition == null) {
        final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
        _currentPosition = LatLng(pos.latitude, pos.longitude);
      }

      if (_currentPosition == null) {
        debugPrint("❌ Vị trí hiện tại null, không thể join channel");
        return;
      }

      // Chuyển userId sang integer nếu cần
      int userIdInt = widget.userId;


      // Payload an toàn
      final joinParams = {
        "user_id": userIdInt,
        "username": widget.username.isNotEmpty ? widget.username : "hung",
        "latitude": _currentPosition!.latitude,
        "longitude": _currentPosition!.longitude,
      };

      debugPrint("📡 Phoenix join payload: $joinParams");

      // Khởi tạo socket
      _socket = PhoenixSocket(AppConfig.websocketUrl);
      await _socket!.connect();

      // Tạo channel
      _onlineChannel = _socket!.addChannel(
        topic: "online_users:lobby",
        parameters: joinParams,
      );

      // Join channel với try/catch để tránh crash
      try {
        await _onlineChannel!.join();
        debugPrint("✅ Joined online_users:lobby thành công");

        // Gửi presence ban đầu
        _sendInitialPresence();

        // Lắng nghe tất cả event
        _onlineChannel!.messages.listen((event) {
          final eventName = event.event.toString().toLowerCase();
          debugPrint("📩 Event received: '$eventName' -> ${event.payload}");

          if (eventName.contains("presence_state")) {
            try {
              _handlePresenceState(Map<String, dynamic>.from(event.payload as Map));
            } catch (e) {
              debugPrint("❌ Error handling presence_state: $e");
            }
          } else if (eventName.contains("presence_diff")) {
            try {
              debugPrint("🔹 Handling presence_diff: ${event.payload}");
              _handlePresenceDiff(Map<String, dynamic>.from(event.payload as Map));
            } catch (e, st) {
              debugPrint("❌ Error handling presence_diff: $e\n$st");
            }
          }
        });

      } catch (joinErr) {
        debugPrint("❌ Phoenix join failed: $joinErr");
        // Có thể retry sau vài giây nếu muốn
      }
    } catch (e) {
      debugPrint("❌ ConnectPhoenix error: $e");
    }
  }

  Future<void> updateUserLocation({
    required String jwtToken,
    required int userId,          // thêm userId
    required double latitude,
    required double longitude,
  }) async {
    final url = Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/update-user-location");

    try {
      final response = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $jwtToken",
        },
        body: jsonEncode({
          "user_id": userId,        // gửi userId lên server
          "last_latitude": latitude,
          "last_longitude": longitude,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print("Cập nhật vị trí thành công cho userId=$userId!");
      } else {
        print("Lỗi cập nhật vị trí: ${response.statusCode}, ${response.body}");
      }
    } catch (e) {
      print("Exception: $e");
    }
  }





  void _sendInitialPresence() {
    _sendStatus("online");
    if (_currentPosition == null) return;
    int userIdInt = widget.userId;


    _onlineChannel?.push("update_presence", {
      "user_id": userIdInt,
      "username": widget.username.isNotEmpty ? widget.username : "hung2",
      "latitude": _currentPosition!.latitude,
      "longitude": _currentPosition!.longitude,
    });
  }


  void _updatePresence() => _sendInitialPresence();


// ===== HANDLE PRESENCE STATE =====
  void _handlePresenceState(Map<String, dynamic> payload) {
    presenceUsers.clear();

    payload.forEach((key, value) {
      final metasList = value['metas'] as List;
      if (metasList.isEmpty) return;

      final metaInner = metasList.first; // fix: không nested 'metas' nữa

      presenceUsers[key] = {
        'username': metaInner['username'] ?? 'hung3',
        'user_id': key,
        'latitude': parseDouble(metaInner['latitude']),
        'longitude': parseDouble(metaInner['longitude']),
        'status': metaInner['status'] ?? "online",   // 👈 thêm
        'online_at': metaInner['online_at'],
      };
    });

    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _moveCameraOnce();
    });
    // zoom map đến tất cả users
  }

// ===== HANDLE PRESENCE DIFF =====
  void _handlePresenceDiff(Map<String, dynamic> payload) {
    bool changed = false;

    final joins = payload['joins'] as Map<String, dynamic>? ?? {};
    final leaves = payload['leaves'] as Map<String, dynamic>? ?? {};

    joins.forEach((key, value) {
      final metas = (value['metas'] as List?) ?? [];
      if (metas.isEmpty) return;

      final meta = metas.first;
      final username = meta['username'] ?? 'hung4';
      final lat = parseDouble(meta['latitude']);
      final lng = parseDouble(meta['longitude']);


      presenceUsers[key.toString()] = {
        'user_id': key.toString(),
        'username': username,
        'latitude': lat,
        'longitude': lng,
        'status': meta['status'] ?? "online",        // 👈 thêm
        'online_at': meta['online_at'],
      };
      debugPrint("📡 JOIN -> $key, $username, lat=$lat, lng=$lng");
      changed = true;
    });

    leaves.forEach((key, _) {
      presenceUsers.remove(key.toString());
      debugPrint("📴 LEAVE -> $key");
      changed = true;
    });

    if (changed) {
      debugPrint("📍 Updated presenceUsers: ${presenceUsers.values.toList()}");
      setState(() {}); // đảm bảo UI map cập nhật
    }
  }


// Fit bounds linh hoạt, dùng cho join mới
  void _fitBoundsDynamic() {
    if (_currentPosition == null || presenceUsers.isEmpty) return;

    final points = presenceUsers.values
        .map((u) => LatLng(u['latitude'], u['longitude']))
        .toList()
      ..add(_currentPosition!);

    _mapController.fitBounds(
      LatLngBounds(
        LatLng(points.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
            points.map((p) => p.longitude).reduce((a, b) => a < b ? a : b)),
        LatLng(points.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
            points.map((p) => p.longitude).reduce((a, b) => a > b ? a : b)),
      ),
      options: const FitBoundsOptions(padding: EdgeInsets.all(50)),
    );
  }


  void _fitBoundsOnce() {
    if (_boundsFitted || _currentPosition == null || presenceUsers.isEmpty) return;
    _boundsFitted = true;
    final points = presenceUsers.values.map((u) => LatLng(u['latitude'], u['longitude'])).toList()..add(_currentPosition!);
    _mapController.fitBounds(
      LatLngBounds(
        LatLng(points.map((p) => p.latitude).reduce((a, b) => a < b ? a : b),
            points.map((p) => p.longitude).reduce((a, b) => a < b ? a : b)),
        LatLng(points.map((p) => p.latitude).reduce((a, b) => a > b ? a : b),
            points.map((p) => p.longitude).reduce((a, b) => a > b ? a : b)),
      ),
      options: const FitBoundsOptions(padding: EdgeInsets.all(50)),
    );
  }

  Color getDealColor(dynamic timeStr) {
    if (timeStr == null || timeStr.toString().isEmpty) {
      return Colors.green;
    }

    try {
      final dealTime =
      DateFormat('dd/MM/yyyy HH:mm').parse(timeStr.toString());

      final now = DateTime.now();
      final diff = dealTime.difference(now);

      // Đang diễn ra: từ lúc bắt đầu đến 3h sau
      if (now.isAfter(dealTime) &&
          now.isBefore(dealTime.add(const Duration(hours: 24)))) {
        return Colors.red;
      }

      // Đã kết thúc hơn 24h
      if (now.isAfter(dealTime.add(const Duration(hours: 24)))) {
        return Colors.grey;
      }

      // Sắp diễn ra trong 3h
      if (diff.inHours <= 3) {
        return Colors.orange;
      }

      // Hôm nay
      if (diff.inHours <= 24) {
        return Colors.amber;
      }

      // Tương lai
      return Colors.green;
    } catch (_) {
      return Colors.green;
    }
  }

  List<Marker> _buildMarkers() {
    if (_currentPosition == null) return [];

    final markers = <Marker>[];

    // Marker của chính bạn
    // Marker của chính bạn (giống user khác nhưng màu xanh dương)
    markers.add(
      Marker(
        point: _currentPosition!,
        width: 80,
        height: 90,
        builder: (_) => Stack(
          alignment: Alignment.center,
          children: [
            // Pulse hơi xa xuống dưới 1 chút
            const Positioned(
              bottom: 2,
              child: _PulseMarker(
                color: Colors.blue,
                size: 16,
              ),
            ),

            // Bubble + mũi nhọn tách nhẹ
            Positioned(
              bottom: 14,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 4),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person, size: 12, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          "Tôi",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 5), // 👈 tạo khoảng hở nhẹ

                  const Icon(
                    Icons.arrow_drop_down,
                    color: Colors.blue,
                    size: 18,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );


    // Users khác
    final defaultLat = 10.0; // tọa độ mặc định nếu 0
    final defaultLng = 106.0;
    print("HUNGNE: ${presenceUsers.values}");

    for (var user in presenceUsers.values) {
      final isCurrentUser = user['user_id'].toString() == widget.userId.toString();
      if (isCurrentUser) continue; // không vẽ thêm chính mình

      // Lấy tọa độ, nếu user khác mà là 0 thì dùng mặc định
      final lat = parseDouble(user['latitude']) == 0.0 ? defaultLat : parseDouble(user['latitude']);
      final lng = parseDouble(user['longitude']) == 0.0 ? defaultLng : parseDouble(user['longitude']);

      // Thông tin người muốn chat
      final targetUserId = user['user_id'].toString();
      final targetUsername = user['username'] ?? "hung5";

      // ==== Thêm trạng thái user ====
      final status = user['status'] ?? "online"; // "online" | "background" | "offline"
      Color statusColor;
      String statusText;

      switch (status) {
        case "background":
          statusColor = Colors.orange;
          statusText = "Away";
          break;
        case "offline":
          statusColor = Colors.red;
          statusText = "Offline";
          break;
        default:
          statusColor = Colors.green;
          statusText = "Online";
      }

      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 90,
          height: 120,
          builder: (_) => SizedBox(
            width: 90,
            height: 95,
            child: Stack(
              alignment: Alignment.bottomCenter,
              clipBehavior: Clip.none,
              children: [

                // ===== PULSE (ĐÁY) =====
                Positioned(
                  bottom: 0,
                  child: _PulseMarker(
                    color: statusColor,
                    size: 20,
                  ),
                ),

                // ===== ARROW =====
                Positioned(
                  bottom: 18,
                  child: Transform.rotate(
                    angle: 3.14,
                    child: const Icon(
                      Icons.arrow_drop_up,
                      color: Colors.black54,
                      size: 14,
                    ),
                  ),
                ),

                // ===== CHAT =====
                Positioned(
                  bottom: 32,
                  child: GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ChatPage(
                            username: widget.username,
                            userId: widget.userId,
                            targetUser: targetUsername,
                            targetId: int.parse(targetUserId),
                            targetAvatar: user['avatar'] ?? "",
                            serverUrl: AppConfig.websocketUrl,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        "Chat",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ),

                // ===== USER STATUS =====
                Positioned(
                  bottom: 55,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      "${user['username'] ?? 'Unknown'} • $statusText",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }


    // Pubs (giữ nguyên)
    /*for (var pub in nearbyPubs) {
      final lat = parseDouble(pub['latitude']);
      final lng = parseDouble(pub['longitude']);
      if (lat == 0.0 && lng == 0.0) continue;

      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 45,
          height: 45,
          builder: (_) => GestureDetector(
            onTap: () => _showPubDialog(pub),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
              ),
              child: Icon(
                getIconByType(pub['type'] ?? ""),
                color: getColorByType(pub['type'] ?? ""),
                size: 25,
              ),
            ),
          ),

        ),
      );
    }*/

    // ===== KÈO GẦN ĐÂY =====
    for (var deal in nearbyDeals) {
      if (deal['lat'] == 0.0 || deal['lng'] == 0.0) continue;

      // ===== THÊM FILTER KÈO HẾT HẠN =====
      final timeStr = deal['time']?.toString();
      debugPrint("DEAL: $deal");
      if (timeStr != null && timeStr.isNotEmpty) {
        final endTime = DateTime.tryParse(timeStr);

        if (endTime != null) {
          final remaining = endTime.difference(DateTime.now());

          // ❌ bỏ kèo đã kết thúc > 1 ngày
          if (remaining.isNegative && remaining.inDays.abs() >= 1) {
            continue;
          }
        }
      }

      markers.add(
        Marker(
          point: LatLng(deal['lat'], deal['lng']),
          width: 65,
          height: 65,
          builder: (_) {
            final color = getDealColor(deal['time']);

            return GestureDetector(
              onTap: () {
                showDialog(
                  context: context,
                  barrierColor: Colors.black.withOpacity(0.4),
                  builder: (_) => _DealDetailDialog(
                    deal: deal,
                    dealColor: color,
                    wpService: wpService,
                    primaryBlue: const Color(0xFF1E3A8A),
                    accentOrange: const Color(0xFFFF7F50),
                  ),
                );
              },
              child: _GroupMarker(
                count: (deal['participants'] as List?)?.length ?? 1,
                color: color,
                dealType: deal['type']?.toString() ?? "",
              ),
            );
          },
        ),
      );
    }


    return markers;
  }




  void _showPubDialog(Map<String, dynamic> pub) {
    print("DEBUG pub: $pub");

    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7, // tối đa 70% màn hình
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tên quán
                Text(pub['name'] ?? "Đang cập nhật",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 12),

                // Slider ảnh
                if ((pub['images'] != null && (pub['images'] as List).isNotEmpty) ||
                    (pub['image'] != null && pub['image'].toString().isNotEmpty))
                  SizedBox(
                    height: 180, // fix chiều cao
                    child: PageView.builder(
                      // Gộp pub['image'] + pub['images'] vào itemCount
                      itemCount: ((pub['images'] != null ? (pub['images'] as List).length : 0) +
                          (pub['image'] != null && pub['image'].toString().isNotEmpty ? 1 : 0)),
                      itemBuilder: (context, index) {
                        String img;
                        if (pub['image'] != null && pub['image'].toString().isNotEmpty) {
                          if (index == 0) {
                            img = pub['image'];
                          } else {
                            img = (pub['images'] as List)[index - 1];
                          }
                        } else {
                          img = (pub['images'] as List)[index];
                        }

                        return ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            img,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey[300],
                              child: const Center(child: Icon(Icons.image_not_supported)),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),


                // Thông tin scrollable
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("🍺 Loại hình: ${pub['type'] ?? 'Đang cập nhật'}"),
                        const SizedBox(height: 6),
                        Text("📍 Địa chỉ: ${pub['address'] ?? 'Đang cập nhật'}"),
                        const SizedBox(height: 6),
                        Text(
                          "🕒 Giờ mở cửa: ${(pub['open_time'] ?? 'Chưa cập nhật').toString().replaceAll('&nbsp;', ' ')}",
                        ),

                        const SizedBox(height: 6),
                        Text("💰 Giá: ${pub['price_range'] ?? 'Chưa cập nhật'}"),
                        const SizedBox(height: 6),
                        Text("⭐ Đánh giá tổng: ${pub['avg_rating'] ?? 'Chưa có'}"),
                        const SizedBox(height: 6),
                        // Rating từng mục
                        /*if (pub['ratings'] != null)
                          if (pub['ratings'] is Map && (pub['ratings'] as Map).isNotEmpty)
                            ...((pub['ratings'] as Map).entries.map((e) {
                              return Text("${e.key}: ${e.value}");
                            }).toList())
                          else if (pub['ratings'] is List && (pub['ratings'] as List).isNotEmpty)
                            ...((pub['ratings'] as List).map((e) {
                              return Text(e.toString());
                            }).toList()),
                        const SizedBox(height: 12),*/
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Nút đóng
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Đóng"),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_currentPosition == null) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1E3A8A), Color(0xFFFF7F50)], // 💙🧡 giống ProfilePage
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 🌍 Hiệu ứng vòng tròn lan tỏa
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: Duration(seconds: 2),
                  curve: Curves.easeInOut,
                  builder: (context, value, _) => Container(
                    width: 80 + value * 20,
                    height: 80 + value * 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent.withOpacity(0.3 * (1 - value)),
                    ),
                  ),
                  onEnd: () {},
                ),
                const SizedBox(height: 20),
                const Text(
                  "Đang định vị và khởi tạo bản đồ...",
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }



    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight + 8),
        child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 6,
          centerTitle: true,
          // icon màu trắng (back button)
          iconTheme: const IconThemeData(color: Colors.white),
          // flexibleSpace để vẽ gradient + bo góc dưới
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1E3A8A), Color(0xFFFF7F50)], // xanh đậm -> cam (brand)
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(18)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
          ),
          title: const Text(
            "Tìm bạn và kèo gần đây",
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.2,
            ),
          ),
          // action ví dụ (tuỳ bạn có cần hay không), giữ làm nút refresh giống floating button
          actions: [
            IconButton(
              icon: const Icon(Icons.location_searching),
              onPressed: () {
                // refresh nhỏ: gọi lại fit bounds + setState
                // nếu đang ở trong class, dùng:
                // _fitBoundsOnce(); setState(() {});
                // để tránh lỗi khi copy, giữ empty hoặc tuỳ chỉnh
              },
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(center: _currentPosition!, zoom: 14, minZoom: 3, maxZoom: 18),
            children: [
             /* TileLayer(
                urlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
                subdomains: const ['a', 'b', 'c'],
                retinaMode: false, // ✅ thêm dòng này
                tileSize: 256,
              ),*/
              TileLayer(
                urlTemplate:
                "https://api.maptiler.com/maps/streets/{z}/{x}/{y}.png?key=ekMdlA2wzoBPrxkE0tKf",
                userAgentPackageName: 'com.spiritwebs.app',
              ),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          if (_loadingPubs)
            Positioned(
              top: 20,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    "Đang tải...",
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
        ],
      ),
      /*floatingActionButton: FloatingActionButton(
        onPressed: () {
          _updatePresence();
          if (mounted) setState(() {});
        },
        child: const Icon(Icons.refresh),
      ),*/
    );
  }
}
class _PulseMarker extends StatefulWidget {
  final Color color;
  final double size;

  const _PulseMarker({required this.color, required this.size});

  @override
  State<_PulseMarker> createState() => _PulseMarkerState();
}

class _PulseMarkerState extends State<_PulseMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size * 3,
      height: widget.size * 3,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Vòng tròn lan tỏa
          ScaleTransition(
            scale: Tween<double>(begin: 0.5, end: 2.0).animate(
              CurvedAnimation(parent: _controller, curve: Curves.easeOut),
            ),
            child: FadeTransition(
              opacity: Tween<double>(begin: 0.6, end: 0.0).animate(_controller),
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withOpacity(0.4),
                ),
              ),
            ),
          ),

          // Icon chính
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withOpacity(0.6),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(Icons.person, color: Colors.white, size: 14),
          ),
        ],
      ),
    );
  }
}

class _GroupMarker extends StatefulWidget {
  final int count; // số người
  final double size;
  final Color color;
  final String dealType; // "" nếu chưa có loại hình

  const _GroupMarker({
    required this.count,
    this.size = 14,
    this.color = Colors.redAccent,
    this.dealType = "",
  });

  @override
  State<_GroupMarker> createState() => _GroupMarkerState();
}


// ==================== REPLACE TOÀN BỘ _DealDetailDialog ====================

class _DealDetailDialog extends StatefulWidget {
  final Map<String, dynamic> deal;
  final Color dealColor;
  final WordPressService wpService;
  final Color primaryBlue;
  final Color accentOrange;

  const _DealDetailDialog({
    required this.deal,
    required this.dealColor,
    required this.wpService,
    required this.primaryBlue,
    required this.accentOrange,
  });

  @override
  State<_DealDetailDialog> createState() => _DealDetailDialogState();
}

class _DealDetailDialogState extends State<_DealDetailDialog> {
  bool _loadingDetail = false;

  // ===== Status info =====
  Map<String, dynamic> get _statusInfo {
    final color = widget.dealColor;
    if (color == Colors.red) return {"label": "Đang diễn ra", "icon": Icons.local_fire_department};
    if (color == Colors.grey) return {"label": "Đã kết thúc", "icon": Icons.event_busy};
    if (color == Colors.orange) return {"label": "Sắp bắt đầu", "icon": Icons.timer};
    if (color == Colors.amber) return {"label": "Hôm nay", "icon": Icons.today};
    return {"label": "Sắp tới", "icon": Icons.event_available};
  }

  // ===== Type styling =====
  Map<String, dynamic> _getTypeStyle(String type) {
    switch (type) {
      case 'Nhậu':
        return {"bg": const Color(0xFFFEF0E8), "text": const Color(0xFFB84A18), "icon": Icons.liquor};
      case 'Bar/Pub':
        return {"bg": const Color(0xFFEDE9FE), "text": const Color(0xFF5B21B6), "icon": Icons.local_bar};
      case 'Beer club':
        return {"bg": const Color(0xFFFEF9E7), "text": const Color(0xFF92400E), "icon": Icons.sports_bar};
      case 'Karaoke':
        return {"bg": const Color(0xFFFDE8F0), "text": const Color(0xFF9D174D), "icon": Icons.mic};
      default:
        return {"bg": const Color(0xFFF3F4F6), "text": const Color(0xFF374151), "icon": Icons.place};
    }
  }

  String get _formattedTime {
    final timeStr = widget.deal['time']?.toString();
    if (timeStr == null || timeStr.isEmpty) return "Chưa cập nhật thời gian";
    try {
      final t = DateFormat('dd/MM/yyyy HH:mm').parse(timeStr);
      return DateFormat('HH:mm — EEEE, dd/MM/yyyy', 'vi').format(t);
    } catch (_) {
      return timeStr;
    }
  }

  String get _title {
    final raw = widget.deal['title'];
    if (raw == null) return 'Chi tiết kèo';
    final s = raw.toString().trim();
    return s.isEmpty ? 'Chi tiết kèo' : s;
  }

  String? get _imageUrl {
    final deal = widget.deal;
    final candidate = deal['image'] ??
        deal['thumbnail'] ??
        (deal['images'] is List && (deal['images'] as List).isNotEmpty
            ? (deal['images'] as List).first
            : null);
    final url = candidate?.toString();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  String get _dealType {
    return widget.deal['type']?.toString().trim() ?? '';
  }

  int? get _participantCount {
    final raw = widget.deal['participants'];
    if (raw is List) return raw.length;
    if (raw is int) return raw;
    return null;
  }

  Future<void> _openDetail() async {
    final rawId = widget.deal['id'];
    final productId = int.tryParse(rawId?.toString() ?? '');
    if (productId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Kèo này thiếu thông tin, không thể xem chi tiết")),
      );
      return;
    }
    setState(() => _loadingDetail = true);
    final productJson = await widget.wpService.fetchProductById(productId);
    if (!mounted) return;
    setState(() => _loadingDetail = false);
    if (productJson == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Không tải được chi tiết kèo, thử lại sau")),
      );
      return;
    }
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProductDetailPage(product: productJson)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _statusInfo;
    final typeStyle = _getTypeStyle(_dealType);
    final participantCount = _participantCount;
    final imageUrl = _imageUrl;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1E3A8A), Color(0xFF2D4FA8), Color(0xFFB85A30), Color(0xFFFF7F50)],
              stops: [0.0, 0.38, 0.75, 1.0],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [

              // ===== IMAGE BLOCK =====
              SizedBox(
                height: 148,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (imageUrl != null)
                      Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _GradientPlaceholder(),
                      )
                    else
                      _GradientPlaceholder(),

                    // Overlay tối trên
                    Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0x6A000000), Colors.transparent],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0.0, 0.6],
                        ),
                      ),
                    ),

                    // Overlay hòa vào gradient dưới
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: Container(
                        height: 48,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, Color(0x8C1E3A8A)],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ),

                    // Badge + Close
                    Positioned(
                      top: 12, left: 14, right: 14,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _StatusBadgeV2(
                            label: status["label"] as String,
                            icon: status["icon"] as IconData,
                            color: widget.dealColor,
                          ),
                          _CloseButtonV2(onTap: () => Navigator.pop(context)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ===== BODY =====
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // TYPE PILLS
                    if (_dealType.isNotEmpty) ...[
                      Wrap(
                        spacing: 8,
                        children: [
                          _TypePill(
                            label: _dealType,
                            icon: typeStyle["icon"] as IconData,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],

                    // TITLE
                    Text(
                      _title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.3,
                        shadows: [Shadow(color: Color(0x40000000), blurRadius: 4)],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // THỜI GIAN
                    _InfoCard(
                      icon: Icons.schedule_rounded,
                      label: "THỜI GIAN",
                      value: _formattedTime,
                    ),
                    const SizedBox(height: 8),

                    // SỐ NGƯỜI
                    if (participantCount != null) ...[
                      _InfoCard(
                        icon: Icons.group_rounded,
                        label: "THAM GIA",
                        value: "$participantCount người đang tham gia",
                      ),
                      const SizedBox(height: 8),
                    ],

                    // Divider
                    Container(height: 1, color: Colors.white.withOpacity(0.12), margin: const EdgeInsets.symmetric(vertical: 14)),

                    // CTA
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _loadingDetail ? null : _openDetail,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.18),
                          foregroundColor: Colors.white,
                          shadowColor: Colors.transparent,
                          side: BorderSide(color: Colors.white.withOpacity(0.3), width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                          elevation: 0,
                        ),
                        child: _loadingDetail
                            ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                        )
                            : const Text(
                          "Xem chi tiết kèo →",
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, letterSpacing: 0.1),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== GRADIENT PLACEHOLDER ====================
class _GradientPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.15),
      child: const Center(
        child: Icon(Icons.local_bar_rounded, size: 44, color: Color(0x55FFFFFF)),
      ),
    );
  }
}

// ==================== TYPE PILL (cùng tông) ====================
class _TypePill extends StatelessWidget {
  final String label;
  final IconData icon;
  const _TypePill({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.14),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== INFO CARD (cùng tông) ====================
class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoCard({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.16)),
      ),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 16, color: Colors.white.withOpacity(0.85)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Colors.white.withOpacity(0.55),
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(value,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
// ==================== STATUS BADGE V2 ====================
class _StatusBadgeV2 extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _StatusBadgeV2({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.88),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== CLOSE BUTTON V2 ====================
class _CloseButtonV2 extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseButtonV2({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.28),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close, size: 15, color: Colors.white),
      ),
    );
  }
}



// ===== Tách badge trạng thái thành widget riêng để dùng lại ở cả 2 vị trí (trên ảnh / trong header) =====
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, required this.dealColor});

  final Map<String, dynamic> status;
  final Color dealColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: dealColor.withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status["icon"] as IconData, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            status["label"] as String,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.25),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close, size: 16, color: Colors.white),
      ),
    );
  }
}

class _GroupMarkerState extends State<_GroupMarker>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // 🌊 Aura
        ScaleTransition(
          scale: Tween(begin: 1.0, end: 1.6).animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          ),
          child: Container(
            width: widget.size * 2.8,
            height: widget.size * 2.8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withOpacity(0.25),
            ),
          ),
        ),

        // 🔴 Core
        Container(
          width: widget.size * 2,
          height: widget.size * 2,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 6),
            ],
          ),
          child: const Icon(
            Icons.groups,
            color: Colors.white,
            size: 14,
          ),
        ),

        // 🔢 Count
        if (widget.count > 1)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
              child: Text(
                widget.count.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

        // 🏷️ Loại hình quán (góc trái-trên, tránh đè badge count)
        if (widget.dealType.isNotEmpty)
          Positioned(
            top: 5,
            left: 5,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: widget.color, width: 1.2),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 3),
                ],
              ),
              child: Icon(
                getIconByType(widget.dealType),
                size: 11,
                color: getColorByType(widget.dealType),
              ),
            ),
          ),
      ],
    );
  }
}



