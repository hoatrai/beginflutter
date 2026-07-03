import 'helpers/lifecycle_tracker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:ui';

import 'pages/login_page.dart';
import 'pages/profile_page.dart';
import 'pages/market_page.dart';
import 'pages/blog_page.dart';
import 'pages/shop_page.dart';
import 'pages/flutter_map.dart';
import 'pages/group_page.dart';
import 'pages/create_invite_page.dart';
import 'helpers/storage_helper.dart';
import 'pages/splash_page.dart';
import 'pages/product_detail_page.dart';
import 'pages/chat_page.dart';
import 'pages/notification_store.dart';
import 'pages/notification_page.dart';



// 🔹 Firebase background handler
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('Background message received: ${message.messageId}');
}

final GlobalKey<NavigatorState> navigatorKey =
GlobalKey<NavigatorState>();

final ValueNotifier<int> unreadNotiVN = ValueNotifier<int>(0);

String? pendingKeoId;
OverlayEntry? _appNotificationOverlay;
bool isChatPageOpen = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await setupFirebaseMessaging();

  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('jwt_token');

  runApp(const CryptoApp(
    initialPage: SplashPage(),
  ));

 /* runApp(CryptoApp(
    initialPage: token == null ? const LoginPage() : const MainPage(),
  ));*/
}
Future<Map?> fetchMe() async {
  final token = await StorageHelper.read("jwt_token");

  final res = await http.get(
    Uri.parse("https://spiritwebs.com/wp-json/spiritwebs/v1/me"),
    headers: {
      "Authorization": "Bearer $token",
    },
  );

  if (res.statusCode != 200) return null;
  return jsonDecode(res.body);
}
void showAppNotification({
  required String title,
  required String body,
}) {
  final overlay = navigatorKey.currentState?.overlay;
  if (overlay == null) return;

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

  Future.delayed(const Duration(seconds: 3), () {
    _appNotificationOverlay?.remove();
    _appNotificationOverlay = null;
  });
}

Future<void> setupFirebaseMessaging() async {
  FirebaseMessaging messaging = FirebaseMessaging.instance;

  NotificationSettings settings = await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  print('User granted permission: ${settings.authorizationStatus}');

  String? token = await messaging.getToken();
  print("Firebase Messaging Token: $token");

  await messaging.subscribeToTopic("all_devices");

 /* FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('Foreground: ${message.notification?.title} - ${message.notification?.body}');
  });*/
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final title = message.notification?.title ?? "Thông báo";
    final body = message.notification?.body ?? "";

    NotificationStore.add(
      title: title,
      body: body,
      type: message.data['type'],
      data: message.data,
    );

    unreadNotiVN.value++;

    showAppNotification(
      title: title,
      body: body,
    );
  });


  /*FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    print('Clicked: ${message.notification?.title}');
  });*/
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    print('Clicked: ${message.notification?.title}');

    final type = message.data['type'];

    if (type == 'invite_keo') {
      openInviteFromNotification(message);
    }

    if (type == 'chat_message') {
      openChatFromNotification(message);
    }
  });


  RemoteMessage? initialMessage =
  await FirebaseMessaging.instance.getInitialMessage();

  if (initialMessage != null) {

    if (initialMessage.data['type'] == 'invite_keo') {
      pendingKeoId = initialMessage.data['keo_id'];
    }

    if (initialMessage.data['type'] == 'chat_message') {

      Future.delayed(
        const Duration(seconds: 1),
            () => openChatFromNotification(initialMessage),
      );
    }
  }

}

Future<void> openChatFromNotification(
    RemoteMessage message) async {

  try {

    final senderId =
        int.tryParse(message.data['sender_id'] ?? '0') ?? 0;

    final senderName =
        message.data['sender_username'] ?? 'Người dùng';

    final me = await fetchMe();

    if (me == null) return;

    final myId =
        int.tryParse(me['id'].toString()) ?? 0;

    final myUsername =
        me['username'] ?? '';

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

Future<void> openInviteFromNotification(
    RemoteMessage message) async {

  final keoId = message.data['keo_id'];

  if (keoId == null) return;

  try {
    final res = await http.get(
      Uri.parse(
        "https://spiritwebs.com/wp-json/wc/v3/products/$keoId"
            "?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
            "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
      ),
    );

    if (res.statusCode != 200) return;

    final product =
    jsonDecode(res.body) as Map<String, dynamic>;

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => ProductDetailPage(
          product: product,
        ),
      ),
    );
  } catch (e) {
    debugPrint("Open invite error: $e");
  }
}

