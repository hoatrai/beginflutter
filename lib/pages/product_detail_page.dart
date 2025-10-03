import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_html/flutter_html.dart';
import 'shop_page.dart';

class ProductDetailPage extends StatelessWidget {
  final Map<String, dynamic> product;
  const ProductDetailPage({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(product["name"]?.toString() ?? "Sản phẩm"),
        backgroundColor: Colors.blue,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hình ảnh sản phẩm
                    if (product["images"] != null &&
                        product["images"] is List &&
                        product["images"].isNotEmpty)
                      SizedBox(
                        height: 250,
                        child: PageView.builder(
                          itemCount: product["images"].length,
                          itemBuilder: (context, index) {
                            final img = product["images"][index];
                            String imgUrl = "";
                            if (img is Map && img.containsKey("src")) {
                              imgUrl = img["src"];
                            } else if (img is String) {
                              imgUrl = img;
                            }
                            return CachedNetworkImage(
                              imageUrl: imgUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              placeholder: (context, url) =>
                              const Center(child: CircularProgressIndicator()),
                              errorWidget: (context, url, error) =>
                              const Icon(Icons.error),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 16),

                    // Tên sản phẩm
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        product["name"]?.toString() ?? "Không có tên",
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Giá sản phẩm
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        "${product["price"]?.toString() ?? "0"} ${product["currency"] ?? "USD"}",
                        style: const TextStyle(
                          fontSize: 18,
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Mô tả sản phẩm (HTML)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: product["description"] != null
                          ? Html(data: product["description"].toString())
                          : const Text("Chưa có mô tả",
                          style: TextStyle(fontSize: 16)),
                    ),
                    const SizedBox(height: 80), // tạo khoảng trống cho nút
                  ],
                ),
              ),
            ),

            // Nút thêm vào giỏ cố định dưới màn hình
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    cartItems.add(Map<String, dynamic>.from(product));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Đã thêm vào giỏ hàng!")),
                    );
                  },
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text("Thêm vào giỏ", style: TextStyle(fontSize: 18)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: Colors.blue,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
