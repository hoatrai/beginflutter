import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

class MapPageSelectLocation extends StatefulWidget {
  const MapPageSelectLocation({super.key});

  @override
  State<MapPageSelectLocation> createState() => _MapPageSelectLocationState();
}

class _MapPageSelectLocationState extends State<MapPageSelectLocation>
    with SingleTickerProviderStateMixin {
  LatLng? _selectedPoint;
  LatLng _currentCenter = LatLng(10.762622, 106.660172);
  bool _loading = true;
  final TextEditingController _addressController = TextEditingController();
  final MapController _mapController = MapController();
  double _currentZoom = 15;


  // ===== PUB =====
  List<Map<String, dynamic>> _pubs = [];
  bool _loadingPub = false;

  // Colors
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _determinePosition();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animationController.dispose();
    _addressController.dispose();
    super.dispose();
  }
  void _showPubInfo(Map<String, dynamic> pub) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                primaryBlue.withOpacity(0.95),
                accentOrange.withOpacity(0.85),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(24),
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 12,
                offset: Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ===== IMAGE =====
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    height: 160,
                    width: double.infinity,
                    child: pub['image'] != null &&
                        pub['image'].toString().isNotEmpty
                        ? Image.network(
                      pub['image'],
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Colors.white,
                          ),
                        );
                      },
                      errorBuilder: (_, __, ___) {
                        return _buildNoImage();
                      },
                    )
                        : _buildNoImage(),
                  ),
                ),

                const SizedBox(height: 12),

                // ===== NAME =====
                Text(
                  pub['name'] ?? 'Không tên',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),

                const SizedBox(height: 6),

                // ===== ADDRESS =====
                Text(
                  pub['address'] ?? 'Không có địa chỉ',
                  style: const TextStyle(color: Colors.white70),
                ),

                const SizedBox(height: 6),

                // ===== RATING =====
                if (pub['rating'] != null)
                  Row(
                    children: [
                      const Icon(Icons.star,
                          color: Colors.yellowAccent, size: 18),
                      const SizedBox(width: 4),
                      Text(
                        pub['rating'].toString(),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),

                const SizedBox(height: 16),

                // ===== ACTION BUTTON =====
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black.withOpacity(0.25),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: Colors.white30),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.check_circle,
                        color: Colors.white),
                    label: const Text(
                      "Chọn quán này",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () {
                      final point = LatLng(pub['lat'], pub['lng']);

                      setState(() {
                        _selectedPoint = point;
                        _addressController.text =
                            pub['address'] ??
                                pub['name'] ??
                                '';
                      });

                      _mapController.move(point, 16.5);

                      Navigator.pop(context);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNoImage() {
    return Container(
      color: Colors.grey.shade200,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported, size: 40, color: Colors.grey),
            SizedBox(height: 6),
            Text("Không có hình ảnh", style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
  Widget _buildPubMarker() {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        final pulse = _animationController.value;
        final scale = 1 + pulse * 0.12;
        final glow = 6 + pulse * 10;

        return Transform.scale(
          scale: scale,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [
                  Color(0xFFFFF3E0),
                  Color(0xFFFF9800),
                  Color(0xFFE65100),
                ],
                radius: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withOpacity(0.8),
                  blurRadius: glow,
                  spreadRadius: 1,
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.35),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        );
      },
    );
  }




  // ================= GPS =================

  Future<void> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _loading = false);
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _loading = false);
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() => _loading = false);
      return;
    }

    final position = await Geolocator.getCurrentPosition();
    await Future.delayed(const Duration(milliseconds: 500));

    setState(() {
      _currentCenter = LatLng(position.latitude, position.longitude);
      _loading = false;
    });

    // ✅ LOAD PUB SAU KHI CÓ GPS
    _loadPubs();
  }

  // ================= PUB API =================

  double _parseDouble(dynamic v) {
    if (v == null) return 0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  Future<void> _loadPubs() async {
    try {
      setState(() => _loadingPub = true);

      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/spiritwebs/v1/nearby-pubs"
            "?lat=${_currentCenter.latitude}"
            "&lng=${_currentCenter.longitude}"
            "&radius=10",
      );

      final res = await http.get(url);

      debugPrint("PUB RAW: ${res.body}");


      if (res.statusCode == 200) {
        final List data = jsonDecode(res.body);

        _pubs = data
            .where((e) => e['lat'] != null && e['lng'] != null)
            .map((e) {
          final lat = _parseDouble(e['lat']);
          final lng = _parseDouble(e['lng']);

          debugPrint("PUB: ${e['name']} → $lat , $lng");

          return {
            'name': e['name'],
            'address': e['address'],
            'lat': lat,
            'lng': lng,
            'image': e['image'],
            'rating': e['avg_rating'],
          };
        }).where((e) => e['lat'] != 0 && e['lng'] != 0).toList();

      }
    } catch (e) {
      debugPrint("Load pub error: $e");
    }

    if (mounted) {
      setState(() => _loadingPub = false);
    }
  }

  // ================= SEARCH ADDRESS =================

  Future<void> _searchAddress() async {
    final query = _addressController.text.trim();
    if (query.isEmpty) return;

    final encodedQuery = Uri.encodeComponent(query);
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search?q=$encodedQuery&format=json&addressdetails=1&limit=1',
    );

    try {
      final response = await http.get(
        url,
        headers: {
          'User-Agent': 'SpiritWebsApp/1.0 (contact: xuanhung1606@gmail.com)',
          'Accept-Language': 'vi,en;q=0.9',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data.isNotEmpty) {
          final lat = double.parse(data[0]['lat']);
          final lon = double.parse(data[0]['lon']);
          final newPoint = LatLng(lat, lon);

          setState(() {
            _selectedPoint = newPoint;
            _mapController.move(newPoint, 16);
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("📍 Đã định vị: ${data[0]['display_name']}"),
              backgroundColor: primaryBlue,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Search error: $e");
    }
  }

  // ================= REVERSE =================

  Future<void> _reverseGeocode(LatLng point) async {
    final url = Uri.parse(
      'https://nominatim.openstreetmap.org/reverse?lat=${point.latitude}&lon=${point.longitude}&format=json',
    );

    try {
      final response = await http.get(
        url,
        headers: {
          'User-Agent': 'SpiritWebsApp/1.0 (contact: xuanhung1606@gmail.com)',
          'Accept-Language': 'vi,en;q=0.9',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final displayName = data['display_name'] ?? 'Không rõ địa chỉ';
        setState(() {
          _selectedPoint = point;
          _addressController.text = displayName;
        });
      }
    } catch (e) {
      debugPrint("Reverse error: $e");
    }
  }

  Widget _buildLoadingScreen() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: FadeTransition(
          opacity: _animationController.drive(
            Tween(begin: 0.3, end: 1.0),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_on, color: textWhite, size: 80),
              const SizedBox(height: 16),
              const Text(
                "Đang xác định vị trí...",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const CircularProgressIndicator(color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(body: _buildLoadingScreen());

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  center: _currentCenter,
                  zoom: 15,
                  maxZoom: 18,
                  minZoom: 3,
                  onPositionChanged: (position, hasGesture) {
                    if (position.zoom != null) {
                      setState(() {
                        _currentZoom = position.zoom!;
                      });
                    }
                  },
                  onTap: (tapPosition, point) {
                    _reverseGeocode(point);
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                    "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                    userAgentPackageName: 'com.spiritwebs.app',
                  ),

                  MarkerLayer(
                    markers: [
                      // ===== USER POSITION =====
                      Marker(
                        point: _currentCenter,
                        width: 40,
                        height: 40,
                        builder: (context) => const Icon(
                          Icons.person_pin_circle,
                          color: Colors.blue,
                          size: 40,
                        ),
                      ),

                      // ===== SELECTED POINT =====
                      if (_selectedPoint != null)
                        Marker(
                          point: _selectedPoint!,
                          width: 40,
                          height: 40,
                          builder: (context) => const Icon(
                            Icons.location_pin,
                            color: Colors.red,
                            size: 40,
                          ),
                        ),

                      // ===== PUB MARKERS =====
                        ..._pubs.map((pub) {
                          return Marker(
                            point: LatLng(pub['lat'], pub['lng']),
                            width: 22,
                            height: 22,
                            builder: (_) => GestureDetector(
                              onTap: () => _showPubInfo(pub),
                              onDoubleTap: () => Navigator.pop(context, pub),
                              child: _buildPubMarker(),
                            ),
                          );
                        }).toList(),


                    ],
                  ),
                ],
              ),

              // ===== SEARCH =====
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _addressController,
                        style: TextStyle(color: textWhite),
                        decoration: InputDecoration(
                          hintText:
                          "Nhập địa chỉ, ví dụ: 123 Lê Lợi, Q1, TP.HCM",
                          hintStyle:
                          const TextStyle(color: Colors.white70),
                          filled: true,
                          fillColor: primaryBlue.withOpacity(0.6),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _searchAddress(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _searchAddress,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentOrange,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child:
                      const Icon(Icons.search, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _selectedPoint == null
          ? null
          : FloatingActionButton.extended(
        backgroundColor: primaryBlue,
        icon: const Icon(Icons.check, color: Colors.white),
        label: const Text(
          "Chọn địa điểm này",
          style: TextStyle(color: Colors.white),
        ),
        onPressed: () {
          Navigator.pop(context, {
            'address': _addressController.text,
            'latitude': _selectedPoint!.latitude,
            'longitude': _selectedPoint!.longitude,
          });
        },
      ),
    );
  }
}