Future<void> openInviteById(String keoId) async {
  try {
    final res = await http.get(
      Uri.parse(
        "https://spiritwebs.com/wp-json/wc/v3/products/$keoId"
            "?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
            "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
      ),
    );

    if (res.statusCode != 200) return;

    final product =
    jsonDecode(res.body) as Map<String, dynamic>;

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => ProductDetailPage(
          product: product,
        ),
      ),
    );
  } catch (e) {
    debugPrint("Open invite error: $e");
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

        // TODO: gửi socket ở đây nếu muốn
        // sendAppStateToServer(state);
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

class _MainPageState extends State<MainPage> with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  Map<String, dynamic>? _userData;
  bool _loading = true;
  late final List<Widget> _pages;


  late final AnimationController _fabController;
  late final Animation<double> _fabAnimation;

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  @override
  void initState() {
    super.initState();
    _loadUserData();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openPendingInvite();
    });
    _pages = [
      const ShopPage(),
      const SizedBox(), // placeholder cho MapPage
      const NotificationPage(), // 👈 THÊM VÀO ĐÂY
      const GroupPage(),
      const ProfilePage(),
    ];

    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fabAnimation = Tween<double>(begin: 1.0, end: 1.2)
        .animate(CurvedAnimation(parent: _fabController, curve: Curves.easeInOut));
  }

  Widget _buildMapPageWrapper() {
    return FutureBuilder<String?>(
      future: StorageHelper.read("user_id"),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFFF7F50)),
          );
        }

        final userId = snapshot.data ?? "guest";
        final userIdInt = int.tryParse(userId) ?? 0;

        return MapPage(
          userId: userIdInt,
          username: _userData?['display_name'] ?? 'hung8',
          email: _userData?['email'] ?? '',
        );
      },
    );
  }

  Future<void> _loadUserData() async {
    setState(() => _loading = true);

    final jsonString = await StorageHelper.read("user_data");

    if (jsonString != null && jsonString.isNotEmpty) {
      try {
        final data = jsonDecode(jsonString);
        if (data is Map<String, dynamic>) {
          setState(() {
            _userData = data;
            _loading = false;
          });
        } else {
          setState(() {
            _userData = {"slug": "Visitor", "email": ""};
            _loading = false;
          });
        }
      } catch (e) {
        setState(() {
          _userData = {"slug": "Visitor", "email": ""};
          _loading = false;
        });
      }
    } else {
      setState(() {
        _userData = {"slug": "Visitor", "email": ""};
        _loading = false;
      });
    }
  }

  Future<void> _openPendingInvite() async {
    if (pendingKeoId == null) return;

    final id = pendingKeoId!;

    pendingKeoId = null;

    await Future.delayed(
      const Duration(milliseconds: 500),
    );

    openInviteById(id);
  }



  /*Widget _buildCurrentPage() {
    switch (_selectedIndex) {
      case 0:
        return const ShopPage();
      case 1:
        if (_loading) return const Center(child: CircularProgressIndicator(color: Color(0xFFFF7F50)));
        if (_userData == null) return const Center(child: Text("Không có dữ liệu user"));

        return FutureBuilder<String?>(
          future: StorageHelper.read("user_id"),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator(color: Color(0xFFFF7F50)));
            }
            final userId = snapshot.data ?? "guest";
            final userIdInt = int.tryParse(userId) ?? 0;
            return MapPage(
              userId: userIdInt,
              username: _userData!['display_name'] ?? 'hung8',
              email: _userData!['email'] ?? '',
            );
          },
        );
      case 2:
        return const GroupPage();
      case 3:
        return const ProfilePage();
      default:
        return const SizedBox.shrink();
    }
  }*/

  /*void _onItemTapped(int index) {
    if (index == 1 && _pages[1] is SizedBox) {
      _pages[1] = _buildMapPageWrapper(); // lazy load MapPage
    }

    setState(() {
      _selectedIndex = index;
    });
  }*/
  Widget _buildCurrentPage() {
    switch (_selectedIndex) {
      case 0:
        return const ShopPage();

      case 1:
        if (_loading) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFFF7F50)),
          );
        }

        return FutureBuilder<String?>(
          future: StorageHelper.read("user_id"),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(color: Color(0xFFFF7F50)),
              );
            }

            final userId = snapshot.data ?? "0";
            final userIdInt = int.tryParse(userId) ?? 0;

            return MapPage(
              userId: userIdInt,
              username: _userData?['display_name'] ?? 'hung8',
              email: _userData?['email'] ?? '',
            );
          },
        );

      case 2:
        return const NotificationPage(); // 👈 THÊM ĐÚNG Ở ĐÂY

      case 3:
        return const GroupPage();

      case 4:
        return const ProfilePage();

      default:
        return const SizedBox();
    }
  }
  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;

      // nếu vào tab Thông báo (index = 2)
      if (index == 2) {
        unreadNotiVN.value = 0;
      }
    });
  }


  Widget _navItem(IconData icon, String label, int index) {
    final isSelected = _selectedIndex == index;

    return GestureDetector(
      onTap: () {
        _onItemTapped(index);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                icon,
                color: isSelected ? accentOrange : Colors.grey[700],
              ),

              // 🔥 BADGE ĐÚNG CHỖ
              if (label == "Thông báo")
                ValueListenableBuilder<int>(
                  valueListenable: unreadNotiVN,
                  builder: (context, value, _) {
                    if (value == 0) return const SizedBox();

                    return Positioned(
                      right: -6,
                      top: -6,
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
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),

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
      extendBody: true, // 🔹 gradient chạy dưới BottomAppBar
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue.withOpacity(0.1), accentOrange.withOpacity(0.05)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: _buildCurrentPage(), // 🔥 THAY Ở ĐÂY
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
              colors: [primaryBlue.withOpacity(0.2), accentOrange.withOpacity(0.1)],
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
              _navItem(Icons.notifications, "Thông báo", 2),
              _navItem(Icons.article_outlined, "Quán", 3),
              _navItem(Icons.account_circle_outlined, "Hồ sơ", 4),
            ],
          ),
        ),
      ),
    );
  }
}
