import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'helpers/lifecycle_tracker.dart';
import 'services/global_call_service.dart';
import 'app_globals.dart';
import 'helpers/storage_helper.dart';
import 'pages/profile_page.dart';
import 'pages/shop_page.dart';
import 'pages/flutter_map.dart';
import 'pages/group_page.dart';
import 'pages/create_invite_page.dart';
import 'pages/splash_page.dart';
import 'pages/product_detail_page.dart';
import 'pages/chat_page.dart';
import 'pages/notification_store.dart';

// ---------------- GLOBAL STATE ----------------

final ValueNotifier<int> unreadNotiVN = ValueNotifier<int>(0);

String? pendingKeoId;
Map<String, dynamic>? _pendingCallData; // lưu FCM call khi app bị terminated
OverlayEntry? _appNotificationOverlay;
Timer? _notificationDismissTimer;

class WooCommerceConfig {
  static const consumerKey = 'ck_3809ad31dd47ca7d10573e35ccdf746494b305a9';
  static const consumerSecret = 'cs_a49b903ddc7972646359f360d79343cd1e33b6f8';
  static const productsUrl = 'https://spiritwebs.com/wp-json/wc/v3/products';
}

// ---------------- FIREBASE BACKGROUND HANDLER ----------------

// Khi app bị tắt hoàn toàn, FCM notification field sẽ tự hiện notification
// trên Android — không cần flutter_local_notifications.
// Handler này chỉ cần init Firebase, không làm gì thêm.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('Background message: ${message.messageId}');
  // Android tự hiện notification nếu server gửi kèm "notification" field trong FCM payload
}

// ---------------- CALL PAYLOAD HANDLER ----------------

/// Xử lý data call — dùng chung cho tap notification & getInitialMessage
void _handleCallPayload(Map<String, dynamic> data) {
  if (data['type'] != 'video_call') return;

  final overlay = navigatorKey.currentState?.overlay;
  if (overlay == null) {
    // Navigator chưa sẵn sàng → lưu lại xử lý sau trong MainPage.initState
    _pendingCallData = data;
    return;
  }
  GlobalCallService.instance.handleFcmCall(data);
}

// ---------------- OPEN CHAT / INVITE ----------------

Future<void> _openChatFromData(Map<String, dynamic> data) async {
  try {
    final senderId = int.tryParse(data['sender_id'] ?? '0') ?? 0;
    final senderName = data['sender_username'] ?? 'Người dùng';

    final me = await fetchMe();
    if (me == null) return;

    final myId = int.tryParse(me['id'].toString()) ?? 0;
    final myUsername = me['username'] ?? '';

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          userId: myId,
          username: myUsername,
          targetId: senderId,
          targetUser: senderName,
        ),
      ),
    );
  } catch (e) {
    debugPrint("Open chat error: $e");
  }
}

Future<void> openChatFromNotification(RemoteMessage message) =>
    _openChatFromData(message.data);

Future<void> openChatFromData(Map<String, dynamic> data) =>
    _openChatFromData(data);

// ---------------- ENTRY POINT ----------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await setupFirebaseMessaging();
  } catch (e) {
    debugPrint('⚠️ Firebase init failed: $e');
  }

  runApp(const CryptoApp(initialPage: SplashPage()));
}

// ---------------- API HELPERS ----------------

