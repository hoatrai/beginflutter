import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import 'package:intl/intl.dart';
import '../helpers/storage_helper.dart';
import 'product_detail_page.dart';
import 'chat_list_page.dart';
import 'user_info_page.dart';
import 'my_keo_page.dart';
import 'create_invite_page.dart';
import '../main.dart' show unreadNotiVN;
import 'notification_page.dart';


//import 'chat_page_phoenix.dart';
import 'chat_page.dart';
import 'dart:async';

List<Map<String, dynamic>> cartItems = [];

class ShopPage extends StatefulWidget {
  const ShopPage({super.key});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> with WidgetsBindingObserver {
  List<Map<String, dynamic>> products = [];
  Map<int, InviteStatus?> inviteStatusMap = {}; // ← DÁN Ở ĐÂY
  bool loading = true;
  bool _loadingMore = false; // khai báo trong _ShopPageState
  bool isFindingKeo = false;
  String? findingOption; // now | tonight | weekend
  String? district;
  List<Map<String, dynamic>>? findingUsers; // null = chưa load
  bool loadingFinding = false;
  bool userChangedFinding = false; // 🔒 khóa sync khi user thao tác
  bool sendingInvite = false;
  bool isOpeningLocation = false;
  bool isShowingLocationDialog = false;
  bool justReturnedFromSettings = false;
  bool isUserScrolling = false;
  Timer? autoScrollTimer;
  final Set<String> _fetchingAvatarIds = {};
  double? myLat;
  double? myLng;

  final Set<String> _fetchingHostStats = {};
  final Set<String> _fetchingCreators = {};
  bool _didPreload = false;
  String? activityType;

  final ScrollController _findingScrollController = ScrollController();




  int page = 1;
  int myUserId = 0; // khai báo int
  bool hasMore = true;
  bool _isNavigating = false;
  Map<String, String> creatorAvatars = {};
  Map<String, String> participantAvatars = {};
  Timer? heartbeatTimer;

  Map<String, dynamic> hostStatsMap = {};


  late WebSocketChannel channel;
  bool _socketConnected = false; // ✅ tránh gọi dispose khi channel chưa init
  Map<String, String> userAvatars = {};
  final currencyFormat = NumberFormat('#,###', 'vi_VN');
  Map<String, String> creatorNames = {};
  int chatCount = 0;
  bool pageLoaded = false; // trạng thái ban đầu



  // Theme colors đồng bộ ProfilePage
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startAutoScroll();
    _initPage();
    //loadFindingStatus(); // 🔥 ở đây
    _initFlow();
  }
  void _startAutoScroll() {

    autoScrollTimer?.cancel();

    autoScrollTimer = Timer.periodic(

      const Duration(milliseconds: 16),

          (timer) {

        if (!mounted) return;

        if (!_findingScrollController.hasClients) {
          return;
        }

        // 🔥 USER ĐANG KÉO
        if (isUserScrolling) {
          return;
        }

        final maxScroll =
            _findingScrollController
                .position
                .maxScrollExtent;

        final current =
            _findingScrollController.offset;

        double next = current + 0.8;

        if (next >= maxScroll) {

          _findingScrollController.jumpTo(0);

        } else {

          _findingScrollController.jumpTo(next);
        }
      },
    );
  }

  Future<void> fetchHostStats(String userId) async {
    if (hostStatsMap.containsKey(userId)) return;

    try {
      final res = await http.get(
        Uri.parse(
          '${AppConfig.webDomain}/wp-json/nhau/v1/user-stats/$userId',
        ),
      );

      final data = jsonDecode(res.body);

      if (data['success'] == true) {
        setState(() {
          hostStatsMap[userId] = data['stats'];
        });
      }
    } catch (e) {
      debugPrint("host stats error: $e");
    }
  }


  Future<void> fetchInviteStatus(int productId) async {
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";

      final res = await http.get(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/invite/by-product?product_id=$productId"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
      );

      if (res.statusCode != 200) {
        throw Exception("HTTP ${res.statusCode}");
      }

      final data = jsonDecode(res.body);

      inviteStatusMap[productId] = InviteStatus(
        isJoined: data['is_joined'] == true,
        isFull: data['is_full'] == true,
        status: data['status']?.toString() ?? "",
        joinedCount: int.tryParse(data['joined_count']?.toString() ?? "0") ?? 0,
        maxPeople: int.tryParse(data['max_people']?.toString() ?? "0") ?? 0,
      );

    } catch (e) {
      debugPrint("🔴 fetchInviteStatus error: $e");

      // ❗ BẮT BUỘC: set fallback để UI không bị loading vĩnh viễn
      inviteStatusMap[productId] = InviteStatus(
        isJoined: false,
        isFull: false,
        status: "error",
        joinedCount: 0,
        maxPeople: 0,
      );
    }

