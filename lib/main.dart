import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // 🔹 Bắt buộc nếu muốn dùng jsonDecode

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';


// Import pages
import 'pages/login_page.dart';
import 'pages/profile_page.dart';
import 'pages/market_page.dart';
import 'pages/blog_page.dart';
import 'pages/shop_page.dart';
import 'pages/flutter_map.dart';

// 🔹 Firebase background handler
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('Background message received: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await setupFirebaseMessaging();

  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('jwt_token');

  runApp(CryptoApp(
    initialPage: token == null ? const LoginPage() : const MainPage(),
  ));
}

// 🔹 Firebase Messaging setup
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

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('Foreground: ${message.notification?.title} - ${message.notification?.body}');
  });

  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    print('Clicked: ${message.notification?.title}');
  });
}

// 🔹 App root
class CryptoApp extends StatelessWidget {
  final Widget initialPage;
  const CryptoApp({super.key, required this.initialPage});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crypto App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: initialPage,
    );
  }
}

// 🔹 MainPage với BottomNavigationBar
class MainPage extends StatefulWidget {
  const MainPage({super.key});
  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _selectedIndex = 0;
  Map<String, dynamic>? _userData;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('user_data');

    if (userJson != null && userJson.isNotEmpty) {
      try {
        final data = jsonDecode(userJson); // decode
        if (data is Map<String, dynamic>) {
          setState(() {
            _userData = data;
            _loading = false;
          });
        } else {
          debugPrint("Data không phải Map: $data");
          setState(() {
            _loading = false;
          });
        }
      } catch (e) {
        debugPrint("Lỗi decode JSON: $e");
        setState(() {
          _loading = false;
        });
      }
    } else {
      debugPrint("userJson null hoặc rỗng");
      setState(() {
        _loading = false;
      });
    }
  }


  List<Widget> _pages() {
    return [
      const MarketPage(),
      const BlogPage(),
      const ShopPage(),
      const ProfilePage(),
      (_userData != null)
          ? MapPage(
        username: _userData!['slug'] ?? 'Visitor',
        email: _userData!['email'] ?? '',
      )
          : const Center(child: CircularProgressIndicator()), // loading Map
    ];
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages(),
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        backgroundColor: Colors.white,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: "Market"),
          BottomNavigationBarItem(icon: Icon(Icons.article), label: "Blog"),
          BottomNavigationBarItem(icon: Icon(Icons.shopping_cart), label: "Shop"),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: "Profile"),
          BottomNavigationBarItem(icon: Icon(Icons.home), label: "Map"),
        ],
      ),
    );
  }
}