Future<Map<String, dynamic>?> _fetchProductById(String productId) async {
  try {
    final uri = Uri.parse(
      "${WooCommerceConfig.productsUrl}/$productId"
          "?consumer_key=${WooCommerceConfig.consumerKey}"
          "&consumer_secret=${WooCommerceConfig.consumerSecret}",
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  } catch (e) {
    debugPrint("Fetch product error: $e");
    return null;
  }
}

Future<void> _navigateToInvite(String keoId) async {
  final product = await _fetchProductById(keoId);
  if (product == null) return;
  navigatorKey.currentState?.push(
    MaterialPageRoute(builder: (_) => ProductDetailPage(product: product)),
  );
}

Future<void> openInviteFromNotification(RemoteMessage message) async {
  final keoId = message.data['keo_id'];
  if (keoId == null) return;
  await _navigateToInvite(keoId);
}

Future<void> openInviteById(String keoId) => _navigateToInvite(keoId);

// ---------------- IN-APP NOTIFICATION BANNER ----------------

void showAppNotification({required String title, required String body}) {
  final overlay = navigatorKey.currentState?.overlay;
  if (overlay == null) return;

  _notificationDismissTimer?.cancel();
  _appNotificationOverlay?.remove();

  _appNotificationOverlay = OverlayEntry(
    builder: (context) {
      return Positioned(
        top: 60,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1E3A8A).withOpacity(0.95),
                  const Color(0xFFFF7F50).withOpacity(0.85),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active,
                          color: Colors.white, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              body,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(_appNotificationOverlay!);

  _notificationDismissTimer = Timer(const Duration(seconds: 3), () {
    _appNotificationOverlay?.remove();
    _appNotificationOverlay = null;
  });
}

// ---------------- FIREBASE MESSAGING SETUP ----------------

Future<void> setupFirebaseMessaging() async {
  final messaging = FirebaseMessaging.instance;

  final settings = await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  debugPrint('Permission: ${settings.authorizationStatus}');

  final token = await messaging.getToken();
  debugPrint("FCM Token: $token");

  await messaging.subscribeToTopic("all_devices");

  // Foreground: app đang mở
  FirebaseMessaging.onMessage.listen((message) {
    final type = message.data['type'];

    if (type == 'video_call') {
      GlobalCallService.instance.handleFcmCall(message.data);
      return;
    }
    if (type == 'call_cancel') {
      GlobalCallService.instance.cancelPendingCall(message.data['topic']);
      return;
    }

    final title = message.notification?.title ?? "Thông báo";
    final body = message.notification?.body ?? "";

    NotificationStore.add(
      title: title,
      body: body,
      type: type,
      data: message.data,
    );

    unreadNotiVN.value++;

    // Không hiện banner nếu đang mở đúng cuộc chat với người gửi tin
    final senderId = int.tryParse(message.data['sender_id'] ?? '') ?? -1;
    final isChattingWithSender =
        isChatPageOpen && currentChatTargetId != null && currentChatTargetId == senderId;

    // ✅ Không hiện banner nếu đang mở đúng nhóm chat nhận tin
    final groupId = int.tryParse(message.data['group_id'] ?? '') ?? -1; // đổi key nếu backend đặt tên khác
    final isViewingSameGroup =
        isGroupChatPageOpen && currentGroupChatId != null && currentGroupChatId == groupId;

    if (!isChattingWithSender && !isViewingSameGroup) {
      showAppNotification(title: title, body: body);
    }
  });

  // Background: app chưa tắt, user tap notification
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    debugPrint('onMessageOpenedApp: ${message.data}');
    final type = message.data['type'];
    if (type == 'video_call') {
      _handleCallPayload(message.data);
    } else if (type == 'invite_keo') {
      openInviteFromNotification(message);
    } else if (type == 'chat_message') {
      openChatFromNotification(message);
    }
  });

  // Terminated: app bị tắt hoàn toàn, user tap notification mở app
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    final type = initialMessage.data['type'];
    if (type == 'video_call') {
      // Lưu lại, xử lý sau khi navigator sẵn sàng (MainPage._openPendingCall)
      _pendingCallData = initialMessage.data;
    } else if (type == 'invite_keo') {
      pendingKeoId = initialMessage.data['keo_id'];
    } else if (type == 'chat_message') {
      Future.delayed(
        const Duration(seconds: 1),
            () => openChatFromNotification(initialMessage),
      );
    }
  }
}

// ---------------- APP ROOT ----------------

class CryptoApp extends StatelessWidget {
  final Widget initialPage;
  const CryptoApp({super.key, required this.initialPage});

  @override
  Widget build(BuildContext context) {
    return AppLifecycleTracker(
      onStateChanged: (state) {
        debugPrint("🔥 APP STATE => $state");
      },
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Crypto App',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.deepPurple,
          scaffoldBackgroundColor: Colors.grey[100],
        ),
        home: initialPage,
      ),
    );
  }
}

// ---------------- MAIN PAGE ----------------

