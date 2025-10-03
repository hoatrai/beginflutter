import 'package:flutter/material.dart';
import 'shop_page.dart';
import 'product_detail_page.dart';


class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Giỏ hàng"),
        backgroundColor: Colors.blue,
      ),
      body: cartItems.isEmpty
          ? const Center(
        child: Text(
          "Giỏ hàng trống",
          style: TextStyle(fontSize: 18),
        ),
      )
          : ListView.builder(
        itemCount: cartItems.length,
        itemBuilder: (context, index) {
          final item = cartItems[index];

          // Lấy ảnh đầu tiên chuẩn Phoenix/WooCommerce
          String imageUrl = "";
          if (item["images"] != null &&
              item["images"] is List &&
              item["images"].isNotEmpty) {
            final img = item["images"][0];
            if (img is Map && img.containsKey("src")) {
              imageUrl = img["src"];
            } else if (img is String) {
              imageUrl = img;
            }
          }

          return Card(
            margin: const EdgeInsets.all(8),
            child: ListTile(
              leading: imageUrl.isNotEmpty
                  ? Image.network(
                imageUrl,
                width: 50,
                height: 50,
                fit: BoxFit.cover,
              )
                  : const Icon(Icons.image),
              title: Text(item["name"] ?? "Không có tên"),
              subtitle: Text(
                "${item["price"] ?? "0"} ${item["currency"] ?? "USD"}",
                style: const TextStyle(color: Colors.red),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () {
                  setState(() {
                    cartItems.removeAt(index);
                  });
                },
              ),
              onTap: () {
                // Có thể thêm xem chi tiết sản phẩm nếu muốn
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        ProductDetailPage(product: item),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
