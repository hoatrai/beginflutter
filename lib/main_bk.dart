import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

// 👉 Firebase
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'pages/shop_page.dart';

// 🔹 Xử lý notification khi app background/terminated
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('Background message received: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Khởi tạo Firebase
  await Firebase.initializeApp();

  // Background handler
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Setup notification
  await setupFirebaseMessaging();

  runApp(const CryptoApp());
}

// 🔹 Hàm setup Firebase Messaging
Future<void> setupFirebaseMessaging() async {
  FirebaseMessaging messaging = FirebaseMessaging.instance;

  // Yêu cầu quyền notification (iOS & Android 13+)
  NotificationSettings settings = await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  print('User granted permission: ${settings.authorizationStatus}');

  // Lấy token device
  String? token = await messaging.getToken();
  print("Firebase Messaging Token: $token");

  // 🔹 Subscribe topic để nhận notification từ Phoenix
  await messaging.subscribeToTopic("all_devices");

  // Khi app foreground nhận notification
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    print('Foreground message: ${message.notification?.title} - ${message.notification?.body}');
  });

  // Khi app mở từ notification
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    print('Notification clicked: ${message.notification?.title}');
  });
}

// 🔹 App chính
class CryptoApp extends StatelessWidget {
  const CryptoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crypto App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: const MainPage(),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _selectedIndex = 0;

  final List<Widget> _pages = [
    const MarketPage(),
    const PortfolioPage(),
    const ProfilePage(),
    const BlogPage(),
    const ShopPage(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.blue,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white70,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart),
            label: "Market",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet),
            label: "Portfolio",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: "Profile",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.article),
            label: "Blog",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shopping_cart),
            label: "Shop",
          ),
        ],
      ),
    );
  }
}

// ---------------------- Các trang ----------------------

class MarketPage extends StatelessWidget {
  const MarketPage({super.key});

  final List<Map<String, dynamic>> coins = const [
    {"name": "Bitcoin", "symbol": "BTC", "price": "65,200", "change": "+2.3%"},
    {"name": "Ethereum", "symbol": "ETH", "price": "3,200", "change": "-1.1%"},
    {"name": "Binance Coin", "symbol": "BNB", "price": "450", "change": "+0.8%"},
    {"name": "Solana", "symbol": "SOL", "price": "150", "change": "+5.4%"},
    {"name": "Ripple", "symbol": "XRP", "price": "0.52", "change": "-0.6%"},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Crypto Market", style: TextStyle(color: Colors.white)),
        centerTitle: true,
        backgroundColor: Colors.blue,
      ),
      body: ListView.builder(
        itemCount: coins.length,
        padding: const EdgeInsets.all(12),
        itemBuilder: (context, index) {
          final coin = coins[index];
          final bool isPositive = coin["change"].toString().contains("+");

          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(vertical: 8),
            elevation: 4,
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: Colors.blue.shade100,
                child: Text(coin["symbol"], style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              title: Text(coin["name"], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: Text("Price: \$${coin["price"]}"),
              trailing: Text(
                coin["change"],
                style: TextStyle(
                  color: isPositive ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => CoinDetailPage(coin: coin)),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class CoinDetailPage extends StatelessWidget {
  final Map<String, dynamic> coin;
  const CoinDetailPage({super.key, required this.coin});

  @override
  Widget build(BuildContext context) {
    final bool isPositive = coin["change"].toString().contains("+");
    return Scaffold(
      appBar: AppBar(title: Text("${coin["name"]} Details"), backgroundColor: Colors.blue),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(coin["name"], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Text("Symbol: ${coin["symbol"]}"),
                const SizedBox(height: 10),
                Text("Current Price: \$${coin["price"]}", style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 10),
                Text(
                  "Change: ${coin["change"]}",
                  style: TextStyle(color: isPositive ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                const Text(
                  "This is a demo description about the coin. In a real app, you can fetch live data from an API like CoinGecko.",
                  style: TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PortfolioPage extends StatelessWidget {
  const PortfolioPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Danh mục", style: TextStyle(color: Colors.white)), backgroundColor: Colors.blue),
      body: const Center(child: Text("Your portfolio will be displayed here.", style: TextStyle(fontSize: 16))),
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Profile", style: TextStyle(color: Colors.white)), backgroundColor: Colors.blue),
      body: const Center(child: Text("User Profile Page", style: TextStyle(fontSize: 16))),
    );
  }
}

class BlogPage extends StatefulWidget {
  const BlogPage({super.key});
  @override
  State<BlogPage> createState() => _BlogPageState();
}

class _BlogPageState extends State<BlogPage> {
  List posts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    fetchPosts();
  }

  Future<void> fetchPosts() async {
    final url = Uri.parse("https://spiritwebs.com/wp-json/wp/v2/posts");
    final response = await http.get(url);
    if (response.statusCode == 200) {
      setState(() {
        posts = json.decode(response.body);
        loading = false;
      });
    } else {
      setState(() {
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Blog Crypto", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Colors.blue),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: fetchPosts,
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          itemCount: posts.length,
          itemBuilder: (context, index) {
            final post = posts[index];
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                title: Text(post["title"]["rendered"], style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text("ID: ${post["id"]}"),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => BlogDetailPage(post: post)));
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class BlogDetailPage extends StatelessWidget {
  final Map post;
  const BlogDetailPage({super.key, required this.post});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(post["title"]["rendered"], style: const TextStyle(color: Colors.white)), backgroundColor: Colors.blue),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Html(
          data: post["content"]["rendered"],
          style: {
            "body": Style(fontSize: FontSize(16), color: Colors.black87),
          },
        ),
      ),
    );
  }
}