    if (!mounted) return;
    setState(() {});
  }




  Future<void> _initPage() async {

    setState(() {
      pageLoaded = true; // đánh dấu đã load xong
    });
  }
  Widget _buildFindingToggleIfLoaded() {
    if (!pageLoaded) return Container(); // chưa load → không hiển thị
    return _buildFindingToggle(); // đã load → hiển thị toggle
  }

  // ============================================================
  // 🔧 FIX 1: KHÔNG ĐỂ LỖI VỊ TRÍ LÀM TREO LOADING VĨNH VIỄN
  // 🔧 FIX 2: LẤY VỊ TRÍ NHANH (cache trước, GPS medium sau)
  // 🔧 FIX 3: CHẠY SONG SONG CÁC TÁC VỤ ĐỘC LẬP THAY VÌ TUẦN TỰ
  // ============================================================
  Future<void> _initFlow() async {
    await Future.wait([
      fetchProducts(),
      _loadMyUserId(),
      loadFindingStatus(),
    ]);

    await _requestLocationOnFirstLoad(); // 🆕

    fetchChatCount();
    connectSocket();
  }

  Future<void> _requestLocationOnFirstLoad() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showLocationDialog(context, "Vui lòng bật GPS để tìm kèo gần bạn.");
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        _showLocationDialog(context, "Bạn đã tắt quyền vị trí.\nVào Cài đặt để bật lại.");
        return;
      }

      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        _resolveMyLocationSilent();
      }
    } catch (e) {
      debugPrint("⚠️ _requestLocationOnFirstLoad: $e");
    }
  }

  Future<void> _resolveMyLocationSilent() async {
    try {
      final serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) return;
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) return;

      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        myLat = lastKnown.latitude;
        myLng = lastKnown.longitude;
        _reloadProductsWithLocation();
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 5));

      myLat = pos.latitude;
      myLng = pos.longitude;
      _reloadProductsWithLocation();

    } catch (e) {
      debugPrint("⚠️ _resolveMyLocationSilent: $e");
    }
  }

  void _reloadProductsWithLocation() {
    if (!mounted) return;
    setState(() {
      page = 1;
      hasMore = true;
      products.clear();
    });
    fetchProducts();
  }



  /// Lấy vị trí người dùng theo thứ tự ưu tiên:
  /// 1. Vị trí cache gần nhất (gần như tức thì)
  /// 2. Nếu chưa có cache -> xin quyền + GPS mới (medium, có timeout)
  /// 3. Nếu vẫn lỗi -> dùng toạ độ fallback để KHÔNG bao giờ làm
  ///    _initFlow() bị treo (đây chính là nguyên nhân gây "load hoài")
  /*Future<void> _resolveMyLocation() async {
    const fallbackLat = 10.7769; // fallback trung tâm TP.HCM
    const fallbackLng = 106.7009;

    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        myLat = lastKnown.latitude;
        myLng = lastKnown.longitude;
      }
    } catch (e) {
      debugPrint("⚠️ getLastKnownPosition error: $e");
    }

    if (myLat != null && myLng != null) {
      // Đã có vị trí cache để hiển thị ngay -> cập nhật vị trí
      // chính xác hơn ở nền, không chặn UI
      _refreshAccurateLocationInBackground();
      return;
    }

    try {
      final hasPermission = await ensureLocationPermission(context);

      if (!hasPermission) {
        myLat = fallbackLat;
        myLng = fallbackLng;
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException("GPS timeout"),
      );

      myLat = pos.latitude;
      myLng = pos.longitude;
    } catch (e) {
      debugPrint("❌ _resolveMyLocation error: $e");
      myLat = fallbackLat;
      myLng = fallbackLng;
    }
  }*/
  Future<void> _resolveMyLocation() async {
    const fallbackLat = 10.7769;
    const fallbackLng = 106.7009;

    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) {
        myLat = lastKnown.latitude;
        myLng = lastKnown.longitude;
      }
    } catch (e) {
      debugPrint("⚠️ getLastKnownPosition error: $e");
    }

    if (myLat != null && myLng != null) {
      _refreshAccurateLocationInBackground();
      return;
    }

    // 🔵 Dùng silent — không mở Settings nếu từ chối
    final hasPermission = await _checkLocationSilent();
    if (!hasPermission) {
      myLat = fallbackLat;
      myLng = fallbackLng;
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 8));

      myLat = pos.latitude;
      myLng = pos.longitude;
    } catch (e) {
      myLat = fallbackLat;
      myLng = fallbackLng;
    }
  }

  /// Lấy vị trí chính xác cao hơn ở nền sau khi đã có vị trí cache,
  /// để không chặn các bước tiếp theo của _initFlow()
  Future<void> _refreshAccurateLocationInBackground() async {
    try {
      final hasPermission = await ensureLocationPermission(context);
      if (!hasPermission) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 8));

      if (!mounted) return;

      myLat = pos.latitude;
      myLng = pos.longitude;
      // refresh lại danh sách theo vị trí mới chính xác hơn
      setState(() {
        page = 1;
        hasMore = true;
        products.clear();
      });
      fetchProducts();
    } catch (e) {
      debugPrint("⚠️ _refreshAccurateLocationInBackground error: $e");
    }
  }

  String getDistanceText(Map product) {
    try {
      if (myLat == null || myLng == null) return "";

      final double lat =
      double.parse(product['meta']['lat'].toString());

      final double lng =
      double.parse(product['meta']['lng'].toString());

      final km = Geolocator.distanceBetween(
        myLat!,
        myLng!,
        lat,
        lng,
      ) /
          1000;

      return "${km.toStringAsFixed(1)} km";
    } catch (e) {
      return "";
    }
  }

  Future<void> deleteProduct(int productId) async {
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";

      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/wc/v3/products/$productId?force=true",
      );

      final response = await http.delete(
        url,
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
      );

      if (response.statusCode == 200) {
        setState(() {
          products.removeWhere((p) => p['id'] == productId);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Đã xóa thành công")),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Không thể xóa")),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Lỗi: $e")),
      );
    }
  }

  Future<void> loadFindingStatus() async {
    try {
      if (userChangedFinding) {
        debugPrint("⛔ Skip loadFindingStatus because user changed manually");
        return;
      }

      final userId = await StorageHelper.read("user_id") ?? "0";
      final url = Uri.parse(
          "${AppConfig.webDomain}/wp-json/custom/v1/finding-keo/status?user_id=$userId"
      );

      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);

        if (!mounted) return;
        if (userChangedFinding) return; // 🔥 double check
        if (!mounted) return;
        if (!userChangedFinding) {
          setState(() {
            isFindingKeo = data['is_finding'] == 1;
            findingOption = data['finding_option'];
          });
        }
      }
    } catch (e) {
      debugPrint("❌ loadFindingStatus error: $e");
    }
  }


  Widget _skeletonBox({double width = double.infinity, double height = 12}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.25),
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
  Widget _buildFindingSkeleton() {
    return SizedBox(
      height: 110,
      child: shimmer.Shimmer.fromColors(
        baseColor: Colors.white.withOpacity(0.08),
        highlightColor: Colors.white.withOpacity(0.25),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: 4,
          itemBuilder: (_, __) {
            return Container(
              width: 160,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _skeletonBox(width: 90, height: 14),
                  const SizedBox(height: 8),
                  _skeletonBox(width: 70, height: 12),
                  const SizedBox(height: 8),
                  _skeletonBox(width: 50, height: 12),
                ],
              ),
            );
          },
        ),
      ),
    );
  }





  Future<void> _loadMyUserId() async {
    final idStr = await StorageHelper.read("user_id");
    setState(() {
      myUserId = int.tryParse(idStr ?? '0') ?? 0;
    });
  }

  /*Future<bool> ensureLocationPermission(BuildContext context) async {

    bool serviceEnabled =
    await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {

      _showLocationDialog(
        context,
        "Vui lòng bật GPS để tìm kèo gần bạn.",
      );

      return false;
    }

    LocationPermission permission =
    await Geolocator.checkPermission();

    debugPrint("📍 Current permission: $permission");

    if (permission == LocationPermission.denied) {

      permission =
      await Geolocator.requestPermission();

      debugPrint("📍 Requested permission: $permission");

      if (permission == LocationPermission.denied) {

        debugPrint("❌ User denied location");

        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {

      debugPrint("❌ deniedForever");

      _showLocationDialog(
        context,
        "Bạn đã tắt quyền vị trí.\nVào Cài đặt để bật lại.",
      );

      return false;
    }

    return true;
  }*/

  // 🔵 Dùng khi VÀO TRANG — im lặng, không mở Settings
  Future<bool> _checkLocationSilent() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } catch (e) {
      return false;
    }
  }

// 🟠 Dùng khi BẬT TÌM KÈO — bắt buộc, mở thẳng Settings nếu cần
  Future<bool> ensureLocationPermission(BuildContext context) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      isOpeningLocation = true;
      await Geolocator.openLocationSettings(); // mở thẳng
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }

    if (permission == LocationPermission.deniedForever) {
      isOpeningLocation = true;
      await Geolocator.openAppSettings(); // mở thẳng app settings
      return false;
    }

    return true;
  }

  void _showLocationDialog(BuildContext context, String message) {
    if (!mounted) return;

    // 👇 CHẶN HIỆN 2 LẦN
    if (isShowingLocationDialog) return;
    isShowingLocationDialog = true;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: [
                Colors.blue.shade900.withOpacity(.9),
                Colors.orange.shade700.withOpacity(.9),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.4),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ICON
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.location_off,
                  size: 36,
                  color: Colors.orange,
                ),
              ),

              const SizedBox(height: 16),

              const Text(
                "Cần bật định vị",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 20),

              // PRIMARY BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    isOpeningLocation = true;
                    Geolocator.openLocationSettings();
                    Navigator.pop(context);
                  },
                  child: const Text(
                    "Bật định vị",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  "Để sau",
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      // 👇 RESET KHI ĐÓNG
      isShowingLocationDialog = false;
    });
  }



  Future<Map<String, double>> getMyLocation() async {
    if (myLat != null && myLng != null) {
      return {"lat": myLat!, "lng": myLng!};
    }

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.medium,
    ).timeout(const Duration(seconds: 8));

    myLat = position.latitude;
    myLng = position.longitude;

    return {"lat": position.latitude, "lng": position.longitude};
  }

  Future<String> getDistrictFromLatLng(double lat, double lng) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lng);

      if (placemarks.isEmpty) return "";

      final p = placemarks.first;

      return p.subAdministrativeArea?.trim().isNotEmpty == true
          ? p.subAdministrativeArea!
          : p.locality?.trim().isNotEmpty == true
          ? p.locality!
          : "";
    } catch (e) {
      debugPrint("❌ getDistrict error: $e");
      return "";
    }
  }


  Future<bool> findingKeoOn() async {
    debugPrint("🎯 activityType = $activityType");
    debugPrint("⏰ findingOption = $findingOption");
    try {
      final hasPermission = await ensureLocationPermission(context);
      if (!hasPermission) return false;

      final token = await StorageHelper.read("jwt_token") ?? "";
      final userId = await StorageHelper.read("user_id") ?? "0";

      final loc = await getMyLocation();
      final lat = loc["lat"];
      final lng = loc["lng"];

      if (lat != null && lng != null) {
        district = await getDistrictFromLatLng(lat, lng);
        if (district?.isEmpty ?? true) return false;
      }

      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/custom/v1/finding-keo/on"),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $token",
        },
        body: jsonEncode({
          "user_id": userId,
          "finding_option": findingOption,
          "activity_type": activityType,  // 🆕
          "lat": lat,
          "lng": lng,
          "district": district,
        }),
      );

      return res.statusCode == 200;
    } catch (e) {
      debugPrint("❌ findingKeoOn error: $e");
      return false;
    }
  }


  Future<void> findingKeoOff() async {
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final userId = await StorageHelper.read("user_id") ?? "0";

      final url = Uri.parse("${AppConfig.webDomain}/wp-json/custom/v1/finding-keo/off");

      await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $token",
        },
        body: jsonEncode({"user_id": userId}),
      );
    } catch (e) {
      debugPrint("❌ findingKeoOff error: $e");
    }
  }

  Future<void> fetchNearbyFindingUsers() async {

    debugPrint("🔥 CALL nearby API at ${DateTime.now()}");

    try {

      // 🔥 CHECK GPS + PERMISSION
      final hasPermission = await ensureLocationPermission(context);

      if (!hasPermission) {
        debugPrint("❌ Không có quyền location");
        return;
      }

      loadingFinding = true;
      findingUsers = findingUsers; // giữ UI cũ
      setState(() {});

      await Future.delayed(const Duration(milliseconds: 200));

      final loc = await getMyLocation();

      final currentUserId =
          await StorageHelper.read("user_id") ?? "0";

      final lat = loc['lat'];
      final lng = loc['lng'];

      if (lat == null || lng == null) {
        debugPrint("⚠️ Lat/Lng chưa có giá trị");
        return;
      }

      final districtName =
      await getDistrictFromLatLng(lat, lng);

      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/custom/v1/finding-keo/nearby"
            "?lat=$lat"
            "&lng=$lng"
            "&district=$districtName"
            "&current_user_id=$currentUserId"
            "&activity_type=${activityType ?? ''}", // 🆕
      );

      final res = await http.get(url);

      debugPrint("📦 STATUS: ${res.statusCode}");
      debugPrint("📦 BODY: ${res.body}");

      if (res.statusCode == 200) {

        final data = jsonDecode(res.body);

        if (data['success'] == true) {

          final users =
          List<Map<String, dynamic>>.from(data['data']);

          final ids = users
              .map((u) => u['user_id'].toString())
              .toList();

// 🔥 1. render ngay lập tức (KHÔNG CHỜ avatar)
          setState(() {
            findingUsers = users;
          });

// 🔥 2. load avatar sau
          fetchUsersBulk(ids).then((_) {
            if (!mounted) return;

            setState(() {
              findingUsers = findingUsers!.map((u) {
                final id = u['user_id'].toString();

                return {
                  ...u,
                  'display_name': creatorNames[id] ?? u['display_name'],
                  'avatar_url': creatorAvatars[id] ?? u['avatar_url'],
                };
              }).toList();
            });
          });

          debugPrint(
            "✅ Loaded nearby users: ${findingUsers?.length}",
          );

        } else {

          debugPrint("⚠️ API success=false");

          setState(() {
            findingUsers = [];
          });
        }
      }

    } catch (e) {

      debugPrint(
        "❌ fetchNearbyFindingUsers error: $e",
      );

    } finally {

      if (mounted) {
        setState(() {
          loadingFinding = false;
        });
      }
    }
  }

