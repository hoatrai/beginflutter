import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

import 'cart_page.dart';
import 'product_detail_page.dart';

// =========================
// Giỏ hàng toàn cục
// =========================
List<Map<String, dynamic>> cartItems = [];

class ShopPage extends StatefulWidget {
  const ShopPage({super.key});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> {
  List<Map<String, dynamic>> products = [];
  bool loading = true;
  int page = 1;
  bool hasMore = true;

  late WebSocketChannel channel;

  @override
  void initState() {
    super.initState();
    fetchProducts(); // Load sản phẩm hiện tại từ WooCommerce
    connectSocket(); // Kết nối WebSocket Phoenix
  }

  @override
  void dispose() {
    channel.sink.close(status.goingAway);
    super.dispose();
  }

  // -----------------------------
  // Load sản phẩm từ WooCommerce
  // -----------------------------
  Future<void> fetchProducts() async {
    if (!hasMore) return;

    final url = Uri.parse(
      "https://spiritwebs.com/wp-json/wc/v3/products"
          "?status=publish&per_page=10&page=$page"
          "&orderby=date&order=desc"
          "&consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
          "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
    );

    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List newProducts = json.decode(response.body);

      setState(() {
        for (var p in newProducts) {
          final productMap = Map<String, dynamic>.from(p);
          // tránh trùng
          if (!products.any((e) => e["id"] == productMap["id"])) {
            products.add(productMap);
          }
        }

        loading = false;
        if (newProducts.length < 10) {
          hasMore = false;
        } else {
          page++;
        }
      });
    } else {
      setState(() {
        loading = false;
        hasMore = false;
      });
    }
  }

  // -----------------------------
  // Kết nối WebSocket Phoenix
  // -----------------------------
  void connectSocket() {
    channel = WebSocketChannel.connect(
      Uri.parse('wss://socket.spiritwebs.com/socket/websocket'),
    );

    channel.stream.listen((message) {
      try {
        final decoded = json.decode(message);

        // Phoenix message dạng: { "event": "new_product", "payload": {...} }
        if (decoded is Map && decoded['event'] == 'new_product') {
          final payload = decoded['payload'];
          if (payload is Map) {
            final productMap = Map<String, dynamic>.from(payload);

            // Chuẩn hóa images về List<Map<String,String>> với key 'src'
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

            setState(() {
              if (!products.any((e) => e["id"] == productMap["id"])) {
                products.insert(0, productMap); // Thêm sản phẩm mới lên đầu
              }
            });
          }
        }
      } catch (e) {
        print("WebSocket parse error: $e");
      }
    }, onError: (error) {
      print("WebSocket error: $error");
    }, onDone: () {
      print("WebSocket closed");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const Icon(Icons.shopping_cart, color: Colors.white),
        title: const Text("Sản phẩm mới", style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.blue,
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.shopping_bag),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const CartPage()),
                  ).then((_) => setState(() {}));
                },
              ),
              if (cartItems.isNotEmpty)
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
                      "${cartItems.length}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: loading && products.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (!loading &&
              hasMore &&
              scrollInfo.metrics.pixels ==
                  scrollInfo.metrics.maxScrollExtent) {
            fetchProducts();
          }
          return false;
        },
        child: ListView.builder(
          itemCount: products.length + (hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == products.length) {
              return const Padding(
                padding: EdgeInsets.all(8.0),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final product = products[index];
            return Card(
              margin: const EdgeInsets.all(8),
              child: ListTile(
                leading: product["images"] != null &&
                    product["images"] is List &&
                    product["images"].isNotEmpty
                    ? CachedNetworkImage(
                  imageUrl: product["images"][0]["src"],
                  width: 50,
                  height: 50,
                  fit: BoxFit.cover,
                )
                    : const Icon(Icons.image),
                title: Text(product["name"].toString()),
                subtitle: Text(
                    "${product["price"].toString()} ${product["currency"] ?? "USD"}"),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ProductDetailPage(
                        product: Map<String, dynamic>.from(product),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
