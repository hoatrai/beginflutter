import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:share_plus/share_plus.dart';
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
import '../main.dart' show unreadNotiVN, activeTabIndexVN;
import 'notification_page.dart';
import 'notification_store.dart';
import '../config/app_config.dart';
import '../services/location_permission_gate.dart';

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
  // 🔧 FIX 2 popup "bật định vị" chồng nhau: việc dedupe request vị trí
  // giờ nằm ở `LocationPermissionGate` (dùng chung toàn app, xem
  // services/location_permission_gate.dart) thay vì Future riêng ở đây,
  // vì bug thật sự xảy ra GIỮA ShopPage và PresenceService (2 nơi khác
  // nhau cùng xin quyền lúc app khởi động), không chỉ trong nội bộ trang
  // này.
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
  int _emptyPageCount = 0;
  bool _locationRefreshed = false;
  // 🆕 Retry / empty state
  bool hasError = false;
  // 🆕 Report/Block
  Set<String> blockedUserIds = {};
  // Thêm vào đầu class cùng chỗ với các biến khác
  int elapsedMinutes = 0;
  String? selectedCategory; // null = tất cả

  final ScrollController _findingScrollController = ScrollController();

  Timer? _elapsedTimer;
  DateTime? _startedAt;


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
    // ← THÊM VÀO CUỐI
    _elapsedTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      debugPrint("⏱️ Timer tick! isFindingKeo=$isFindingKeo _startedAt=$_startedAt mounted=$mounted");  // 🆕
      if (!mounted) return;
      // 🚀 Tab Shop đang bị ẩn (người dùng ở tab khác) → khỏi setState,
      // tránh rebuild cây widget không cần thiết cho 1 trang không hiển thị.
      if (activeTabIndexVN.value != 0) return;
      if (isFindingKeo && _startedAt != null) {
        setState(() {
          elapsedMinutes = DateTime.now().difference(_startedAt!).inMinutes;
        });
        debugPrint("⏱️ elapsedMinutes updated to $elapsedMinutes");  // 🆕
      }
    });
  }
  void _startAutoScroll() {

    autoScrollTimer?.cancel();

    autoScrollTimer = Timer.periodic(

      const Duration(milliseconds: 16),

          (timer) {

        if (!mounted) return;

        // 🚀 Đang ở tab khác (Map/Group/Profile...) → khỏi jumpTo(), tránh
        // ép layout lại ListView 60 lần/giây cho 1 trang không hiển thị.
        // IndexedStack giữ nguyên state ShopPage nên Timer vẫn chạy nền
        // nếu không chặn ở đây.
        if (activeTabIndexVN.value != 0) return;

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

      // 🆕 THÊM DÒNG NÀY ĐỂ XEM DATA THẬT
      debugPrint("🔍 Invite status for product $productId: $data");

      final invite = InviteStatus(
        isJoined: data['is_joined'] == true,
        isFull: data['is_full'] == true,
        status: data['status']?.toString() ?? "",
        joinedCount: int.tryParse(data['joined_count']?.toString() ?? "0") ?? 0,
        maxPeople: int.tryParse(data['max_people']?.toString() ?? "0") ?? 0,
      );

      inviteStatusMap[productId] = invite;

      final bool isClosed = invite.isFull ||
          invite.status == "closed" ||
          invite.status == "full" ||
          invite.status == "done";

      // 🆕 THÊM DÒNG NÀY
      debugPrint("🔍 productId=$productId isFull=${invite.isFull} status='${invite.status}' isClosed=$isClosed");

      if (isClosed) {
        if (!mounted) return;
        setState(() {
          products.removeWhere((p) => p['id'] == productId);
          inviteStatusMap.remove(productId);
        });
        return;
      }

    } catch (e) {
      debugPrint("🔴 fetchInviteStatus error: $e");
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

  Widget _buildFilterBar() {
    final filters = [
      {"label": "🍺 Nhậu", "value": "Nhậu"},
      {"label": "🎤 Karaoke", "value": "Karaoke"},
      {"label": "🍸 Bar/Pub", "value": "Bar/Pub"},
      {"label": "🍻 Beer Club", "value": "Beer Club"},
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Nút "Tất cả"
          GestureDetector(
            onTap: () {
              setState(() {
                selectedCategory = null;
                products.clear();
                page = 1;
                hasMore = true;
              });
              fetchProducts();
            },
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: selectedCategory == null
                    ? Colors.orange
                    : Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selectedCategory == null
                      ? Colors.orange
                      : Colors.white24,
                ),
              ),
              child: const Text(
                "🎯 Tất cả",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          ...filters.map((f) {
            final isSelected = selectedCategory == f['value'];
            // 🎨 Mỗi chip filter lấy đúng tone màu theo thể loại của nó
            // (giống categoryColor dùng cho card/nút hành động bên dưới),
            // thay vì luôn cố định màu cam cho mọi filter khi được chọn.
            final Color chipColor = _getCategoryColor(f['value']!);
            return GestureDetector(
              onTap: () {
                setState(() {
                  selectedCategory = f['value'];
                  products.clear();
                  page = 1;
                  hasMore = true;
                });
                fetchProducts();
              },
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected
                      ? chipColor
                      : Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected ? chipColor : Colors.white24,
                  ),
                ),
                child: Text(
                  f['label']!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ============================================================
  // 🔧 FIX 1: KHÔNG ĐỂ LỖI VỊ TRÍ LÀM TREO LOADING VĨNH VIỄN
  // 🔧 FIX 2: LẤY VỊ TRÍ NHANH (cache trước, GPS medium sau)
  // 🔧 FIX 3: CHẠY SONG SONG CÁC TÁC VỤ ĐỘC LẬP THAY VÌ TUẦN TỰ
  // ============================================================
  Future<void> _initFlow() async {
    // 1. Load userId + findingStatus + blocked list song song, nhẹ
    await Future.wait([
      _loadMyUserId(),
      loadFindingStatus(),
      fetchBlockedUsers(), // 🆕
    ]);

    // 2. Xin quyền vị trí ngầm (không chặn UI)
    _requestLocationOnFirstLoad();

    // 3. Load products KHÔNG chờ creator/invite
    await fetchProducts();

    // 4. Các tác vụ phụ chạy sau khi UI đã hiện
    fetchChatCount();
    connectSocket();
  }

  // 🆕 Lấy danh sách user đã bị mình chặn, để lọc feed/nearby ở client
  Future<void> fetchBlockedUsers() async {
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final res = await http.get(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/blocked-list"),
        headers: {"Authorization": "Bearer $token"},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true) {
          final ids = List.from(data['data'] ?? [])
              .map((e) => e.toString())
              .toSet();
          if (!mounted) return;
          setState(() => blockedUserIds = ids);
        }
      }
    } catch (e) {
      debugPrint("❌ fetchBlockedUsers error: $e");
    }
  }

  Future<void> _requestLocationOnFirstLoad() async {
    try {
      final granted =
      await _requestLocationPermissionShared(openSettingsDirectly: false);
      if (granted) _resolveMyLocationSilent();
    } catch (e) {
      debugPrint("⚠️ _requestLocationOnFirstLoad: $e");
    }
  }

  Future<void> _resolveMyLocationSilent() async {
    try {
      // Quyền đã được xác nhận `granted` bởi caller (_requestLocationOnFirstLoad
      // -> LocationPermissionGate) — không check/requestPermission lại ở đây
      // nữa để tránh gọi Geolocator dư thừa.
      final serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) return;

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

    if (products.isEmpty) {
      setState(() {
        page = 1;
        hasMore = true;
        _emptyPageCount = 0;
      });
      fetchProducts();
      return;
    }

    // Đã có sản phẩm → chỉ update khoảng cách, không reset list
    setState(() {
      for (final p in products) {
        p['distanceText'] = getDistanceText(p);
      }
    });
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
    if (_locationRefreshed) return; // ← THÊM DÒNG NÀY
    _locationRefreshed = true;      // ← THÊM DÒNG NÀY
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
        debugPrint("🕐 status response: ${res.body}");

        if (!mounted) return;

        // ← XÓA HẾT double check, chỉ giữ 1 lần check mounted
        bool stillActive = data['is_finding'].toString() == '1';
        debugPrint("🕐 stillActive: $stillActive"); // ← THÊM
        debugPrint("🕐 is_finding raw: ${data['is_finding']}"); // ← THÊM
        // Tính elapsed
        if (stillActive && data['started_at'] != null) {
          final fixedStarted = data['started_at'].toString().replaceFirst(' ', 'T');
          final startedAt = DateTime.parse(fixedStarted + 'Z');
          _startedAt = startedAt; // ← GÁN VÀO ĐÂY
          elapsedMinutes = DateTime.now().difference(startedAt).inMinutes;
          // 🆕 THÊM LOG
          debugPrint("🕐 raw started_at=${data['started_at']}");
          debugPrint("🕐 parsed startedAt(UTC)=$startedAt");
          debugPrint("🕐 now=${DateTime.now()}");
          debugPrint("🕐 elapsedMinutes=$elapsedMinutes");
        }

        // Check expire
        if (stillActive && data['expire_at'] != null) {
          final fixedExpire = data['expire_at'].toString().replaceFirst(' ', 'T');
          final expireAt = DateTime.parse(fixedExpire + 'Z');
          if (DateTime.now().isAfter(expireAt)) {
            stillActive = false;
          }
        }

        setState(() {
          isFindingKeo = stillActive;
          findingOption = data['finding_option'];
          // ← THÊM kiểm tra trước khi ghi đè
          if (data['activity_type'] != null &&
              data['activity_type'].toString().isNotEmpty) {
            activityType = data['activity_type'];
          }
        });

        if (stillActive) fetchNearbyFindingUsers();
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
  Future<bool> ensureLocationPermission(BuildContext context) {
    return _requestLocationPermissionShared(openSettingsDirectly: true);
  }

  /// Lõi xin quyền vị trí DÙNG CHUNG cho mọi nơi trong trang — giờ đi qua
  /// `LocationPermissionGate` dùng chung CHO TOÀN APP (không chỉ riêng
  /// trang này), vì `PresenceService` cũng cần xin quyền vị trí ngay lúc
  /// app khởi động (main.dart -> _bootstrap()), gần như cùng lúc với
  /// trang này. Trước đây mỗi bên tự dedupe riêng nên vẫn bị 2 popup
  /// "bật định vị" chồng lên nhau — giờ dùng chung 1 cổng nên chỉ còn
  /// đúng 1 request tại 1 thời điểm cho toàn app.
  ///
  /// [openSettingsDirectly] = true  -> hành vi "bắt buộc" (khi user chủ
  ///   động bấm nút, vd "Bật tìm kèo"): mở thẳng Cài đặt nếu thiếu quyền.
  /// [openSettingsDirectly] = false -> hành vi "nhẹ nhàng" (khi tự động
  ///   chạy lúc vào trang): chỉ hiện bottom sheet gợi ý, không tự mở Cài đặt.
  Future<bool> _requestLocationPermissionShared({
    required bool openSettingsDirectly,
  }) {
    return LocationPermissionGate.ensure(
      openSettingsDirectly: openSettingsDirectly,
      onNeedGps: () {
        if (mounted) {
          _showLocationDialog(context, "Vui lòng bật GPS để tìm kèo gần bạn.");
        }
      },
    );
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
    debugPrint("📤 findingKeoOn: activity=$activityType, option=$findingOption");
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
      debugPrint("📥 findingKeoOn response: ${res.statusCode} ${res.body}"); // ← THÊM


      return res.statusCode == 200;
    } catch (e) {
      debugPrint("❌ findingKeoOn error: $e");
      return false;
    }
  }


  Future<void> findingKeoOff() async {
    debugPrint("🔴 findingKeoOff called!");
    debugPrint(StackTrace.current.toString());
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final userId = await StorageHelper.read("user_id") ?? "0";
      debugPrint("🔴 findingKeoOff userId=$userId");

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

          // 🆕 lọc bỏ user đã bị mình chặn
          final users = List<Map<String, dynamic>>.from(data['data'])
              .where((u) => !blockedUserIds.contains(u['user_id'].toString()))
              .toList();

          // 🆕 THÊM LOG
          debugPrint("🔍 district=$districtName activity=${activityType ?? ''}");
          for (final u in users) {
            debugPrint("👤 user_id=${u['user_id']} is_finding=${u['is_finding']} expire=${u['expire_at']}");
          }

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

      // 🆕 THÊM: reconnect WS khi app về foreground
      _reconnectSocket();

    } else if (state == AppLifecycleState.paused) {
      // 🆕 THÊM: đóng WS khi app vào background
      if (_socketConnected) {
        heartbeatTimer?.cancel();
        channel.sink.close();
        _socketConnected = false;
      }
    }
  }

// 🆕 THÊM HÀM NÀY
  void _reconnectSocket() {
    if (_socketConnected) {
      heartbeatTimer?.cancel();
      channel.sink.close();
      _socketConnected = false;
    }
    connectSocket();

    // 🆕 Reload lại findingUsers sau reconnect để sync
    if (isFindingKeo) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) fetchNearbyFindingUsers();
      });
    }
  }

  @override
  void dispose() {
    autoScrollTimer?.cancel(); // 👈 THÊM DÒNG NÀY
    heartbeatTimer?.cancel();
    _elapsedTimer?.cancel(); // ← THÊM
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
          serverUrl: AppConfig.websocketUrl,
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
        // 🆕 Bỏ qua nếu creator đã bị mình chặn
        if (blockedUserIds.contains(creatorId)) return;

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
      final targetTime = DateFormat("dd/MM/yyyy HH:mm").parse(timeString);
      final expireTime = targetTime.add(const Duration(days: 1));
      final expired = DateTime.now().isAfter(expireTime);
      if (expired) debugPrint("⏰ Expired: $timeString");
      return expired;
    } catch (e) {
      debugPrint("⚠️ isExpiredInvite parse error: $timeString");
      return false; // ✅ parse lỗi → KHÔNG filter, vẫn hiện
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
    if (!hasMore || _loadingMore) return;
    debugPrint("🔄 fetchProducts page=$page emptyCount=$_emptyPageCount hasMore=$hasMore");
    if (!hasMore || _loadingMore) return;

    final isFirstPage = page == 1;

    setState(() {
      if (isFirstPage) loading = true;
      else _loadingMore = true;
    });

    try {
      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/wc/v3/products"
            "?status=publish&per_page=10&page=$page"
            "&orderby=date&order=desc"
        // 🚀 CHỈ lấy field cần dùng ở shop page thay vì cả schema WC
        // (description, attributes, variations, links...) → JSON nhẹ
        // hơn đáng kể, parse nhanh hơn, tốn ít băng thông hơn.
            "&_fields=id,name,price,images,meta_data,categories,date_created"
            "&consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
            "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
      );
      // ✅ MỚI - thêm after để chỉ lấy kèo mới tạo trong 2 ngày gần đây
      /*final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
      final afterDate = "${twoDaysAgo.year}-${twoDaysAgo.month.toString().padLeft(2,'0')}-${twoDaysAgo.day.toString().padLeft(2,'0')}T00:00:00";

      final url = Uri.parse(
        "${AppConfig.webDomain}/wp-json/wc/v3/products"
            "?status=publish&per_page=10&page=$page"
            "&orderby=date&order=desc"
            "&after=$afterDate"  // ✅ chỉ lấy kèo tạo trong 2 ngày gần đây
            "&consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
            "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
      );*/

      final response = await http.get(url);

      if (response.statusCode != 200) {
        setState(() {
          loading = false;
          _loadingMore = false;
          hasMore = false;
          hasError = true; // 🆕
        });
        return;
      }

      final List newProducts = json.decode(response.body);

      // ✅ Check hasMore từ API TRƯỚC khi filter
      final bool apiHasMore = newProducts.length >= 10;

      final List<Map<String, dynamic>> parsedProducts = [];
      final Set<String> creatorIds = {};

      for (var p in newProducts) {
        final productMap = parseProduct(p);

        // Lọc hết hạn
        final timeString = productMap['meta']['time']?.toString() ?? '';
        if (isExpiredInvite(timeString)) continue;

        // 🆕 Bỏ qua kèo của người đã bị chặn
        final creatorId = productMap['meta']['creator_id']?.toString() ?? "0";
        if (blockedUserIds.contains(creatorId)) continue;

        // Lọc 50km + cache distance
        try {
          final lat = double.tryParse(productMap['meta']['lat']?.toString() ?? '');
          final lng = double.tryParse(productMap['meta']['lng']?.toString() ?? '');

          if (lat == null || lng == null) {
            // ✅ không có tọa độ → vẫn hiện, không filter
            productMap['distanceKm'] = null;
            productMap['distanceText'] = "";
          } else if (myLat != null && myLng != null) {
            // ✅ có GPS → filter 50km
            final distanceKm = Geolocator.distanceBetween(myLat!, myLng!, lat, lng) / 1000;
            if (distanceKm > 50) continue;
            productMap['distanceKm'] = distanceKm;
            productMap['distanceText'] = "${distanceKm.toStringAsFixed(1)} km";
          } else {
            // ✅ chưa có GPS → hiện hết
            // chưa có GPS → không filter, hiện hết
            productMap['distanceKm'] = null;
            productMap['distanceText'] = "";
            debugPrint("⚠️ No GPS, showing product without distance filter");
          }
        } catch (e) {
          productMap['distanceKm'] = null;
          productMap['distanceText'] = "";
          // ❌ bỏ continue — lỗi tọa độ vẫn hiện sản phẩm
        }

        // Gom creator id
        if (creatorId != "0") creatorIds.add(creatorId);

        // Dùng cache nếu có
        productMap['creatorName'] = creatorNames[creatorId] ?? '...';
        productMap['creatorAvatar'] = creatorAvatars[creatorId] ?? '';

        parsedProducts.add(productMap);
      }

      // Sort chỉ trang mới
      parsedProducts.sort((a, b) {
        final d1 = (a['distanceKm'] as double?) ?? 9999;
        final d2 = (b['distanceKm'] as double?) ?? 9999;
        return d1.compareTo(d2);
      });

      setState(() {
        final existingIds = products.map((p) => p['id']).toSet();
        final newOnes = parsedProducts.where((p) => !existingIds.contains(p['id'])).toList();
        products.addAll(newOnes);
        loading = false;
        _loadingMore = false;
        hasMore = apiHasMore;
        hasError = false; // 🆕 fetch thành công thì clear error
        if (apiHasMore) page++;
      });

      debugPrint("✅ parsedProducts.length = ${parsedProducts.length}, apiHasMore=$apiHasMore, page=$page");

// ✅ Nếu trang này filter ra 0 nhưng API còn data → tự fetch trang tiếp
      if (parsedProducts.isEmpty && apiHasMore) {
        _emptyPageCount++;
        if (_emptyPageCount >= 3) {
          setState(() => hasMore = false);
          _emptyPageCount = 0;
          return; // ← dừng hẳn, không fetch tiếp
        }
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted && hasMore) fetchProducts();
      } else {
        _emptyPageCount = 0;
      }

      // Fetch creator + invite sau khi UI hiện
      // Fetch creator + lọc kèo đã đóng sau khi UI hiện
      // Fetch creator + badge slot + lọc kèo đã đóng sau khi UI hiện
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Future.wait([
          fetchCreatorsBulk(creatorIds.toList()),
          filterClosedProducts(),                  // 🆕 lọc kèo đã đóng
          Future(() => preloadInviteStatuses()),   // giữ badge "Còn X slots"
        ]);
      });

    } catch (e) {
      debugPrint("❌ fetchProducts error: $e");
      setState(() {
        loading = false;
        _loadingMore = false;
        hasMore = false;
        hasError = true; // 🆕
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
      height: 120,

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

                onLongPress: () {
                  // 🆕 nhấn giữ để báo cáo/chặn người tìm kèo
                  final userId = int.tryParse((u['user_id'] ?? 0).toString()) ?? 0;
                  final name = u['display_name']?.toString() ?? 'Người dùng';
                  if (userId == 0 || userId == myUserId) return;
                  _showReportBlockUserSheet(targetUserId: userId, targetUserName: name);
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
                                // 🚀 Giới hạn kích thước decode ~2x kích thước
                                // hiển thị (retina) thay vì decode ảnh full-size
                                // cho 1 avatar 44x44 → giảm RAM + CPU đáng kể
                                // khi list có nhiều item.
                                memCacheWidth: 88,
                                memCacheHeight: 88,
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

  // ============================================================
  // 🆕 REPORT + BLOCK
  // Gọi tới các endpoint /wp-json/nhau/v1/report, /block, /unblock
  // (xem modules/report-block.php phía backend)
  // ============================================================

  Future<void> _reportContent({
    required String targetType, // 'product' | 'user'
    required int targetId,
    required String reason,
    String note = '',
  }) async {
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/report"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "target_type": targetType,
          "target_id": targetId,
          "reason": reason,
          "note": note,
        }),
      );
      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['success'] == true) {
        _showSnackBar("✅ Đã gửi báo cáo, cảm ơn bạn");
      } else {
        _showSnackBar(data['message']?.toString() ?? "❌ Không thể gửi báo cáo");
      }
    } catch (e) {
      debugPrint("❌ _reportContent error: $e");
      _showSnackBar("❌ Lỗi khi gửi báo cáo");
    }
  }

  Future<void> _blockUser(int blockedId) async {
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/block"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({"blocked_id": blockedId}),
      );
      final data = jsonDecode(res.body);
      if (res.statusCode == 200 && data['success'] == true) {
        final idStr = blockedId.toString();
        if (!mounted) return;
        setState(() {
          blockedUserIds.add(idStr);
          products.removeWhere(
                (p) => (p['meta']['creator_id']?.toString() ?? '') == idStr,
          );
          findingUsers = findingUsers
              ?.where((u) => u['user_id'].toString() != idStr)
              .toList();
        });
        _showSnackBar("🚫 Đã chặn người dùng này");
      } else {
        _showSnackBar(data['message']?.toString() ?? "❌ Không thể chặn");
      }
    } catch (e) {
      debugPrint("❌ _blockUser error: $e");
      _showSnackBar("❌ Lỗi khi chặn người dùng");
    }
  }

  void _showReportReasonSheet({
    required String targetType,
    required int targetId,
  }) {
    final reasons = [
      {"label": "🚫 Nội dung không phù hợp", "value": "inappropriate"},
      {"label": "🎭 Lừa đảo / giả mạo", "value": "scam"},
      {"label": "🔞 Nội dung nhạy cảm", "value": "sensitive"},
      {"label": "😡 Quấy rối / xúc phạm", "value": "harassment"},
      {"label": "📛 Spam", "value": "spam"},
      {"label": "❓ Khác", "value": "other"},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue.withOpacity(0.95), accentOrange.withOpacity(0.9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text(
                "Vì sao bạn báo cáo?",
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...reasons.map((r) => GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  _reportContent(
                    targetType: targetType,
                    targetId: targetId,
                    reason: r['value']!,
                  );
                },
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Text(r['label']!, style: const TextStyle(color: Colors.white)),
                ),
              )),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmBlock(int blockedId, String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
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
                children: [
                  const Icon(Icons.block, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  const Text("Xác nhận chặn",
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                "Bạn sẽ không thấy kèo hoặc tin nhắn từ $name nữa. Tiếp tục?",
                style: const TextStyle(color: Colors.white70, fontSize: 14),
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text("Chặn"),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (result == true) await _blockUser(blockedId);
  }

  // 🆕 Bottom sheet report/block khi bấm vào 1 sản phẩm/kèo cụ thể
  void _showReportBlockSheet({
    required int productId,
    required int creatorId,
    required String creatorName,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue.withOpacity(0.95), accentOrange.withOpacity(0.9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.flag, color: Colors.orangeAccent),
                title: const Text("Báo cáo kèo này",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context);
                  _showReportReasonSheet(targetType: "product", targetId: productId);
                },
              ),
              ListTile(
                leading: const Icon(Icons.block, color: Colors.redAccent),
                title: Text("Chặn $creatorName",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context);
                  _confirmBlock(creatorId, creatorName);
                },
              ),
              ListTile(
                leading: const Icon(Icons.close, color: Colors.white70),
                title: const Text("Hủy", style: TextStyle(color: Colors.white70)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  // 🆕 Bottom sheet report/block khi nhấn giữ 1 user trong danh sách "đang tìm kèo"
  void _showReportBlockUserSheet({
    required int targetUserId,
    required String targetUserName,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return Container(
          padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue.withOpacity(0.95), accentOrange.withOpacity(0.9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.flag, color: Colors.orangeAccent),
                title: Text("Báo cáo $targetUserName",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context);
                  _showReportReasonSheet(targetType: "user", targetId: targetUserId);
                },
              ),
              ListTile(
                leading: const Icon(Icons.block, color: Colors.redAccent),
                title: Text("Chặn $targetUserName",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.pop(context);
                  _confirmBlock(targetUserId, targetUserName);
                },
              ),
              ListTile(
                leading: const Icon(Icons.close, color: Colors.white70),
                title: const Text("Hủy", style: TextStyle(color: Colors.white70)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
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

  // 🆕 Trạng thái lỗi mạng — có nút "Thử lại"
  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            const Text(
              "Không tải được danh sách kèo",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 6),
            const Text(
              "Kiểm tra kết nối mạng và thử lại nhé",
              style: TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  hasError = false;
                  page = 1;
                  hasMore = true;
                });
                fetchProducts();
              },
              icon: const Icon(Icons.refresh),
              label: const Text("Thử lại"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 🆕 Trạng thái rỗng — không có kèo nào phù hợp
  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text("🍻", style: TextStyle(fontSize: 48)),
            SizedBox(height: 12),
            Text(
              "Chưa có kèo nào gần bạn",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            SizedBox(height: 6),
            Text(
              "Thử đổi bộ lọc hoặc kéo xuống để làm mới",
              style: TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // 🆕 Pull-to-refresh: reset trang + fetch lại từ đầu + đồng bộ blocked-list
  Future<void> _handleRefresh() async {
    setState(() {
      page = 1;
      hasMore = true;
      hasError = false;
      _emptyPageCount = 0;
      products.clear();
    });
    await fetchProducts();
    await fetchBlockedUsers();
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
    channel = WebSocketChannel.connect(Uri.parse(AppConfig.websocketUrl));
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
        // 🆕 THÊM DÒNG NÀY để log tất cả event nhận được
        debugPrint("📨 WS event: ${decoded['event']}");

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
        // 🆕 Có người bật tìm kèo
        else if (decoded['event'] == 'finding_keo_on') {
          final payload = decoded['payload'];
          final String incomingUserId = payload['user_id'].toString();

          // Bỏ qua nếu là chính mình hoặc đã bị chặn
          if (incomingUserId == myUserId.toString()) return;
          if (blockedUserIds.contains(incomingUserId)) return; // 🆕

          final newUser = {
            'user_id':        incomingUserId,
            'display_name':   payload['username'] ?? 'Người dùng',
            'avatar_url':     payload['avatar'] ?? '',
            'district':       payload['district'] ?? '',
            'activity_type':  payload['activity_type'] ?? '',
            'finding_option': payload['finding_option'] ?? '',
            'is_online':      1,
            'lat':            payload['lat'],
            'lng':            payload['lng'],
          };

          if (!mounted) return;
          setState(() {
            final exists = findingUsers?.any(
                    (u) => u['user_id'].toString() == incomingUserId
            ) ?? false;

            if (!exists) {
              findingUsers = [...(findingUsers ?? []), newUser];
            }
          });
        }

        // 🆕 Có người tắt tìm kèo
        else if (decoded['event'] == 'finding_keo_off') {
          final String offUserId = decoded['payload']['user_id'].toString();

          debugPrint("🔴 finding_keo_off: offUserId=$offUserId myUserId=$myUserId");
          debugPrint("🔴 findingUsers: ${findingUsers?.map((u) => u['user_id']).toList()}");

          if (offUserId == myUserId.toString()) {
            debugPrint("🔴 Bỏ qua vì là chính mình");
            return;
          }

          if (!mounted) return;
          setState(() {
            findingUsers = findingUsers
                ?.where((u) => u['user_id'].toString() != offUserId)
                .toList();
          });

          debugPrint("🔴 findingUsers sau xóa: ${findingUsers?.map((u) => u['user_id']).toList()}");
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

  String _removeDiacritics(String str) {
    const withDia =
        'àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ'
        'ÀÁẢÃẠĂẰẮẲẴẶÂẦẤẨẪẬÈÉẺẼẸÊỀẾỂỄỆÌÍỈĨỊÒÓỎÕỌÔỒỐỔỖỘƠỜỚỞỠỢÙÚỦŨỤƯỪỨỬỮỰỲÝỶỸỴĐ';
    const withoutDia =
        'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd'
        'AAAAAAAAAAAAAAAAAEEEEEEEEEEEIIIIIOOOOOOOOOOOOOOOOOUUUUUUUUUUUYYYYYD';
    var result = str;
    for (int i = 0; i < withDia.length; i++) {
      result = result.replaceAll(withDia[i], withoutDia[i]);
    }
    return result;
  }

  int _categoryTagPriority(String rawName) {
    final text = _removeDiacritics(rawName.trim().toLowerCase());
    if (text.contains('nhau')) return 0;
    if (text.contains('karaoke')) return 1;
    if (text.contains('bar') || text.contains('pub')) return 2;
    if (text.contains('beer')) return 3;
    return 99;
  }

  /// 🔗 Chia sẻ 1 kèo ra ngoài app (Zalo, Messenger, SMS, Facebook...) qua
  /// share sheet của hệ điều hành (share_plus). Vì app hiện chưa có deep
  /// link mở thẳng đúng kèo cho người CHƯA cài app (chỉ có trang cài app
  /// chung "/quet-ma"), nội dung share gồm đủ thông tin để người nhận
  /// biết kèo gì trước khi tải app + link cài app kèm sẵn keo_id (khi nào
  /// làm deep link/dynamic link thật thì trang /quet-ma chỉ cần đọc query
  /// keo_id để tự mở đúng kèo sau khi cài xong).
  Future<void> _shareKeo(Map<String, dynamic> product) async {
    try {
      final id = product['id']?.toString() ?? '';
      final name = (product['name'] ?? 'Kèo nhậu').toString();
      final meta = product['meta'] ?? {};
      final time = meta['time']?.toString() ?? '';
      final pubName = meta['pub_name']?.toString() ?? '';
      final address = meta['address']?.toString() ?? '';

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

      final link = "${AppConfig.webDomain}/quet-ma?keo_id=$id";

      final buffer = StringBuffer()
        ..writeln("🍻 $name")
        ..writeln();
      if (pubName.isNotEmpty) buffer.writeln("📍 $pubName${address.isNotEmpty ? ' - $address' : ''}");
      if (time.isNotEmpty) buffer.writeln("🕒 $time");
      buffer.writeln("💰 $priceText");
      buffer.writeln();
      buffer.writeln("Tham gia kèo cùng mình nè 👇");
      buffer.writeln(link);

      final box = context.findRenderObject() as RenderBox?;
      await Share.share(
        buffer.toString(),
        subject: name,
        sharePositionOrigin:
        box != null ? (box.localToGlobal(Offset.zero) & box.size) : null,
      );
    } catch (e) {
      debugPrint("❌ _shareKeo: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Không thể chia sẻ kèo này, thử lại sau.")),
        );
      }
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
        _selectTime("Bây giờ");                // ✅ bỏ chọn giờ, luôn là "Ngay bây giờ"
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isFindingKeo && activityType != null
                        ? "🟢 Đang tìm kèo: $activityType"
                        : "🎯 Bật để tìm kèo nhanh!",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,   // 👈 THÊM
                    maxLines: 1,                       // 👈 THÊM
                  ),
                  if (isFindingKeo) ...[
                    const SizedBox(height: 2),
                    Text(
                      "Đã chờ: $elapsedMinutes phút  •  ${findingUsers?.length ?? 0} người phù hợp",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,   // 👈 THÊM
                      maxLines: 1,                       // 👈 THÊM
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: isFindingKeo,
              // 🟢 Đổi thành xanh lá, đồng bộ với nút "Chia sẻ" của card
              // thể loại Nhậu (Colors.lightGreen trong _getCategoryColor).
              activeColor: Colors.lightGreen,
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
              Text(
                "${_getActivityEmoji()} Bạn muốn ${activityType?.toLowerCase()} lúc nào?",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              _timeOption("🔥 Ngay bây giờ",     "Bây giờ"),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }
  String _getActivityEmoji() {
    switch (activityType) {
      case "Nhậu":      return "🍺";
      case "Karaoke":   return "🎤";
      case "Bar/Pub":   return "🍸";
      case "Beer Club": return "🍻";
      default:          return "🎯";
    }
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

    final ok = await findingKeoOn();
    if (!mounted) return;

    if (!ok) {
      setState(() => loadingFinding = false);
      _showSnackBar("⚠️ Không thể bật tìm kèo (mất GPS/mạng), thử lại nhé.");
      return;
    }

    setState(() {
      isFindingKeo = true;
      _startedAt = DateTime.now(); // ← THÊM
      elapsedMinutes = 0;          // ← THÊM
      userChangedFinding = false; // ← THÊM
    });
    await loadFindingStatus(); // ← THÊM: lấy started_at mới từ server

    //await fetchNearbyFindingUsers();
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

  // 🎨 Màu theo thể loại — cùng nhóm giá trị với filter bar (🍺 Nhậu,
  // 🎤 Karaoke, 🍸 Bar/Pub, 🍻 Beer Club). categoryNames có thể là chuỗi
  // gộp nhiều category ("Nhậu, Karaoke") nên match theo "chứa" thay vì so
  // khớp tuyệt đối; ưu tiên theo thứ tự liệt kê bên dưới khi có nhiều match.
  Color _getCategoryColor(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('karaoke')) return const Color(0xFFFF7F50); // cam, đồng bộ tone accentOrange của app
    if (lower.contains('beer')) return const Color(0xFFFFC107); // vàng hổ phách, nổi trên nền xanh dương
    if (lower.contains('nhậu')) return Colors.lightGreen;
    if (lower.contains('bar') || lower.contains('pub')) return Colors.cyan;
    return Colors.white70;
  }

  // 🎨 Gradient 2 màu cùng "họ" với _getCategoryColor(), dùng để đồng bộ
  // toàn bộ nút hành động của 1 kèo (Vào phòng / Chat / Chia sẻ) theo
  // đúng màu thể loại — thay vì mỗi nút tự hardcode 1 màu khác nhau như
  // trước (chat luôn cam-đỏ, share luôn xanh lá, không liên quan gì tới
  // thể loại thật của kèo).
  List<Color> _getCategoryGradient(String text) {
    final base = _getCategoryColor(text);
    final hsl = HSLColor.fromColor(base);
    final darker = hsl
        .withLightness((hsl.lightness - 0.18).clamp(0.0, 1.0))
        .toColor();
    return [base, darker];
  }

  // 🖼️ Ghép nhiều ảnh trong 1 card (collage), giống layout Facebook:
  //  - 1 ảnh  -> full-bleed
  //  - 2 ảnh  -> chia đôi ngang nhau
  //  - >=3 ảnh -> 1 ảnh lớn bên trái + 2 ảnh nhỏ xếp chồng bên phải,
  //               ảnh nhỏ cuối cùng có badge "+N" nếu còn dư ảnh chưa hiện.
  // 🎥🖼️ Giong _buildImageCollage nhung uu tien video lam o lon (neu co),
  // anh van hien xen ke o cac o con ben canh - khong an mat anh khi co video.
  Widget _buildMediaCollage(Map<String, dynamic> product, String? videoUrl) {
    const double gap = 3.0;

    if (videoUrl == null) {
      return _buildImageCollage(product);
    }

    final rawImages = product["images"];
    final List imagesList = rawImages is List ? rawImages : [];
    final List<String> urls = imagesList
        .map((e) => (e is Map ? e["src"] : null)?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();

    Widget videoMainCell() => _CardVideoPreview(url: videoUrl);

    Widget subCell(String url, {String? badge}) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(
              color: Colors.black26,
              child: const Icon(Icons.broken_image, color: Colors.white38),
            ),
          ),
          if (badge != null)
            Container(
              color: Colors.black.withOpacity(0.55),
              alignment: Alignment.center,
              child: Text(
                badge,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 19,
                ),
              ),
            ),
        ],
      );
    }

    // Video nhung khong co anh nao -> video full-bleed
    if (urls.isEmpty) {
      return videoMainCell();
    }

    // Video + 1 anh -> chia doi ngang nhau
    if (urls.length == 1) {
      return Row(
        children: [
          Expanded(child: videoMainCell()),
          const SizedBox(width: gap),
          Expanded(child: subCell(urls[0])),
        ],
      );
    }

    // Video + >=2 anh -> video lon ben trai, 2 anh nho xep chong ben phai
    // (anh thu 2 co badge "+N" neu con du anh chua hien)
    final int extra = urls.length - 2;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: videoMainCell(),
        ),
        const SizedBox(width: gap),
        Expanded(
          flex: 2,
          child: Column(
            children: [
              Expanded(child: subCell(urls[0])),
              const SizedBox(height: gap),
              Expanded(
                child: subCell(
                  urls[1],
                  badge: extra > 0 ? "+$extra" : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImageCollage(Map<String, dynamic> product) {
    const double gap = 3.0;

    final rawImages = product["images"];
    final List imagesList = rawImages is List ? rawImages : [];
    final List<String> urls = imagesList
        .map((e) => (e is Map ? e["src"] : null)?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();

    if (urls.isEmpty) {
      return Container(
        color: const Color(0xFF2A2340),
        child: const Icon(Icons.image, size: 48, color: Colors.white38),
      );
    }

    Widget mainCell(String url) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final double w = constraints.maxWidth.isFinite ? constraints.maxWidth : 400;
          final double h = constraints.maxHeight.isFinite ? constraints.maxHeight : 240;
          return HeroProductImage(
            tag: 'product-image-${product["id"]}',
            imageUrl: url,
            width: w,
            height: h,
            fit: BoxFit.cover,
          );
        },
      );
    }

    Widget subCell(String url, {String? badge}) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(
              color: Colors.black26,
              child: const Icon(Icons.broken_image, color: Colors.white38),
            ),
          ),
          if (badge != null)
            Container(
              color: Colors.black.withOpacity(0.55),
              alignment: Alignment.center,
              child: Text(
                badge,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 19,
                ),
              ),
            ),
        ],
      );
    }

    // 1 ảnh -> full-bleed như thiết kế gốc
    if (urls.length == 1) {
      return mainCell(urls[0]);
    }

    // 2 ảnh -> chia đôi ngang nhau
    if (urls.length == 2) {
      return Row(
        children: [
          Expanded(child: mainCell(urls[0])),
          const SizedBox(width: gap),
          Expanded(child: subCell(urls[1])),
        ],
      );
    }

    // >=3 ảnh -> 1 ảnh lớn trái + 2 ảnh nhỏ xếp chồng phải
    final int extra = urls.length - 3;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: mainCell(urls[0]),
        ),
        const SizedBox(width: gap),
        Expanded(
          flex: 2,
          child: Column(
            children: [
              Expanded(child: subCell(urls[1])),
              const SizedBox(height: gap),
              Expanded(
                child: subCell(
                  urls[2],
                  badge: extra > 0 ? '+$extra' : null,
                ),
              ),
            ],
          ),
        ),
      ],
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

  // 🚀 FIX TRIỆT ĐỂ: thay vì bắn N request riêng lẻ (có stagger 60ms/request
  // như trước — với 10 sản phẩm là 10 round-trip + 30 query SQL), giờ gom
  // hết productId cần lấy status lại và gọi backend đúng 1 lần duy nhất
  // qua endpoint bulk /invite/by-products (2-3 query SQL cho cả trang).
  void preloadInviteStatuses() {
    final ids = <int>[];
    for (final product in products) {
      final int productId = int.tryParse(product['id'].toString()) ?? 0;
      if (productId != 0 && !inviteStatusMap.containsKey(productId)) {
        inviteStatusMap[productId] = null;
        ids.add(productId);
      }
    }
    if (ids.isEmpty) return;
    fetchInviteStatusesBulk(ids);
  }

  /// Lấy invite-status cho NHIỀU sản phẩm cùng lúc trong 1 request.
  /// Thay thế cho việc gọi fetchInviteStatus() N lần.
  Future<void> fetchInviteStatusesBulk(List<int> productIds) async {
    if (productIds.isEmpty) return;

    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final idsParam = productIds.join(',');

      final res = await http
          .get(
        Uri.parse(
          "${AppConfig.webDomain}/wp-json/nhau/v1/invite/by-products?ids=$idsParam",
        ),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
      )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        throw Exception("HTTP ${res.statusCode}");
      }

      final decoded = jsonDecode(res.body);
      if (decoded['success'] != true) return;

      final Map<String, dynamic> data = decoded['data'] ?? {};
      final Set<int> closedProductIds = {};

      for (final idStr in data.keys) {
        final productId = int.tryParse(idStr);
        if (productId == null) continue;

        final item = data[idStr];

        final invite = InviteStatus(
          isJoined: item['is_joined'] == true,
          isFull: item['is_full'] == true,
          status: item['status']?.toString() ?? "",
          joinedCount: int.tryParse(item['joined_count']?.toString() ?? "0") ?? 0,
          maxPeople: int.tryParse(item['max_people']?.toString() ?? "0") ?? 0,
        );

        inviteStatusMap[productId] = invite;

        final bool isClosed = invite.isFull ||
            invite.status == "closed" ||
            invite.status == "full" ||
            invite.status == "done";

        if (isClosed) closedProductIds.add(productId);
      }

      if (!mounted) return;
      setState(() {
        if (closedProductIds.isNotEmpty) {
          products.removeWhere((p) => closedProductIds.contains(p['id']));
          for (final id in closedProductIds) {
            inviteStatusMap.remove(id);
          }
        }
      });
    } catch (e) {
      debugPrint("🔴 fetchInviteStatusesBulk error: $e");
      // Fallback: nếu bulk lỗi (vd backend chưa deploy endpoint mới),
      // vẫn đảm bảo UI không bị treo badge — set trạng thái lỗi nhẹ.
      for (final id in productIds) {
        inviteStatusMap[id] ??= InviteStatus(
          isJoined: false,
          isFull: false,
          status: "error",
          joinedCount: 0,
          maxPeople: 0,
        );
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> filterClosedProducts() async {
    if (products.isEmpty) return;

    final ids = products.map((p) => p['id'].toString()).join(',');

    try {
      final res = await http
          .get(Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/products-status?ids=$ids"))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body);
      if (data['success'] != true) return;

      final Map<String, dynamic> statusMap = data['data'];

      if (!mounted) return;
      setState(() {
        products.removeWhere((p) {
          final status = statusMap[p['id'].toString()];
          if (status == null) return false;
          // 🎯 CHỈ ẩn khi đóng (host tự đóng), KHÔNG ẩn khi đầy
          return status['is_closed'] == true;
        });
      });

      debugPrint("✅ filterClosedProducts done, còn lại ${products.length} kèo");
    } catch (e) {
      debugPrint("❌ filterClosedProducts error: $e");
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
                    ? CachedNetworkImageProvider(
                  creatorAvatar,
                  // 🚀 avatar hiển thị ~26x26 (radius 13) → không cần
                  // decode ảnh full-size, giới hạn ~52px (x2 cho retina)
                  maxWidth: 52,
                  maxHeight: 52,
                )
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
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const NotificationPage()),
                                ).then((_) {
                                  // Đồng bộ lại badge với số thông báo THỰC SỰ
                                  // chưa đọc (người dùng có thể chỉ đọc vài cái
                                  // trong trang Thông báo chứ không phải hết).
                                  unreadNotiVN.value = NotificationStore.unreadCount.value;
                                });
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
              const SizedBox(height: 6),
              _buildFilterBar(), // ← THÊM
              const SizedBox(height: 10),

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
                    : (!loading && products.isEmpty)
                    ? RefreshIndicator(
                  onRefresh: _handleRefresh,
                  color: Colors.orange,
                  backgroundColor: primaryBlue,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
                      hasError ? _buildErrorState() : _buildEmptyState(),
                    ],
                  ),
                )
                    : RefreshIndicator(
                  onRefresh: _handleRefresh,
                  color: Colors.orange,
                  backgroundColor: primaryBlue,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (scrollInfo) {
                      if (scrollInfo is ScrollEndNotification) { // ✅ chỉ trigger khi dừng scroll
                        final metrics = scrollInfo.metrics;

                        if (!_loadingMore &&
                            !loading &&
                            hasMore &&
                            metrics.pixels >= metrics.maxScrollExtent - 300) { // 🆕 tăng threshold

                          fetchProducts(); // ← fetchProducts tự handle loading state bên trong
                        }
                      }
                      return false;
                    },
                    child: Builder(
                      builder: (context) {
                        final filtered = selectedCategory == null
                            ? products
                            : products.where((p) {
                          final cats = p['category_names']?.toString().toLowerCase() ?? '';
                          return cats.contains(selectedCategory!.toLowerCase());
                        }).toList();

                        return ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: filtered.length + (hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == filtered.length) {
                              if (!hasMore) return const SizedBox.shrink();
                              return Column(
                                children: List.generate(3, (_) => buildLoadMoreShimmerItem()),
                              );
                            }

                            final product = filtered[index];

                            final participants = product['participants'] ?? [];

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

                            final int maxPeople = int.tryParse(slots) ?? 0;

                            final int joinedCount =
                                int.tryParse(product['joined_count']?.toString() ?? '0') ?? 0;

                            final bool isHot =
                                maxPeople > 0 && joinedCount >= (maxPeople * 0.6);

                            bool isSoon = false;
                            bool isLive = false;
                            try {
                              final eventTime = DateFormat("dd/MM/yyyy HH:mm").parse(time);
                              final diff = eventTime.difference(DateTime.now());
                              isSoon = diff.inHours <= 24 && diff.inSeconds > 0;
                              // Da bat dau nhung chua qua 24h -> dang dien ra
                              isLive = diff.isNegative && diff.abs().inHours < 24;
                            } catch (_) {}

                            bool isNew = false;
                            try {
                              final created = DateTime.parse(product['date_created']);
                              isNew = DateTime.now().difference(created).inHours <= 6;
                            } catch (_) {}

                            final String creatorId = meta['creator_id']?.toString() ?? "0";

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
                            final String creatorName = product['creatorName'] ?? '...';
                            final String pubName = meta['pub_name']?.toString() ?? "Ẩn danh";
                            final address = meta['address']?.toString() ?? '';
                            final categories = (product['category_names'] ?? '').toString();

                            final metaData = product['meta_data'] as List? ?? [];

                            // Lay video dau tien (neu co) tu meta_data, giong
                            // cach parse ben product_detail_page.dart.
                            String? cardVideoUrl;
                            for (final item in metaData) {
                              if (item is Map && item['key'] == 'videos') {
                                final raw = item['value'];
                                if (raw != null && raw.toString().isNotEmpty) {
                                  try {
                                    final decoded = jsonDecode(raw.toString());
                                    final List list = decoded is String
                                        ? (jsonDecode(decoded) as List)
                                        : (decoded as List);
                                    if (list.isNotEmpty) {
                                      cardVideoUrl = list.first.toString();
                                    }
                                  } catch (_) {}
                                }
                                break;
                              }
                            }

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

                            final distance = product['distanceText'] ?? "";

                            // 🎨 Màu/gradient chung cho toàn bộ nút hành động
                            // (Vào phòng / Chat / Chia sẻ) của kèo này, đồng
                            // bộ theo thể loại (Nhậu/Karaoke/Bar-Pub/Beer Club).
                            final Color categoryColor = _getCategoryColor(categories);
                            final List<Color> categoryGradient =
                            _getCategoryGradient(categories);

                            return GestureDetector(
                              onTap: () async {
                                final userId = await StorageHelper.read("user_id") ?? "0";

                                bool hasJoined = false;
                                if (product['participants'] != null &&
                                    product['participants'] is List) {
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
                                          product['joined_count'] = updatedProduct['joined_count'];
                                          product['participants'] = updatedProduct['participants'];

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
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                child: _StatusGlowCard(
                                  active: isLive || isSoon,
                                  colorLight: isLive ? Colors.lightGreen : const Color(0xFFFFC107),
                                  colorStrong: isLive ? const Color(0xFF558B2F) : const Color(0xFFFF9800),
                                  duration: isLive
                                      ? const Duration(milliseconds: 1400)
                                      : const Duration(milliseconds: 2400),
                                  intensity: isLive ? 1.0 : 0.55,
                                  child: AspectRatio(
                                    aspectRatio: 1.55,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        // Nen khung (lo ra thanh 1 vien mong quanh anh
                                        // sau khi anh duoc padding vao trong) - dung
                                        // dung gradient xanh duong -> cam giong nen
                                        // ngoai cua trang, thay vi mau den rieng.
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(24),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  primaryBlue.withOpacity(0.9),
                                                  accentOrange.withOpacity(0.8),
                                                ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                            ),
                                          ),
                                        ),

                                        // Anh nen: ghep nhieu anh (collage), duoc "thut"
                                        // vao trong 1 chut (padding) de lo vien khung ra.
                                        // Khi dang dien ra: anh ben trong "tho" phong-xep
                                        // nhe, ClipRRect ben ngoai giu nguyen kich thuoc
                                        // nen khong tran ra de card ben canh.
                                        Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(19),
                                            child: _BreathingScale(
                                              active: isLive,
                                              child: _buildMediaCollage(product, cardVideoUrl),
                                            ),
                                          ),
                                        ),

                                        // Lop phu toi dan ve day the (scrim) - chi phu
                                        // trong vung anh (cung padding voi anh).
                                        Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: IgnorePointer(
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(19),
                                                gradient: LinearGradient(
                                                  begin: Alignment.topCenter,
                                                  end: Alignment.bottomCenter,
                                                  stops: const [0.0, 0.36, 0.70, 1.0],
                                                  colors: [
                                                    Colors.black.withOpacity(0.02),
                                                    Colors.black.withOpacity(0.10),
                                                    Colors.black.withOpacity(0.62),
                                                    Colors.black.withOpacity(0.96),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),

                                        // Vien mau theo the loai: chi 2 goc cheo (trai-tren
                                        // + phai-duoi), dang "bracket" giong mau ban gui,
                                        // thay vi vien full bao quanh 4 canh.
                                        Positioned(
                                          top: 10,
                                          left: 10,
                                          child: IgnorePointer(
                                            child: _CornerAccent(
                                              color: categoryColor.withOpacity(isHot ? 1.0 : 0.95),
                                              glow: categoryColor.withOpacity(0.55),
                                              armLength: isHot ? 30 : 26,
                                              thickness: isHot ? 3 : 2.6,
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          bottom: 10,
                                          right: 10,
                                          child: IgnorePointer(
                                            child: RotatedBox(
                                              quarterTurns: 2,
                                              child: _CornerAccent(
                                                color: categoryColor.withOpacity(isHot ? 1.0 : 0.95),
                                                glow: categoryColor.withOpacity(0.55),
                                                armLength: isHot ? 30 : 26,
                                                thickness: isHot ? 3 : 2.6,
                                              ),
                                            ),
                                          ),
                                        ),

                                        // Hang tren cung: chip the loai (trai) + khoang cach (phai)
                                        Positioned(
                                          top: 14,
                                          left: 14,
                                          right: 14,
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Wrap(
                                                  spacing: 6,
                                                  runSpacing: 6,
                                                  children: [
                                                    ...(categories.split(',')
                                                        .map((e) => e.trim())
                                                        .where((e) => e.isNotEmpty)
                                                        .toList()
                                                      ..sort((a, b) {
                                                        final pa = _categoryTagPriority(a);
                                                        final pb = _categoryTagPriority(b);
                                                        if (pa != pb) return pa.compareTo(pb);
                                                        return a.toLowerCase().compareTo(b.toLowerCase());
                                                      }))
                                                        .asMap()
                                                        .entries
                                                        .map((entry) {
                                                      final bool isPrimary = entry.key == 0;
                                                      final String label = entry.value;
                                                      final Color chipColor = _getCategoryColor(label);
                                                      return Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                                                        decoration: BoxDecoration(
                                                          color: isPrimary ? chipColor : Colors.black.withOpacity(0.5),
                                                          borderRadius: BorderRadius.circular(100),
                                                          border: isPrimary
                                                              ? null
                                                              : Border.all(color: Colors.white.withOpacity(0.3)),
                                                        ),
                                                        child: Text(
                                                          label,
                                                          style: TextStyle(
                                                            fontSize: 10.5,
                                                            fontWeight: FontWeight.w700,
                                                            letterSpacing: 0.2,
                                                            color: Colors.white,
                                                            shadows: const [
                                                              Shadow(
                                                                color: Colors.black45,
                                                                blurRadius: 2,
                                                                offset: Offset(0, 0.5),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      );
                                                    }),
                                                    if (isLive)
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                        decoration: BoxDecoration(
                                                          gradient: const LinearGradient(
                                                            colors: [Color(0xFFFF3B30), Color(0xFFFF7043)],
                                                          ),
                                                          borderRadius: BorderRadius.circular(100),
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: const Color(0xFFFF3B30).withOpacity(0.5),
                                                              blurRadius: 8,
                                                              spreadRadius: 1,
                                                            ),
                                                          ],
                                                        ),
                                                        child: const Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            _PulsingDot(),
                                                            SizedBox(width: 5),
                                                            Text(
                                                              "LIVE",
                                                              style: TextStyle(
                                                                fontSize: 10,
                                                                color: Colors.white,
                                                                fontWeight: FontWeight.w800,
                                                                letterSpacing: 0.5,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    if (isNew)
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                        decoration: BoxDecoration(
                                                          color: const Color(0xFF2E7D32),
                                                          borderRadius: BorderRadius.circular(100),
                                                        ),
                                                        child: const Text(
                                                          "\u{1F195} M\u1EDAI",
                                                          style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700),
                                                        ),
                                                      ),
                                                    if (isHot)
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                        decoration: BoxDecoration(
                                                          gradient: const LinearGradient(
                                                            colors: [Color(0xFFFF7043), Color(0xFFE53935)],
                                                          ),
                                                          borderRadius: BorderRadius.circular(100),
                                                        ),
                                                        child: const Text(
                                                          "\u{1F525} HOT",
                                                          style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              if (distance.toString().isNotEmpty)
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withOpacity(0.6),
                                                    borderRadius: BorderRadius.circular(100),
                                                    border: Border.all(color: Colors.white.withOpacity(0.25)),
                                                  ),
                                                  child: Text(
                                                    distance.toString(),
                                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),

                                        // Cot nut hanh dong noi ben phai (chat / bao cao / chia se)
                                        Positioned(
                                          right: 12,
                                          bottom: 108,
                                          child: Column(
                                            children: [
                                              GestureDetector(
                                                onTap: () async {
                                                  String avatarUrl = creatorAvatars[creatorId] ?? '';
                                                  if (avatarUrl.isEmpty) {
                                                    try {
                                                      final res = await http.get(Uri.parse(
                                                          "${AppConfig.webDomain}/wp-json/profile/v1/user/$creatorId"));
                                                      if (res.statusCode == 200) {
                                                        final data = jsonDecode(res.body);
                                                        avatarUrl = data['avatar_url'] ?? '';
                                                      }
                                                    } catch (e) {
                                                      debugPrint("Loi fetch avatar: $e");
                                                    }
                                                  }
                                                  _openChat(
                                                    creatorId,
                                                    creatorNames[creatorId] ?? 'Nguoi dung',
                                                    avatarUrl: avatarUrl,
                                                  );
                                                },
                                                child: Container(
                                                  width: 32,
                                                  height: 32,
                                                  decoration: BoxDecoration(
                                                    gradient: LinearGradient(
                                                      colors: categoryGradient,
                                                      begin: Alignment.topLeft,
                                                      end: Alignment.bottomRight,
                                                    ),
                                                    shape: BoxShape.circle,
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color: categoryColor.withOpacity(0.5),
                                                        blurRadius: 8,
                                                        offset: const Offset(0, 4),
                                                      ),
                                                    ],
                                                  ),
                                                  child: const Icon(Icons.chat_bubble, color: Colors.white, size: 14),
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                              if (myUserId != int.tryParse(creatorId))
                                                Tooltip(
                                                  message: "Bao cao / Chan",
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      final id = product["id"];
                                                      final int pid = id != null ? int.tryParse(id.toString()) ?? 0 : 0;
                                                      if (pid == 0) return;
                                                      _showReportBlockSheet(
                                                        productId: pid,
                                                        creatorId: int.tryParse(creatorId) ?? 0,
                                                        creatorName: creatorName,
                                                      );
                                                    },
                                                    child: Container(
                                                      width: 32,
                                                      height: 32,
                                                      decoration: BoxDecoration(
                                                        color: Colors.black38,
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white24),
                                                      ),
                                                      child: const Icon(Icons.more_horiz, color: Colors.white70, size: 16),
                                                    ),
                                                  ),
                                                )
                                              else
                                                Tooltip(
                                                  message: "Xoa keo nay",
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      final id = product["id"];
                                                      final int pid = id != null ? int.tryParse(id.toString()) ?? 0 : 0;
                                                      if (pid == 0) return;
                                                      _confirmDelete(context, pid);
                                                    },
                                                    child: Container(
                                                      width: 32,
                                                      height: 32,
                                                      decoration: BoxDecoration(
                                                        color: Colors.black38,
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white24),
                                                      ),
                                                      child: const Icon(Icons.delete, color: Colors.redAccent, size: 16),
                                                    ),
                                                  ),
                                                ),
                                              const SizedBox(height: 10),
                                              Tooltip(
                                                message: "Chia se keo nay",
                                                child: GestureDetector(
                                                  onTap: () => _shareKeo(product),
                                                  child: Container(
                                                    width: 32,
                                                    height: 32,
                                                    decoration: BoxDecoration(
                                                      gradient: LinearGradient(
                                                        colors: categoryGradient,
                                                        begin: Alignment.topLeft,
                                                        end: Alignment.bottomRight,
                                                      ),
                                                      shape: BoxShape.circle,
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: categoryColor.withOpacity(0.4),
                                                          blurRadius: 6,
                                                          offset: const Offset(0, 3),
                                                        ),
                                                      ],
                                                    ),
                                                    child: const Icon(Icons.share, color: Colors.white, size: 14),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                        // Noi dung day the: tieu de, host, gio/gia, so slot con lai
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(18, 0, 66, 16),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  product["name"].toString(),
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                    height: 1.2,
                                                    shadows: [Shadow(blurRadius: 16, color: Colors.black87)],
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                GestureDetector(
                                                  onTap: () {
                                                    Navigator.push(
                                                      context,
                                                      MaterialPageRoute(
                                                        builder: (context) => UserInfoPage(
                                                          userId: myUserId,
                                                          username: creatorName,
                                                          targetUserId: int.parse(creatorId),
                                                          avatarUrl: creatorAvatars[creatorId],
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      buildParticipantStack(creatorId, product['participants'] ?? []),
                                                      const SizedBox(width: 6),
                                                      Flexible(
                                                        child: Wrap(
                                                          spacing: 4,
                                                          runSpacing: 2,
                                                          crossAxisAlignment: WrapCrossAlignment.center,
                                                          children: [
                                                            Text(
                                                              creatorName,
                                                              style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700),
                                                            ),
                                                            _statChip("\u2B50 ${userStats?['attendance_percent'] ?? 0}%", categoryColor),
                                                            _statChip("\u{1F9FE} ${userStats?['total_keo'] ?? 0}", categoryColor),
                                                            _statChip("\u{1F3AF} ${userStats?['real_join_percent'] ?? 0}%", categoryColor),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(height: 10),
                                                Row(
                                                  crossAxisAlignment: CrossAxisAlignment.end,
                                                  children: [
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          Row(
                                                            children: [
                                                              Icon(Icons.access_time, size: 12, color: categoryColor),
                                                              const SizedBox(width: 4),
                                                              Expanded(
                                                                child: Text(
                                                                  time,
                                                                  maxLines: 1,
                                                                  overflow: TextOverflow.ellipsis,
                                                                  style: const TextStyle(fontSize: 11.5, color: Colors.white70, fontWeight: FontWeight.w500),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          const SizedBox(height: 3),
                                                          Text(
                                                            priceText,
                                                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                                                          ),
                                                          if (time.isNotEmpty || isSoon)
                                                            Padding(
                                                              padding: const EdgeInsets.only(top: 4),
                                                              child: Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  if (time.isNotEmpty) CountdownTimerText(timeString: time),
                                                                  if (time.isNotEmpty && isSoon) const SizedBox(width: 6),
                                                                  if (isSoon)
                                                                    Container(
                                                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                                                      decoration: BoxDecoration(
                                                                        gradient: const LinearGradient(
                                                                          colors: [Color(0xFFFFA726), Color(0xFFFF5722)],
                                                                        ),
                                                                        borderRadius: BorderRadius.circular(12),
                                                                      ),
                                                                      child: const Text(
                                                                        "\u26A1 S\u1EAEP DI\u1EC4N RA",
                                                                        style: TextStyle(fontSize: 9.5, color: Colors.white, fontWeight: FontWeight.w700),
                                                                      ),
                                                                    ),
                                                                ],
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Builder(builder: (context) {
                                                      final int maxPeopleSlot = int.tryParse(product['meta']['slots']?.toString() ?? '0') ?? 0;
                                                      final int joinedNow = inviteStatusMap[productId]?.joinedCount ??
                                                          int.tryParse(product['joined_count']?.toString() ?? '0') ?? 0;
                                                      final int remaining = maxPeopleSlot - joinedNow;
                                                      if (maxPeopleSlot <= 0) return const SizedBox.shrink();
                                                      final bool urgent = remaining <= 2;
                                                      return Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                                        decoration: BoxDecoration(
                                                          color: urgent ? const Color(0x38FF5A5A) : categoryColor.withOpacity(0.18),
                                                          borderRadius: BorderRadius.circular(100),
                                                          border: Border.all(
                                                            color: urgent ? const Color(0x80FF7870) : categoryColor,
                                                          ),
                                                        ),
                                                        child: Text(
                                                          urgent ? "\u{1F525} C\u00F2n $remaining slot" : "C\u00F2n $remaining slots",
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            fontWeight: FontWeight.w700,
                                                            color: urgent ? const Color(0xFFFF9D8F) : categoryColor,
                                                          ),
                                                        ),
                                                      );
                                                    }),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                            );
                          },
                        ); // đóng ListView.builder
                      }, // đóng Builder builder
                    ), // đóng Builder
                  ), // đóng NotificationListener
                ), // đóng RefreshIndicator
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

// =============================================================================
// DÁN KHỐI NÀY VÀO CUỐI FILE shop_page.dart CỦA BẠN
// Chỉ cần đúng 1 class này thôi, không cần StoryProgressCarousel / DoubleTapReaction
// (2 cái đó chỉ dùng bên ProductDetailPage).
// =============================================================================

// Dùng CÙNG tag ở cả 2 nơi:
//  - Widget ảnh trong item của ShopPage (danh sách)     -> 'product-image-${product["id"]}'
//  - Widget ảnh đầu tiên trong carousel của ProductDetailPage (cùng tag để Hero khớp)

// 🎯 Vien goc dang "bracket" (2 net ngan tao hinh chu L) dung cho card san
// pham, thay the cho vien full bao quanh 4 canh - dat o 2 goc cheo nhau.
// 🔴🟡 Vien glow nhap nhay bao quanh card, dung chung cho ca trang thai
// "Dang dien ra" (do, nhip nhanh, manh) va "Sap dien ra" (vang cam, nhip
// cham, diu hon) - phan cap muc do khan cap bang mau/toc do/cuong do.
// Neu active = false thi tra ve nguyen child, khong ton animation.
// 💚 Anh ben trong card "tho" phong len - xep xuong nhe (Transform.scale
// 1.0 -> 1.045) khi keo dang "Dang dien ra". Dat BEN TRONG ClipRRect cua
// card nen phan tran ra ngoai bi cat gon, khong lam doi kich thuoc card
// va khong dam sang card ben canh trong ListView.
// 🎥 Preview video tu phat (mute + loop) ngay trong card danh sach, thay
// cho anh tinh khi keo co video. Khong dung Hero (khac co che voi anh)
// de tranh xung dot animation khi chuyen sang trang chi tiet.
// 🛡️ FIX CRASH: giới hạn số video được phép init/play CÙNG LÚC trong toàn
// app. Nguyên nhân crash gốc: ListView.builder build sẵn vài card phía
// trước/sau viewport (cache extent) → nếu nhiều card có video đứng gần
// nhau, tất cả tự autoplay cùng lúc trong initState() → vượt quá số lượng
// decoder phần cứng (MediaCodec) máy hỗ trợ đồng thời → crash NATIVE mà
// try/catch phía Dart không bắt được. Giải pháp: chỉ init/play khi card
// THẬT SỰ hiện rõ trên màn hình (VisibilityDetector), và cap số video
// đang chạy đồng thời qua toàn app.
class _VideoPlaybackLimiter {
  static const int maxConcurrent = 2;
  static final List<_CardVideoPreviewState> _active = [];

  static bool requestSlot(_CardVideoPreviewState s) {
    if (_active.contains(s)) return true;
    if (_active.length >= maxConcurrent) return false;
    _active.add(s);
    return true;
  }

  static void release(_CardVideoPreviewState s) {
    _active.remove(s);
  }
}

class _CardVideoPreview extends StatefulWidget {
  final String url;
  const _CardVideoPreview({required this.url});

  @override
  State<_CardVideoPreview> createState() => _CardVideoPreviewState();
}

class _CardVideoPreviewState extends State<_CardVideoPreview> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _error = false;
  bool _initializing = false;
  bool _visible = false;
  // key riêng cho mỗi State (không đổi theo url) để VisibilityDetector
  // không bị nhầm lẫn khi Flutter reuse widget trong ListView.
  final Key _visibilityKey = UniqueKey();

  void _onVisibilityChanged(VisibilityInfo info) {
    final isVisible = info.visibleFraction > 0.55;
    if (isVisible == _visible) return;
    _visible = isVisible;

    if (_visible) {
      _tryInit();
    } else {
      _teardown();
    }
  }

  Future<void> _tryInit() async {
    if (_initializing || _controller != null) return;
    if (!_VideoPlaybackLimiter.requestSlot(this)) {
      // Hết chỗ (đã có đủ video khác đang play) → giữ placeholder,
      // KHÔNG init để tránh vượt giới hạn decoder.
      return;
    }
    _initializing = true;
    try {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await ctrl.initialize();
      await ctrl.setLooping(true);
      await ctrl.setVolume(0);

      // Có thể widget đã bị cuộn ra ngoài / dispose trong lúc đang chờ
      // initialize (network chậm) → phải dọn ngay, không được play.
      if (!mounted || !_visible) {
        ctrl.dispose();
        _VideoPlaybackLimiter.release(this);
        _initializing = false;
        return;
      }

      await ctrl.play();
      if (!mounted || !_visible) {
        ctrl.dispose();
        _VideoPlaybackLimiter.release(this);
        _initializing = false;
        return;
      }

      setState(() {
        _controller = ctrl;
        _ready = true;
      });
    } catch (e) {
      _VideoPlaybackLimiter.release(this);
      if (mounted) setState(() => _error = true);
    } finally {
      _initializing = false;
    }
  }

  // Dispose hẳn controller khi card cuộn ra khỏi màn hình (không chỉ
  // pause) để trả decoder về cho các video khác — đây là phần quan
  // trọng nhất giúp không bao giờ vượt quá _VideoPlaybackLimiter.maxConcurrent.
  void _teardown() {
    _VideoPlaybackLimiter.release(this);
    final ctrl = _controller;
    _controller = null;
    if (ctrl != null) {
      ctrl.pause();
      ctrl.dispose();
    }
    if (mounted && _ready) {
      setState(() => _ready = false);
    } else {
      _ready = false;
    }
  }

  @override
  void dispose() {
    _VideoPlaybackLimiter.release(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: _onVisibilityChanged,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_error) {
      return Container(
        color: const Color(0xFF2A2340),
        child: const Icon(Icons.videocam_off, size: 40, color: Colors.white38),
      );
    }
    if (!_ready || _controller == null) {
      return Container(
        color: const Color(0xFF2A2340),
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),
        // Icon nho bao "video dang mute", tranh gay khong hieu tai sao im lang.
        Positioned(
          right: 8,
          top: 8,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.volume_off, size: 12, color: Colors.white),
          ),
        ),
      ],
    );
  }
}

class _BreathingScale extends StatefulWidget {
  final bool active;
  final Widget child;
  const _BreathingScale({required this.active, required this.child});

  @override
  State<_BreathingScale> createState() => _BreathingScaleState();
}

class _BreathingScaleState extends State<_BreathingScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _BreathingScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && oldWidget.active) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double scale = 1.0 + 0.045 * _controller.value;
        return Transform.scale(scale: scale, child: child);
      },
      child: widget.child,
    );
  }
}

class _StatusGlowCard extends StatefulWidget {
  final bool active;
  final Color colorLight;
  final Color colorStrong;
  final Duration duration;
  final double intensity; // 0..1, nhan vao do dam cua glow
  final Widget child;
  const _StatusGlowCard({
    required this.active,
    required this.colorLight,
    required this.colorStrong,
    required this.child,
    this.duration = const Duration(milliseconds: 1400),
    this.intensity = 1.0,
  });

  @override
  State<_StatusGlowCard> createState() => _StatusGlowCardState();
}

class _StatusGlowCardState extends State<_StatusGlowCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _StatusGlowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.dispose();
      _controller = AnimationController(vsync: this, duration: widget.duration);
      if (widget.active) _controller.repeat(reverse: true);
      return;
    }
    if (widget.active && !oldWidget.active) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && oldWidget.active) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double t = _controller.value; // 0 -> 1 -> 0 (reverse)
        final double k = widget.intensity;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Color.lerp(
                widget.colorLight,
                widget.colorStrong,
                t,
              )!.withOpacity(0.55 + 0.40 * k),
              width: 1.4 + 0.6 * k,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.colorStrong.withOpacity((0.18 + t * 0.28) * k),
                blurRadius: (8 + t * 12) * k,
                spreadRadius: (0.5 + t * 2) * k,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

// 🔴 Cham nho nhap nhay dat canh chu "LIVE" trong badge, tao cam giac
// dang phat truc tiep, dong bo phong cach voi cac badge dang co (HOT, MOI).
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> {
  bool _grow = true;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: _grow ? 0.55 : 1.0, end: _grow ? 1.0 : 0.55),
      duration: const Duration(milliseconds: 700),
      onEnd: () {
        if (mounted) setState(() => _grow = !_grow);
      },
      builder: (context, scale, child) {
        return Opacity(
          opacity: scale,
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _CornerAccent extends StatelessWidget {
  final Color color;
  final Color glow;
  final double armLength;
  final double thickness;

  const _CornerAccent({
    required this.color,
    required this.glow,
    required this.armLength,
    required this.thickness,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: armLength,
      height: armLength,
      child: CustomPaint(
        painter: _CornerAccentPainter(
          color: color,
          glow: glow,
          thickness: thickness,
        ),
      ),
    );
  }
}

class _CornerAccentPainter extends CustomPainter {
  final Color color;
  final Color glow;
  final double thickness;

  _CornerAccentPainter({
    required this.color,
    required this.glow,
    required this.thickness,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final glowPaint = Paint()
      ..color = glow
      ..strokeWidth = thickness + 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Net ngang (canh tren) + net doc (canh trai) tao hinh chu L o goc
    // tren-trai; khi RotatedBox 180 do se thanh goc duoi-phai.
    final horizontal = [Offset(0, 0), Offset(size.width, 0)];
    final vertical = [Offset(0, 0), Offset(0, size.height)];

    for (final p in [glowPaint, linePaint]) {
      canvas.drawLine(horizontal[0], horizontal[1], p);
      canvas.drawLine(vertical[0], vertical[1], p);
    }
  }

  @override
  bool shouldRepaint(covariant _CornerAccentPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.glow != glow ||
        oldDelegate.thickness != thickness;
  }
}

class HeroProductImage extends StatelessWidget {
  final String tag;
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius borderRadius;

  const HeroProductImage({
    super.key,
    required this.tag,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  Widget build(BuildContext context) {
    // 🚀 Chỉ decode ảnh ở kích thước thực tế hiển thị (x devicePixelRatio),
    // tránh decode/giữ trong RAM ảnh gốc full-size cho 1 thumbnail 80x80.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final int? cacheW = width != null ? (width! * dpr).round() : null;
    final int? cacheH = height != null ? (height! * dpr).round() : null;

    return Hero(
      tag: tag,
      flightShuttleBuilder: (context, animation, direction, fromCtx, toCtx) {
        return ClipRRect(
          borderRadius: borderRadius,
          child: (direction == HeroFlightDirection.push ? toCtx : fromCtx)
              .widget,
        );
      },
      child: ClipRRect(
        borderRadius: borderRadius,
        child: CachedNetworkImage(
          imageUrl: imageUrl,
          width: width,
          height: height,
          fit: fit,
          memCacheWidth: cacheW,
          memCacheHeight: cacheH,
          errorWidget: (_, __, ___) => Container(
            width: width,
            height: height,
            color: Colors.black26,
            child: const Icon(Icons.broken_image, color: Colors.white38),
          ),
        ),
      ),
    );
  }
}