// Hàm fetch tất cả user 1 lần
  Future<void> fetchUsersBulk(List<String> ids) async {
    if (ids.isEmpty) return;
// ✅ THÊM ĐOẠN NÀY NGAY ĐẦU HÀM
    final newIds = ids
        .where((id) => !creatorAvatars.containsKey(id))
        .toList();

    if (newIds.isEmpty) return;
    try {
      final uri = Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/users");
      final response = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"ids": newIds}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final users = data['users'] ?? [];

        for (var u in users) {
          final id = u['user_id'].toString();
          creatorNames[id] = u['display_name'] ?? 'Người dùng';
          creatorAvatars[id] = u['avatar_url'] ?? '';
        }
      }
    } catch (e) {
      debugPrint("❌ fetchUsersBulk error: $e");
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (isOpeningLocation) {
        isOpeningLocation = false;
        _handleReturnFromSettings();
      } else {
        _resolveMyLocationSilent();
      }
    }
  }

  @override
  void dispose() {
    autoScrollTimer?.cancel(); // 👈 THÊM DÒNG NÀY
    heartbeatTimer?.cancel();

    // 🔧 FIX: channel là `late` nên nếu connectSocket() chưa từng chạy
    // (vd: lỗi xảy ra trước đó), gọi channel.sink sẽ throw
    // LateInitializationError. Guard bằng _socketConnected.
    if (_socketConnected) {
      channel.sink.close(status.goingAway);
    }

    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _openChat(String creatorId, String pubName, {String avatarUrl = ""}) async {
    if (_isNavigating) return;
    _isNavigating = true;

    final myName = await StorageHelper.read("username") ?? "Ẩn danh 3";
    final myId = await StorageHelper.read("user_id") ?? "0";
    final targetId = creatorId;       // id người muốn chat
    final targetName = pubName;       // tên người muốn chat
    final targetAvatar = avatarUrl;   // avatar người muốn chat


    // Nếu avatarUrl rỗng -> fetch lại từ API
    if (avatarUrl.isEmpty) {
      try {
        final res = await http.get(Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/user/$creatorId"));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          avatarUrl = data['avatar_url']?.toString() ?? "";
        }
      } catch (e) {
        debugPrint("❌ Lỗi fetch avatar trước khi chat: $e");
      }
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatPage(
          username: myName,
          userId: int.parse(myId),
          targetUser: targetName,
          targetId: int.parse(targetId),
          targetAvatar: targetAvatar,
          serverUrl: "wss://socket.spiritwebs.com/socket/websocket",
        ),
      ),
    );


    _isNavigating = false;
  }

  Future<void> _handleReturnFromSettings() async {
    final ok = await ensureLocationPermission(context);
    if (!ok) return;

    await _resolveMyLocationSilent();

    if (isFindingKeo) {
      await fetchNearbyFindingUsers();
    }
  }

  Future<void> handleNewProduct(dynamic payload) async {
    try {
      final productId = payload['id'];
      if (productId == null) return;

      // Fetch chi tiết product từ REST API
      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/wc/v3/products/$productId"
            "?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
            "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
      );
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final productMap = parseProduct(data);

        // Lấy creator
        final creatorId = productMap['meta']['creator_id']?.toString() ?? "0";
        if (!creatorNames.containsKey(creatorId)) {
          await fetchCreatorsBulk([creatorId]);
        }
        productMap['creatorName'] = creatorNames[creatorId] ?? '...';

        // Cập nhật vào UI
        setState(() {
          if (!products.any((e) => e["id"] == productMap["id"])) {
            products.insert(0, productMap);
          }
        });
      }
    } catch (e) {
      debugPrint("❌ Lỗi handleNewProduct: $e");
    }
  }

  bool isExpired(String timeString) {
    try {
      final target = DateFormat("dd/MM/yyyy HH:mm").parse(timeString);
      return DateTime.now().isAfter(target);
    } catch (_) {
      return false;
    }
  }

  Future<void> fetchChatCount() async {
    try {
      final userIdStr = await StorageHelper.read("user_id");
      if (userIdStr == null) return;

      final userId = int.parse(userIdStr);
      final url = Uri.parse(
          "${AppConfig.webDomain}/wp-json/spiritwebs/v1/get-chat-list");

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"user_id": userId}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List allChats = data['chats'] ?? [];

        final Map<String, Map<String, dynamic>> uniqueChats = {};
        for (var chat in allChats) {
          final targetId = chat["target_id"]?.toString() ?? "";
          if (targetId.isNotEmpty && !uniqueChats.containsKey(targetId)) {
            uniqueChats[targetId] = chat;
          }
        }

        setState(() {
          chatCount = uniqueChats.length;
        });
      }
    } catch (e) {
      debugPrint("❌ Lỗi fetchChatCount: $e");
    }
  }

  bool isExpiredInvite(String timeString) {
    try {
      final targetTime =
      DateFormat("dd/MM/yyyy HH:mm").parse(timeString);

      // Hết hạn sau 1 ngày
      final expireTime = targetTime.add(const Duration(days: 1));

      return DateTime.now().isAfter(expireTime);
    } catch (e) {
      return false;
    }
  }

  void preloadCreators() {
    final ids = products
        .map((p) => p['meta']['creator_id']?.toString())
        .whereType<String>()
        .toSet();

    final newIds = ids
        .where((id) =>
    !creatorNames.containsKey(id) &&
        !_fetchingCreators.contains(id))
        .toList();

    if (newIds.isEmpty) return;

    _fetchingCreators.addAll(newIds);
    fetchCreatorsBulk(newIds).then((_) {
      _fetchingCreators.removeAll(newIds);
    });
  }

  Future<void> fetchProducts() async {
    if (!hasMore) return;

    setState(() => loading = true);

    final url = Uri.parse(
      "${AppConfig.webDomain}/wp-json/wc/v3/products"
          "?status=publish&per_page=10&page=$page"
          "&orderby=date&order=desc"
          "&consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
          "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
    );

    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List newProducts = json.decode(response.body);

      // Gom các creatorId
      final Set<String> creatorIds = {};
      for (var p in newProducts) {
        if (p['meta_data'] is List) {
          final creatorId = p['meta_data']
              .firstWhere((m) => m['key'] == 'creator_id',
              orElse: () => {'value': '0'})['value']
              .toString();

          if (creatorId != "0" && !creatorNames.containsKey(creatorId)) {
            creatorIds.add(creatorId);
          }
        }
      }

      // 🔥 Chạy ngầm, KHÔNG await → sản phẩm load ra trước
      fetchCreatorsBulk(creatorIds.toList());

      // Parse product
      final List<Map<String, dynamic>> parsedProducts = [];

      for (var p in newProducts) {
        final productMap = parseProduct(p);

        // 🔥 LỌC KÈO HẾT HẠN
        final timeString =
            productMap['meta']['time']?.toString() ?? '';

        if (isExpiredInvite(timeString)) {
          continue;
        }

        // ================== FILTER 20KM ==================
        try {
          final lat = double.tryParse(productMap['meta']['lat']?.toString() ?? '');
          final lng = double.tryParse(productMap['meta']['lng']?.toString() ?? '');

          if (lat == null || lng == null) continue;

          if (myLat != null && myLng != null) {
            final distanceKm = Geolocator.distanceBetween(
              myLat!, myLng!, lat, lng,
            ) / 1000;
            productMap['distanceKm'] = distanceKm;
            if (distanceKm > 20) continue;
          } else {
            productMap['distanceKm'] = null;
          }

        } catch (e) {
          debugPrint("❌ distance error: $e");
          continue;
        }
        // =================================================

        final creatorId =
            productMap['meta']['creator_id']?.toString() ?? "0";

        productMap['creatorName'] = creatorNames[creatorId];

        parsedProducts.add(productMap);
      }

      parsedProducts.sort((a, b) {
        final d1 = (a['distanceKm'] as double?) ?? 9999;
        final d2 = (b['distanceKm'] as double?) ?? 9999;
        return d1.compareTo(d2);
      });

      // Show sản phẩm ngay lập tức
      setState(() {
        products.addAll(parsedProducts);
        loading = false;
        if (newProducts.length < 10) {
          hasMore = false;
        } else {
          page++;
        }
      });

      // 🔧 FIX: trước đây preload chỉ chạy DUY NHẤT 1 LẦN (do cờ
      // _didPreload), nên sản phẩm load thêm ở các trang sau (infinite
      // scroll) không bao giờ được fetch invite-status/creator info.
      // Giờ luôn gọi lại sau mỗi trang — 2 hàm này tự lọc id đã có
      // rồi nên gọi lại không tốn thêm request thừa.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        preloadCreators();
        preloadInviteStatuses();
      });
    } else {
      setState(() {
        loading = false;
        hasMore = false;
      });
    }
  }

  Future<void> fetchCreatorsBulk(List<String> ids) async {
    if (ids.isEmpty) {
      debugPrint("⚠️ fetchCreatorsBulk: ids empty");
      return;
    }

    // ====== FILTER ID CHƯA CÓ ======
    final newIds = ids.where((id) => !creatorNames.containsKey(id)).toList();

    if (newIds.isEmpty) {
      debugPrint("✅ All creators cached, skip API");
      return;
    }

    debugPrint("🚀 fetchCreatorsBulk IDS = $newIds");

    try {
      final uri = Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/users");

      final response = await http
          .post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: json.encode({"ids": newIds}),
      )
          .timeout(const Duration(seconds: 30)); // ⬅ tăng timeout

      debugPrint("📥 Response status = ${response.statusCode}");

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final users = data['users'] as List<dynamic>? ?? [];

        for (final u in users) {
          final id = u['user_id'].toString();
          creatorNames[id] = u['display_name'] ?? 'Người dùng';
          creatorAvatars[id] = u['avatar_url'] ?? '';
        }

        debugPrint("📦 Creator results = $creatorNames");
      } else {
        debugPrint("❌ fetchCreatorsBulk error: status ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("❌ fetchCreatorsBulk exception: $e");
    }

    // ====== ASSIGN TO PRODUCTS ======
    for (final product in products) {
      final rawId = product['meta']?['creator_id'];
      final id = rawId?.toString().trim();

      if (id != null && creatorNames.containsKey(id)) {
        product['creatorName'] = creatorNames[id];
        product['creatorAvatar'] = creatorAvatars[id];

        debugPrint("🎯 Assigned creator for product: $id");
      }
    }

    if (mounted) setState(() {});
  }


  Widget _buildNearbyFindingList() {

    if (findingUsers == null || loadingFinding) {
      return _buildFindingSkeleton();
    }

    final nearbyUsers = findingUsers!
        .where(
          (u) =>
      (u['user_id'] ?? 0).toString() !=
          myUserId.toString(),
    )
        .toList();

    if (nearbyUsers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          "Không có ai đang tìm kèo gần bạn 😢",
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return SizedBox(
      height: 110,

      child: NotificationListener<ScrollNotification>(

        onNotification: (notification) {

          // 🔥 USER BẮT ĐẦU KÉO
          if (notification is ScrollStartNotification) {
            isUserScrolling = true;
          }

          // 🔥 USER THẢ TAY
          if (notification is ScrollEndNotification) {

            Future.delayed(
              const Duration(seconds: 2),
                  () {

                if (mounted) {
                  isUserScrolling = false;
                }
              },
            );
          }

          return false;
        },

        child: ListView.builder(

          controller: _findingScrollController,

          scrollDirection: Axis.horizontal,

          physics: const BouncingScrollPhysics(),

          itemCount: nearbyUsers.length,

          itemBuilder: (context, index) {

            final u = nearbyUsers[index];

            final avatar =
                u['avatar_url']?.toString() ?? '';

            final isOnline =
                (u['is_online'] ?? 0) == 1;

            return Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),

              child: GestureDetector(

                onTap: () {

                  final creatorId =
                  (u['user_id'] ?? 0).toString();

                  final name =
                      u['display_name'] ?? 'Người dùng';

                  final avatarUrl =
                      u['avatar_url'] ?? '';

                  _openChat(
                    creatorId,
                    name,
                    avatarUrl: avatarUrl,
                  );
                },

                child: Container(

                  width: 140,

                  padding: const EdgeInsets.all(8),

                  decoration: BoxDecoration(

                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withOpacity(0.05),
                        Colors.white.withOpacity(0.12),
                      ],
                    ),

                    borderRadius:
                    BorderRadius.circular(12),

                    border: Border.all(
                      color: Colors.white24,
                    ),
                  ),

                  child: Row(
                    children: [

                      // ================= AVATAR =================

                      Stack(
                        clipBehavior: Clip.none,

                        children: [

                          CircleAvatar(
                            radius: 22,
                            backgroundColor: Colors.black26,
                            child: ClipOval(
                              child: CachedNetworkImage(
                                imageUrl: avatar,
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                placeholder: (context, url) =>
                                const Icon(Icons.person, color: Colors.white70),
                                errorWidget: (context, url, error) =>
                                const Icon(Icons.person, color: Colors.white70),
                              ),
                            ),
                          ),

                          if (isOnline)
                            Positioned(
                              bottom: -1,
                              right: -1,

                              child: Container(
                                width: 10,
                                height: 10,

                                decoration:
                                BoxDecoration(
                                  color:
                                  Colors.greenAccent,

                                  shape:
                                  BoxShape.circle,

                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),

                      const SizedBox(width: 10),

                      // ================= INFO =================

                      Expanded(
                        child: Column(

                          crossAxisAlignment:
                          CrossAxisAlignment.start,

                          mainAxisAlignment:
                          MainAxisAlignment.center,

                          children: [

                            Text(
                              u['display_name'] ??
                                  'Người dùng',

                              maxLines: 1,

                              overflow:
                              TextOverflow.ellipsis,

                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight:
                                FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),

                            const SizedBox(height: 2),

                            Text(
                              "📍 ${u['district'] ?? ''}",

                              maxLines: 1,

                              overflow:
                              TextOverflow.ellipsis,

                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),

                            const SizedBox(height: 2),

                            Text(
                              "🎯 ${u['activity_type'] ?? ''}",  // 🆕
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.lightBlueAccent,
                                fontSize: 11,
                              ),
                            ),

                            Text(
                              "⏰ ${u['finding_option'] ?? ''}",

                              maxLines: 1,

                              overflow:
                              TextOverflow.ellipsis,

                              style: const TextStyle(
                                color: Colors.orange,
                                fontSize: 11,
                              ),
                            ),

                            const SizedBox(height: 4),

                            SizedBox(

                              height: 16,

                              child: ElevatedButton(

                                onPressed: () {
                                  _openInvitePopup(u);
                                },

                                style:
                                ElevatedButton.styleFrom(

                                  backgroundColor:
                                  Colors.orange,

                                  padding: EdgeInsets.zero,

                                  minimumSize: Size.zero,

                                  tapTargetSize:
                                  MaterialTapTargetSize
                                      .shrinkWrap,

                                  visualDensity:
                                  VisualDensity.compact,

                                  shape:
                                  RoundedRectangleBorder(
                                    borderRadius:
                                    BorderRadius
                                        .circular(6),
                                  ),
                                ),

                                child: const Padding(
                                  padding:
                                  EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),

                                  child: Text(
                                    "Mời join",

                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white,
                                    ),
                                  ),
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
          },
        ),
      ),
    );
  }
  void _openInvitePopup(Map user) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return InviteListPopup(
          user: user,
          onInviteSelected: (invite) {
            Navigator.pop(context);   // ✅ đóng popup
            _sendInvite(user, invite); // ✅ gửi API
          },
        );
      },
    );
  }

  Future<void> _sendInvite(Map user, Map invite) async {
    try {
      final response = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/spiritwebs/v1/send-invite"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "sender_id": myUserId,
          "receiver_id": user['user_id'],
          "invite_id": invite['id']
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['success'] == true) {
          _showSnackBar("✅ Đã gửi lời mời cho ${user['display_name']}");
        } else {
          _showSnackBar("⚠️ Gửi lời mời thất bại");
        }

      } else {
        _showSnackBar("❌ Lỗi server (${response.statusCode})");
      }
    } catch (e) {
      _showSnackBar("❌ Không thể gửi lời mời");
      debugPrint("Send invite error: $e");
    }
  }
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }




  Future<void> _inviteJoinKeo(Map<String, dynamic> user) async {
    final targetId = user['user_id']?.toString() ?? "0";

    try {
      final token = await StorageHelper.read("jwt_token") ?? "";

      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/invite/send"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "target_user_id": targetId,
        }),
      );

      final data = jsonDecode(res.body);

      if (data['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Đã gửi lời mời 🍻")),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message'] ?? "Không thể mời")),
        );
      }
    } catch (e) {
      debugPrint("Invite error: $e");
    }
  }



  Widget buildInitialLoadingItem() {
    return shimmer.Shimmer.fromColors(
      baseColor: Colors.white.withOpacity(0.08),
      highlightColor: Colors.white.withOpacity(0.25),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        color: Colors.white.withOpacity(0.12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Avatar skeleton
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),

              const SizedBox(width: 10),

              // Text skeleton
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 14,
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 6),
                      color: Colors.white,
                    ),
                    Container(
                      height: 12,
                      width: 140,
                      margin: const EdgeInsets.only(bottom: 6),
                      color: Colors.white,
                    ),
                    Container(
                      height: 12,
                      width: 90,
                      color: Colors.white,
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
  Widget buildLoadMoreShimmerItem() {
    return shimmer.Shimmer.fromColors(
      baseColor: Colors.white.withOpacity(0.06),
      highlightColor: Colors.white.withOpacity(0.20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Fake image
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _shimmerLine(width: double.infinity),
                  const SizedBox(height: 8),
                  _shimmerLine(width: 160),
                  const SizedBox(height: 8),
                  _shimmerLine(width: 120),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shimmerLine({double width = 100, double height = 12}) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }


  Map<String, dynamic> parseProduct(dynamic p) {
    final Map<String, dynamic> productMap = Map<String, dynamic>.from(p);

    Map<String, dynamic> meta = {};
    List participants = [];

    if (productMap['meta_data'] != null && productMap['meta_data'] is List) {
      for (var m in productMap['meta_data']) {
        if (m is Map && m.containsKey('key') && m.containsKey('value')) {
          final key = m['key'];
          final value = m['value'];

          meta[key] = value;

          // ✅ LẤY PARTICIPANTS TỪ DB
          if (key == 'participants') {
            if (value is List) {
              participants = List.from(value);
            } else if (value is String && value.isNotEmpty) {
              // Trường hợp lưu JSON string
              try {
                participants = jsonDecode(value);
              } catch (_) {
                participants = [];
              }
            }
          }
        }
      }
    }

    productMap['meta'] = meta;
    productMap['participants'] = participants;
    productMap['joined_count'] = participants.length;

    // Categories
    if (productMap['categories'] != null && productMap['categories'] is List) {
      productMap['category_names'] =
          (productMap['categories'] as List).map((c) => c['name']).join(', ');
    } else {
      productMap['category_names'] = '';
    }

    // Images
    if (productMap['images'] != null && productMap['images'] is List) {
      final imgs = <Map<String, String>>[];
      for (var img in productMap['images']) {
        if (img is String) {
          imgs.add({'src': img});
        } else if (img is Map && img.containsKey('src')) {
          imgs.add({'src': img['src']});
        }
      }
      productMap['images'] = imgs;
    } else {
      productMap['images'] = [];
    }

    return productMap;
  }



  // Trong _ShopPageState

  void connectSocket() {
    channel = WebSocketChannel.connect(Uri.parse('wss://socket.spiritwebs.com/socket/websocket'));
    _socketConnected = true; // 🔧 đánh dấu đã init để dispose() an toàn

    channel.sink.add(jsonEncode({
      "topic": "products:lobby",
      "event": "phx_join",
      "payload": {},
      "ref": "1",
      "join_ref": "1"
    }));



    channel.stream.listen((message) {
      try {
        final decoded = json.decode(message);

        // Khi có sản phẩm mới
        if (decoded['event'] == 'new_product') {
          final payload = decoded['payload'];
          handleNewProduct(payload); // Gọi hàm mới
        }


        // Khi có update slots/participants
        else if (decoded['event'] == 'product_updated') {
          final payload = decoded['payload'];
          final productId = payload['id'];
          final updatedSlots = payload['meta']['slots']?.toString() ?? "0";
          final updatedParticipants = List<Map<String, dynamic>>.from(
            payload['participants'] ?? [],
          );
          setState(() {
            final index = products.indexWhere((p) => p['id'] == productId);
            if (index != -1) {
              products[index]['meta']['slots'] = updatedSlots;
              products[index]['participants'] = updatedParticipants;
              products[index]['joined_count'] = updatedParticipants.length;
            }
          });
        }

      } catch (_) {
        // ignore invalid JSON
      }
    });

    // --- ❤️ Thêm heartbeat ---
    heartbeatTimer?.cancel();
    heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      channel.sink.add(jsonEncode({
        "topic": "phoenix",
        "event": "heartbeat",
        "payload": {},
        "ref": DateTime.now().millisecondsSinceEpoch.toString(),
        "join_ref": "1",
      }));
    });
  }

// -------------------- Khi user join product --------------------
  Future<void> joinProduct(Map<String, dynamic> product) async {
    final slots = int.tryParse(product['meta']['slots']?.toString() ?? '0') ?? 0;
    if (slots <= 0) return;

    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final url = Uri.parse("${AppConfig.webDomain}/wp-json/custom/v1/invite/${product['id']}/join");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json", "Authorization": "Bearer $token"},
        body: jsonEncode({"user_id": myUserId}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          // Cập nhật local UI
          product['meta']['slots'] = (slots - 1).toString();
          product['participants'] ??= [];
          product['participants'].add({
            'user_id': myUserId,
            'avatar_url': userAvatars[myUserId.toString()] ?? ''
          });
          product['joined_count'] = product['participants'].length;
          if (!mounted) return;
          setState(() {});

          // Gửi thông tin lên WebSocket để broadcast
          channel.sink.add(jsonEncode({
            "topic": "products:lobby",
            "event": "product_updated",
            "payload": {
              "id": product['id'],
              "meta": {"slots": product['meta']['slots']},
              "participants": product['participants']
            },
            "ref": "3"
          }));


          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Tham gia thành công!")));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? "Lỗi tham gia")));
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Lỗi server")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Lỗi: $e")));
    }
  }

  Future<void> _confirmDelete(BuildContext context, int productId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent, // bắt buộc để gradient hiện ra
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFF1E3A8A).withOpacity(0.9), // primaryBlue
                const Color(0xFFFF7F50).withOpacity(0.8), // accentOrange
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: const [
                  Icon(Icons.warning, color: Colors.redAccent),
                  SizedBox(width: 8),
                  Text(
                    "Xác nhận xóa",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                "Bạn có chắc muốn xóa kèo này không?",
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.grey,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text("Hủy"),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text("Xóa"),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (result == true) {
      await _deleteItem(context, productId); // gọi thẳng _deleteItem
    }
  }


  Future<void> _deleteItem(BuildContext context, int productId) async {
    try {
      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/wc/v3/products/$productId"
            "?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
            "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
      );

      final response = await http.put(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"status": "trash"}),
      );

      if (response.statusCode == 200) {
        setState(() {
          products.removeWhere((p) => p['id'] == productId);
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Đã đưa vào thùng rác")));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Không thể xóa: ${response.statusCode}")));
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Lỗi: $e")));
    }
  }

  void _showPickActivity() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue.withOpacity(0.95), accentOrange.withOpacity(0.95)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Bạn muốn đi đâu?",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              _activityOption("🍺 Nhậu",       "Nhậu"),
              _activityOption("🎤 Karaoke",    "Karaoke"),
              _activityOption("🍸 Bar/Pub",    "Bar/Pub"),
              _activityOption("🍻 Beer Club",  "Beer Club"),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  Widget _activityOption(String title, String value) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(context);
        setState(() => activityType = value); // 🆕 lưu loại
        _showPickTime();                       // sau đó chọn thời gian
      },
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildFindingToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          children: [
            const Icon(Icons.location_on, color: Colors.orange, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isFindingKeo && activityType != null
                    ? "Đang tìm: $activityType"   // 🆕 hiện loại đang chọn
                    : "Tìm kèo gần bạn",
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
            Switch(
              value: isFindingKeo,
              activeColor: Colors.orange,
              onChanged: (val) async {
                userChangedFinding = true;
                if (val) {
                  _showPickActivity(); // 🆕 chọn loại trước
                } else {
                  setState(() {
                    isFindingKeo = false;
                    findingOption = null;
                    activityType = null; // 🆕
                  });
                  await findingKeoOff();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showPickTime() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue.withOpacity(0.95), accentOrange.withOpacity(0.95)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _timeOption("🔥 Ngay bây giờ", "Bây giờ"),
              _timeOption("🌙 Tối nay", "Tôi nay"),
              _timeOption("🎉 Cuối tuần", "Cuối tuần"),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }
  Widget _timeOption(String title, String value) {
    return GestureDetector(
      onTap: () => _selectTime(value),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  void _selectTime(String time) async {
    if (justReturnedFromSettings) {
      justReturnedFromSettings = false;
      return;
    }

    userChangedFinding = true;

    setState(() {
      findingOption = time;
      findingUsers = null;
      loadingFinding = true;
    });

    Navigator.pop(context);

    final ok = await findingKeoOn();
    if (!mounted) return;

    if (!ok) {
      setState(() => loadingFinding = false);
      _showSnackBar("⚠️ Không thể bật tìm kèo (mất GPS/mạng), thử lại nhé.");
      return;
    }

    setState(() => isFindingKeo = true);

    await fetchNearbyFindingUsers();
    if (!mounted) return;
    setState(() => loadingFinding = false);
  }

  Widget _statChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<void> fetchParticipantAvatars(List<String> ids) async {
    final uniqueIds = ids
        .where((id) => !_fetchingAvatarIds.contains(id))
        .toList();

    if (uniqueIds.isEmpty) return;

    for (final id in uniqueIds) {
      _fetchingAvatarIds.add(id);
    }
    if (ids.isEmpty) return;

    final res = await http.post(
      Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/users"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"ids": uniqueIds}),
    );

    if (res.statusCode != 200) return;

    final data = jsonDecode(res.body);

    final users = List<Map<String, dynamic>>.from(data['users'] ?? []);

    final Map<String, String> avatars = {};

    for (final u in users) {
      final userId = u['user_id']?.toString();
      if (userId != null) {
        avatars[userId] = u['avatar_url'] ?? '';
      }
    }

    setState(() {
      userAvatars = {
        ...userAvatars,
        ...avatars,
      };

      products = products.map((product) {
        final participants = product['participants'];

        if (participants is List) {
          final updatedParticipants = participants.map((p) {
            final id = p['user_id']?.toString();

            if (id != null &&
                avatars.containsKey(id) &&
                (avatars[id]?.isNotEmpty ?? false)) {
              return {
                ...p,
                'avatar_url': avatars[id],
              };
            }

            return p;
          }).toList();

          return {
            ...product,
            'participants': updatedParticipants,
          };
        }

        return product;
      }).toList();
    });
  }

  // 🔧 FIX: thêm stagger nhẹ giữa các request để tránh bắn quá nhiều
  // request invite-status cùng lúc (giảm áp lực server + cảm giác giật/chậm
  // trên máy yếu). Đây là fix tạm thời ở client; cách sửa triệt để vẫn là
  // thêm 1 API backend nhận nhiều product_id và trả kết quả 1 lần.
  void preloadInviteStatuses() {
    int delayMs = 0;
    const stagger = 60; // mỗi request cách nhau 60ms

    for (final product in products) {
      final int productId = int.tryParse(product['id'].toString()) ?? 0;
      if (productId != 0 && !inviteStatusMap.containsKey(productId)) {
        inviteStatusMap[productId] = null;

        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!mounted) return;
          fetchInviteStatus(productId);
        });

        delayMs += stagger;
      }
    }
  }




  Widget buildParticipantStack(
      String creatorId,
      List participants,
      ) {
    final creatorAvatar = creatorAvatars[creatorId] ?? '';

    return SizedBox(
      width: 32,
      height: 30,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            child: CircleAvatar(
              radius: 15,
              backgroundColor: Colors.white,
              child: CircleAvatar(
                radius: 13,
                backgroundImage: creatorAvatar.isNotEmpty
                    ? CachedNetworkImageProvider(creatorAvatar)
                    : null,
                child: creatorAvatar.isEmpty
                    ? const Icon(Icons.person, size: 13)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          child: Column(
            children: [
              const SizedBox(height: 20),
              // Tiêu đề + nút chat
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
                child: Row(
                  children: [
                    ShaderMask(
                      shaderCallback: (Rect bounds) =>
                          const LinearGradient(colors: [Colors.orange, Colors.red])
                              .createShader(bounds),
                      child: const Text(
                        "Lời mời",
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ),

                    const Spacer(),

                    // 🍻 KÈO CỦA TÔI
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MyKeoPage(
                              products: products,
                              myUserId: myUserId.toString(),
                            ),
                          ),

                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Colors.orange, Colors.deepOrange],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.orange.withOpacity(0.4),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: const [
                            Icon(Icons.local_bar, size: 16, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              "Kèo của tôi",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 🔔 NOTIFICATION ICON — thêm mới
                    ValueListenableBuilder<int>(
                      valueListenable: unreadNotiVN,
                      builder: (context, value, _) {
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.notifications, color: Colors.white),
                              onPressed: () {
                                unreadNotiVN.value = 0; // đánh dấu đã xem
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const NotificationPage()),
                                );
                              },
                            ),
                            if (value > 0)
                              Positioned(
                                right: 6,
                                top: 6,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    value > 9 ? "9+" : value.toString(),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),


                    // CHAT ICON
                    Stack(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chat_bubble, color: Colors.white),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const ChatListPage()),
                            ).then((_) => fetchChatCount());
                          },
                        ),
                        if (chatCount > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                  color: Colors.red, shape: BoxShape.circle),
                              child: Text(
                                "$chatCount",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),

              ),
// 👇 THÊM Ở ĐÂY
              _buildFindingToggleIfLoaded(),

              // 🔥 DANH SÁCH INLINE
              if (isFindingKeo) _buildNearbyFindingList(),

              const SizedBox(height: 10),
              // List sản phẩm
              Expanded(
                child: loading && products.isEmpty
                    ? ListView.builder(
                  itemCount: 5,
                  itemBuilder: (context, index) => buildInitialLoadingItem(),
                )
                    : NotificationListener<ScrollNotification>(
                  onNotification: (scrollInfo) {
                    if (scrollInfo is ScrollUpdateNotification) {
                      final metrics = scrollInfo.metrics;

                      if (!_loadingMore &&
                          !loading &&
                          hasMore &&
                          metrics.pixels >= metrics.maxScrollExtent - 150) {

                        _loadingMore = true;

                        fetchProducts().then((_) {
                          if (mounted) {
                            setState(() {
                              _loadingMore = false;
                            });
                          } else {
                            _loadingMore = false;
                          }
                        });
                      }
                    }
                    return false;
                  },
                  child: ListView.builder(
                    itemCount: products.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == products.length) {
                        return Column(
                          children: List.generate(2, (_) => buildLoadMoreShimmerItem()),
                        );
                      }



                      final product = products[index];

                      final participants =
                          product['participants'] ?? [];

// chỉ fetch khi chưa có avatar

                      final missingIds = participants
                          .where((p) => (p['avatar_url'] ?? '').toString().isEmpty)
                          .map((p) => p['user_id']?.toString())
                          .whereType<String>()
                          .toSet()
                          .toList();



                      final int productId = int.tryParse(product['id'].toString()) ?? 0;


                      final meta = product['meta'] ?? {};
                      final slots = meta['slots']?.toString() ?? '';
                      final time = meta['time']?.toString() ?? '';

                      final int maxPeople =
                          int.tryParse(slots) ?? 0;

                      final int joinedCount =
                          int.tryParse(product['joined_count']?.toString() ?? '0') ?? 0;

// 🔥 Hot nếu trên 70% chỗ đã đầy
                      final bool isHot =
                          maxPeople > 0 &&
                              joinedCount >= (maxPeople * 0.6);

// ⚡ Sắp diễn ra trong 24h tới
                      bool isSoon = false;

                      try {
                        final eventTime =
                        DateFormat("dd/MM/yyyy HH:mm").parse(time);

                        final diff =
                        eventTime.difference(DateTime.now());

                        isSoon =
                            diff.inHours <= 24 &&
                                diff.inSeconds > 0;
                      } catch (_) {}

// 🆕 Mới tạo trong 6h
                      bool isNew = false;

                      try {
                        final created =
                        DateTime.parse(product['date_created']);

                        isNew =
                            DateTime.now()
                                .difference(created)
                                .inHours <=
                                6;
                      } catch (_) {}

                      final String creatorId =
                          meta['creator_id']?.toString() ?? "0";

                      if (!hostStatsMap.containsKey(creatorId) &&
                          !_fetchingHostStats.contains(creatorId)) {

                        _fetchingHostStats.add(creatorId);

                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          fetchHostStats(creatorId).then((_) {
                            _fetchingHostStats.remove(creatorId);
                          });
                        });
                      }


                      final userStats = hostStatsMap[creatorId];
                      final String creatorName =
                          product['creatorName'] ?? '...';
                      final String pubName =
                          meta['pub_name']?.toString() ?? "Ẩn danh";
                      final address = meta['address']?.toString() ?? '';
                      final categories = product['category_names'] ?? '';

                      final metaData = product['meta_data'] as List? ?? [];

                      final priceRange = metaData.firstWhere(
                            (e) => e['key'] == 'price_range',
                        orElse: () => null,
                      )?['value'];

                      String priceText;

                      switch (priceRange) {
                        case null:
                        case '0':
                          priceText = "Miễn phí";
                          break;

                        case '50-100':
                          priceText = "50k - 100k";
                          break;

                        case '100-200':
                          priceText = "100k - 200k/Người";
                          break;

                        case '200-500':
                          priceText = "200k - 500k/Người";
                          break;

                        case '500+':
                          priceText = "500k+/Người";
                          break;

                        default:
                          priceText = "$priceRange";
                      }

                      final distance = getDistanceText(product);

                      return GestureDetector(
                        onTap: () async {
                          final userId = await StorageHelper.read("user_id") ?? "0";

                          bool hasJoined = false;
                          if (product['participants'] != null && product['participants'] is List) {
                            hasJoined = product['participants']
                                .any((p) => p['user_id'].toString() == userId);
                          }

                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ProductDetailPage(
                                product: product,
                                onJoin: (updatedProduct) {
                                  setState(() {
                                    product['joined_count'] =
                                    updatedProduct['joined_count'];

                                    product['participants'] =
                                    updatedProduct['participants'];

                                    final invite = inviteStatusMap[productId];

                                    if (invite != null) {
                                      inviteStatusMap[productId] = InviteStatus(
                                        isJoined: true,
                                        isFull: invite.isFull,
                                        status: invite.status,
                                        joinedCount: updatedProduct['joined_count'] ?? 0,
                                        maxPeople: invite.maxPeople,
                                      );
                                    }
                                  });
                                },
                              ),
                            ),
                          );
                        },
                        child: Card(
                          margin: const EdgeInsets.all(8),
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          color: Colors.white.withOpacity(0.15),
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Column(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: product["images"] != null &&
                                          product["images"] is List &&
                                          product["images"].isNotEmpty &&
                                          (product["images"][0]["src"] ?? '').isNotEmpty
                                          ? CachedNetworkImage(
                                        imageUrl: product["images"][0]["src"],
                                        width: 80,
                                        height: 80,
                                        fit: BoxFit.cover,
                                      )
                                          : Container(
                                        width: 80,
                                        height: 80,
                                        color: Colors.grey[300]?.withOpacity(0.3),
                                        child: const Icon(Icons.image, size: 40),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Builder(
                                      builder: (context) {
                                        final InviteStatus? invite =
                                        inviteStatusMap[productId];

                                        final int maxPeople =
                                            int.tryParse(product['meta']['slots']?.toString() ?? '0') ?? 0;

                                        final int joinedCount =
                                            inviteStatusMap[productId]?.joinedCount ??
                                                int.tryParse(product['joined_count']?.toString() ?? '0') ??
                                                0;

                                        if (maxPeople <= 0) return const SizedBox.shrink();

                                        return Padding(
                                          padding: const EdgeInsets.only(top: 6),
                                          child: Text(
                                            "🔥 Còn ${maxPeople - joinedCount} slots",
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 6),
                                    const SizedBox(height: 6),
                                    SizedBox(
                                      width: 90,
                                      height: 32,
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.orange,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          padding: EdgeInsets.zero,
                                        ),
                                        onPressed: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ProductDetailPage(product: product),
                                            ),
                                          );
                                        },
                                        child: const Text(
                                          "Vào phòng",
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),

                                  ],
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(product["name"].toString(),
                                          style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white)),
                                      const SizedBox(height: 4),

                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [

                                          if (isNew)
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 3,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withOpacity(0.25),
                                                borderRadius: BorderRadius.circular(10),
                                              ),
                                              child: const Text(
                                                "🆕 Mới tạo",
                                                style: TextStyle(
                                                  fontSize: 8,
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),

                                          if (isHot)
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 3,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.red.withOpacity(1),
                                                borderRadius: BorderRadius.circular(10),
                                              ),
                                              child: const Text(
                                                "🔥 Hot",
                                                style: TextStyle(
                                                  fontSize: 6,
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),


                                        ],
                                      ),

                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: categories
                                            .split(',')
                                            .map<Widget>((item) {

                                          final text = item.trim().toLowerCase();

                                          Color color = Colors.orangeAccent;

                                          if (text.contains('karaoke')) {
                                            color = Colors.orange;
                                          } else if (text.contains('nhậu')) {
                                            color = Colors.yellow;
                                          } else if (text.contains('beer')) {
                                            color = Colors.lightGreen;
                                          } else if (text.contains('bar')) {
                                            color = Colors.cyan;
                                          } else {
                                            color = Colors.white70;
                                          }

                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: color.withOpacity(0.15),
                                              borderRadius: BorderRadius.circular(20),
                                              border: Border.all(
                                                color: color.withOpacity(0.4),
                                              ),
                                            ),
                                            child: Text(
                                              item.trim(),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: color,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                      const SizedBox(height: 8),

                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.location_on,
                                            size: 14,
                                            color: Colors.orange,
                                          ),

                                          const SizedBox(width: 4),

                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.blue.withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(10),
                                              border: Border.all(
                                                color: Colors.blueAccent.withOpacity(0.5),
                                              ),
                                            ),
                                            child: Text(
                                              distance,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),

                                          const SizedBox(width: 6),

                                          Expanded(
                                            child: Text(
                                              pubName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.white70,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text("Thời gian: $time",
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.greenAccent)),
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (time.isNotEmpty)
                                            CountdownTimerText(timeString: time),

                                          if (time.isNotEmpty && isSoon)
                                            const SizedBox(width: 6),

                                          if (isSoon)
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                gradient: const LinearGradient(
                                                  colors: [
                                                    Color(0xFFFFA726),
                                                    Color(0xFFFF5722),
                                                  ],
                                                ),
                                                borderRadius: BorderRadius.circular(12),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.orange.withOpacity(0.5),
                                                    blurRadius: 3,
                                                    spreadRadius: 1,
                                                  ),
                                                ],
                                              ),
                                              child: const Text(
                                                "⚡ Sắp diễn ra",
                                                style: TextStyle(
                                                  fontSize: 8,
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text("$priceText • $slots slots",
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.white)),
                                      const SizedBox(height: 4),

                                      Row(
                                        children: [
                                          GestureDetector(
                                            onTap: () {
                                              Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) => UserInfoPage(
                                                    userId: myUserId,
                                                    username: creatorName,
                                                    targetUserId: int.parse(creatorId),
                                                    avatarUrl: creatorAvatars[creatorId],
                                                  ),
                                                ),
                                              );
                                            },
                                            child: buildParticipantStack(
                                              creatorId,
                                              product['participants'] ?? [],
                                            ),
                                          ),

                                          const SizedBox(width: 4),

                                          Expanded(
                                            child: Wrap(
                                              spacing: 4,
                                              runSpacing: 2,
                                              crossAxisAlignment: WrapCrossAlignment.center,
                                              children: [
                                                Text(
                                                  creatorName,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.orangeAccent,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),

                                                _statChip(
                                                  "⭐ ${userStats?['attendance_percent'] ?? 0}%",
                                                  Colors.yellow,
                                                ),

                                                _statChip(
                                                  "🧾 ${userStats?['total_keo'] ?? 0}",
                                                  Colors.yellow,
                                                ),

                                                _statChip(
                                                  "🎯 ${userStats?['real_join_percent'] ?? 0}%",
                                                  Colors.yellow,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      )
                                    ],
                                  ),
                                ),
                                FutureBuilder<String>(
                                  future: StorageHelper.read("user_id")
                                      .then((v) => v ?? "0"),
                                  builder: (context, myIdSnapshot) {
                                    final int myIdInt = int.tryParse(myIdSnapshot.data.toString()) ?? 0;
                                    final int creatorIdInt = int.tryParse(creatorId.toString()) ?? 0;

                                    final bool isSelf = myIdInt == creatorIdInt;

                                    if (isSelf) {
                                      return Tooltip(
                                        message: "Xóa",
                                        child: GestureDetector(
                                          onTap: () {
                                            final id = product["id"];
                                            final int productId = id != null ? int.tryParse(id.toString()) ?? 0 : 0;

                                            if (productId == 0) {
                                              debugPrint("❌ productId không hợp lệ");
                                              return;
                                            }

                                            _confirmDelete(context, productId);
                                          },
                                          child: Container(
                                            width: 30,
                                            height: 30,
                                            decoration: BoxDecoration(
                                              gradient: const LinearGradient(
                                                colors: [Color(0xFFE57373), Color(0xFFEF5350)], // đỏ nhạt → đỏ tươi
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              shape: BoxShape.circle,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withOpacity(0.3),
                                                  blurRadius: 6,
                                                  offset: const Offset(0, 3),
                                                ),
                                                BoxShadow(
                                                  color: Colors.red.withOpacity(0.2),
                                                  blurRadius: 8,
                                                  offset: const Offset(0, 4),
                                                ),
                                              ],
                                            ),
                                            child: const Icon(
                                              Icons.delete,
                                              color: Colors.white,
                                              size: 14,
                                            ),
                                          ),
                                        ),
                                      );
                                    }




                                    return Tooltip(
                                      message: "Chat với $creatorName",
                                      child: GestureDetector(
                                        onTap: () async {
                                          String avatarUrl = creatorAvatars[creatorId] ?? '';

                                          // Nếu avatar rỗng thì fetch lại 1 lần
                                          if (avatarUrl.isEmpty) {
                                            try {
                                              final res = await http.get(Uri.parse("${AppConfig.webDomain}/wp-json/profile/v1/user/$creatorId"));
                                              if (res.statusCode == 200) {
                                                final data = jsonDecode(res.body);
                                                avatarUrl = data['avatar_url'] ?? '';
                                                debugPrint("🟢 Avatar fetched trực tiếp từ API: $avatarUrl");
                                              }
                                            } catch (e) {
                                              debugPrint("❌ Lỗi fetch avatar trong onTap: $e");
                                            }
                                          }

                                          _openChat(
                                            creatorId,
                                            creatorNames[creatorId] ?? 'Người dùng',
                                            avatarUrl: avatarUrl,
                                          );
                                        },
                                        child: Container(
                                          width: 30,
                                          height: 30,
                                          decoration: BoxDecoration(
                                            gradient: const LinearGradient(colors: [Colors.orange, Colors.red]),
                                            shape: BoxShape.circle,
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.orange.withOpacity(0.5),
                                                blurRadius: 8,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: const Icon(Icons.chat_bubble, color: Colors.white, size: 12),
                                        ),
                                      ),
                                    );

                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),

        ),
      ),
    );
  }
}
class CountdownTimerText extends StatefulWidget {
  final String timeString;