class MainPage extends StatefulWidget {
  const MainPage({super.key});
  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  Map<String, dynamic> _userData = {"slug": "Khách", "email": ""};
  int _userId = 0;
  bool _loading = true;

  final List<Widget?> _pageCache = List<Widget?>.filled(4, null);
  late final AnimationController _fabController;
  late final Animation<double> _fabAnimation;

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  @override
  void initState() {
    super.initState();

    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fabAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeInOut),
    );

    _bootstrap();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openPendingInvite();
      _openPendingCall();
    });
  }

  @override
  void dispose() {
    _fabController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    Map<String, dynamic> userData = {"slug": "Khách", "email": ""};
    int userId = 0;

    try {
      final jsonString = await StorageHelper.read("user_data");
      final userIdString = await StorageHelper.read("user_id");

      if (jsonString != null && jsonString.isNotEmpty) {
        try {
          final decoded = jsonDecode(jsonString);
          if (decoded is Map<String, dynamic>) userData = decoded;
        } catch (e) {
          debugPrint("Lỗi parse user_data: $e");
        }
      }

      userId = int.tryParse(userIdString ?? '') ?? 0;
    } catch (e) {
      debugPrint("Lỗi đọc storage: $e");
    }

    if (!mounted) return;
    setState(() {
      _userData = userData;
      _userId = userId;
      _loading = false;
      _pageCache[_selectedIndex] = _pageFor(_selectedIndex);
    });
  }

  Widget _pageFor(int index) {
    switch (index) {
      case 0:
        return const ShopPage();
      case 1:
        return MapPage(
          userId: _userId,
          username: _userData['display_name'] ?? _userData['slug'] ?? 'Khách',
          email: _userData['email'] ?? '',
        );
      case 2:
        return const GroupPage();
      case 3:
        return const ProfilePage();
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _openPendingInvite() async {
    if (pendingKeoId == null) return;
    final id = pendingKeoId!;
    pendingKeoId = null;
    await Future.delayed(const Duration(milliseconds: 500));
    openInviteById(id);
  }

  /// Xử lý cuộc gọi đến khi app vừa mở từ terminated state.
  Future<void> _openPendingCall() async {
    if (_pendingCallData == null) return;
    final data = _pendingCallData!;
    _pendingCallData = null;
    await Future.delayed(const Duration(seconds: 1));
    GlobalCallService.instance.handleFcmCall(data);
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      _pageCache[index] ??= _pageFor(index);
    });
  }

  Widget _navItem(IconData icon, String label, int index) {
    final isSelected = _selectedIndex == index;
    return GestureDetector(
      onTap: () => _onItemTapped(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isSelected ? accentOrange : Colors.grey[700]),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? accentOrange : Colors.grey[700],
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              primaryBlue.withOpacity(0.1),
              accentOrange.withOpacity(0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: _loading
            ? const Center(
          child: CircularProgressIndicator(color: Color(0xFFFF7F50)),
        )
            : IndexedStack(
          index: _selectedIndex,
          children: List<Widget>.generate(
            _pageCache.length,
                (i) => _pageCache[i] ?? const SizedBox.shrink(),
          ),
        ),
      ),
      floatingActionButton: MouseRegion(
        onEnter: (_) => _fabController.forward(),
        onExit: (_) => _fabController.reverse(),
        child: AnimatedBuilder(
          animation: _fabAnimation,
          builder: (context, child) => Transform.scale(
            scale: _fabAnimation.value,
            child: FloatingActionButton(
              backgroundColor: accentOrange,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateInvitePage()),
                );
              },
              child: const Icon(Icons.add, size: 36, color: Colors.white),
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        color: Colors.transparent,
        elevation: 0,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                primaryBlue.withOpacity(0.2),
                accentOrange.withOpacity(0.1),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(Icons.group, "Lời mời", 0),
              _navItem(Icons.map_outlined, "Bản đồ", 1),
              const SizedBox(width: 40),
              _navItem(Icons.article_outlined, "Quán", 2),
              _navItem(Icons.account_circle_outlined, "Hồ sơ", 3),
            ],
          ),
        ),
      ),
    );
  }
}