  const CountdownTimerText({super.key, required this.timeString});

  @override
  State<CountdownTimerText> createState() => _CountdownTimerTextState();
}

class _CountdownTimerTextState extends State<CountdownTimerText> {
  late Timer _timer;
  Duration remaining = Duration.zero;
  bool grow = true;
  @override
  void initState() {
    super.initState();
    _calculateRemaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _calculateRemaining();
    });
  }

  void _calculateRemaining() {
    try {
      // ✅ Parse đúng format: 20/12/2025 19:30
      final targetTime =
      DateFormat("dd/MM/yyyy HH:mm").parse(widget.timeString);

      final now = DateTime.now();

      if (!mounted) return;

      setState(() {
        remaining = targetTime.difference(now);
      });
    } catch (e) {
      debugPrint("❌ Parse error: ${widget.timeString}");
      if (!mounted) return;

      setState(() {
        remaining = Duration.zero;
      });
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ---------------------------------
    // Đã quá 24h kể từ thời điểm bắt đầu
    // ---------------------------------
    if (remaining.isNegative &&
        remaining.abs().inHours >= 24) {
      return const SizedBox.shrink();
    }

    // ---------------------------------
    // Đã bắt đầu nhưng chưa quá 24h
    // ---------------------------------
    if (remaining.isNegative) {
      return TweenAnimationBuilder<double>(
        tween: Tween(
          begin: grow ? 0.95 : 1.08,
          end: grow ? 1.08 : 0.95,
        ),
        duration: const Duration(milliseconds: 800),
        onEnd: () {
          if (mounted) {
            setState(() {
              grow = !grow;
            });
          }
        },
        builder: (context, scale, child) {
          return Transform.scale(
            scale: scale,
            child: child,
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 5,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: Colors.redAccent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.redAccent.withOpacity(0.5),
                blurRadius: 5,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_fire_department,
                color: Colors.white,
                size: 10,
              ),
              SizedBox(width: 5),
              Text(
                "Đang diễn ra",
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ---------------------------------
    // Còn trên 24h
    // ---------------------------------
    if (remaining.inHours >= 24) {
      final int days = remaining.inDays;
      final int hours = remaining.inHours % 24;

      return Text(
        "📅 Còn $days ngày $hours giờ",
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFFB0B0B0),
          fontWeight: FontWeight.bold,
        ),
      );
    }

    // ---------------------------------
    // Còn dưới 24h -> countdown
    // ---------------------------------
    final int hours = remaining.inHours;
    final int minutes = remaining.inMinutes % 60;
    final int seconds = remaining.inSeconds % 60;

    return Text(
      "⏳ "
          "${hours.toString().padLeft(2, '0')}:"
          "${minutes.toString().padLeft(2, '0')}:"
          "${seconds.toString().padLeft(2, '0')}",
      style: const TextStyle(
        fontSize: 12,
        color: Colors.orangeAccent,
        fontWeight: FontWeight.bold,
      ),
    );
  }

}
class InviteStatus {
  final bool isJoined;
  final bool isFull;
  final String status;
  final int joinedCount;
  final int maxPeople;

  InviteStatus({
    required this.isJoined,
    required this.isFull,
    required this.status,
    required this.joinedCount,
    required this.maxPeople,
  });
}

class InviteListPopup extends StatefulWidget {
  final Map user;
  final Function(Map invite) onInviteSelected;

  const InviteListPopup({
    super.key,
    required this.user,
    required this.onInviteSelected,
  });

  @override
  State<InviteListPopup> createState() => _InviteListPopupState();
}

class _InviteListPopupState extends State<InviteListPopup> {
  bool loading = true;
  List invites = [];

  @override
  void initState() {
    super.initState();
    _loadInvites();
  }
  String _extractMeta(List<dynamic>? meta, String key) {
    if (meta == null) return "";

    try {
      final item = meta.firstWhere(
            (m) => m['key'] == key,
        orElse: () => null,
      );

      if (item == null) return "";
      return item['value']?.toString() ?? "";
    } catch (e) {
      return "";
    }
  }

  Future<void> _loadInvites() async {
    try {
      final myUserId = await StorageHelper.read("user_id") ?? "0";

      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/wc/v3/products"
            "?per_page=20"
            "&status=publish"
            "&consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
            "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
      );

      final res = await http.get(url);
      if (res.statusCode != 200) {
        throw "HTTP ${res.statusCode}";
      }

      final List list = jsonDecode(res.body);

      final myInvites = list.where((p) {
        final meta = (p['meta_data'] ?? []) as List;

        String creatorId = "0";

        for (final m in meta) {
          if (m['key'] == 'creator_id') {
            creatorId = m['value']?.toString() ?? "0";
            break;
          }
        }

        return creatorId == myUserId;
      }).map((p) {
        final images = (p['images'] ?? []) as List;
        final imageUrl = images.isNotEmpty ? images.first['src'] : null;

        return {
          "id": p['id'],
          "title": p['name'],
          "time": _extractMeta(p['meta_data'], 'time'),
          "image": imageUrl, // 👈 thêm image
        };
      }).toList();


      invites = myInvites;
    } catch (e) {
      debugPrint("❌ Load invite error: $e");
      invites = [];
    }

    if (mounted) {
      setState(() => loading = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.55,
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).padding.bottom,
      ),

      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF1E3A8A).withOpacity(0.9), // primaryBlue
            const Color(0xFFFF7F50).withOpacity(0.85), // accentOrange
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),


      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          Text(
            "Mời ${widget.user['display_name']}",
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 12),

          Expanded(
            child: loading
                ? ListView.builder(
              itemCount: 6,
              itemBuilder: (context, index) => _buildSkeletonItem(),
            )
                : invites.isEmpty
                ? const Center(
              child: Text(
                "Không có lời mời nào",
                style: TextStyle(color: Colors.white54),
              ),
            )
                : ListView.builder(
              itemCount: invites.length,
              itemBuilder: (context, index) {
                final invite = invites[index];

                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: invite['image'] != null
                          ? Image.network(
                        invite['image'],
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                      )
                          : Container(
                        width: 52,
                        height: 52,
                        color: Colors.white24,
                        child: const Icon(Icons.image, color: Colors.white54),
                      ),
                    ),
                    title: Text(
                      invite['title'],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      invite['time'],
                      style: const TextStyle(color: Colors.white70),
                    ),
                    trailing: SizedBox(
                      height: 32,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF7F50),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          minimumSize: Size.zero,
                        ),
                        onPressed: () {
                          widget.onInviteSelected(invite); // 👈 xử lý kèo này
                        },
                        child: const Text(
                          "Mời kèo",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                    onTap: () {
                      widget.onInviteSelected(invite);
                    },
                  ),
                );

              },
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text(
                "Tạo lời mời mới",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white, // 👈 thêm dòng này
                ),
              ),

              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF7F50),
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () async {
                Navigator.of(context).pop();

                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const CreateInvitePage(),
                  ),
                );

                if (mounted) {
                  setState(() => loading = true);
                  _loadInvites();
                }
              },
            ),
          ),


        ],
      ),
    );
  }
}
Widget _buildSkeletonItem() {
  return shimmer.Shimmer.fromColors(
    baseColor: Colors.white.withOpacity(0.08),
    highlightColor: Colors.white.withOpacity(0.18),
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 14, width: double.infinity, color: Colors.white),
                const SizedBox(height: 8),
                Container(height: 12, width: 120, color: Colors.white),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}