import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'product_detail_page.dart';
import '../helpers/storage_helper.dart';
import 'package:shimmer/shimmer.dart';
import '../config/app_config.dart';


class MyKeoPage extends StatefulWidget {
  final List products;      // ✅ GIỮ NGUYÊN
  final String myUserId;

  const MyKeoPage({
    super.key,
    required this.products,
    required this.myUserId,
  });

  @override
  State<MyKeoPage> createState() => _MyKeoPageState();
}

class _MyKeoPageState extends State<MyKeoPage> {
  bool loading = true;
  String? error;
  late List products;

  @override
  void initState() {
    super.initState();

    /// ✅ dùng data truyền vào trước
    products = widget.products is List
        ? widget.products.whereType<Map>().toList()
        : [];



    /// rồi mới gọi API
    _loadMyKeo();
  }

  Future<void> _loadMyKeo() async {
    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final res = await http.get(
        Uri.parse(
          "${AppConfig.webDomain}/wp-json/nhau/v1/my-keo?user_id=${widget.myUserId}",
        ),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
      );

      debugPrint("TOKEN = [$token]");
      debugPrint("STATUS = ${res.statusCode}");
      debugPrint("BODY = ${res.body}");

      if (res.statusCode != 200) {
        setState(() {
          products = [];
          loading = false;
        });
        return;
      }

      final data = json.decode(res.body);

      /// ❗ LUÔN ĐẢM BẢO products LÀ LIST
      if (data is! Map || data['success'] != true) {
        setState(() {
          products = [];
          loading = false;
        });
        return;
      }

      final List safeProducts = [
        ...(data['current'] is List ? data['current'] : []),
        ...(data['joining'] is List ? data['joining'] : []),
        ...(data['history'] is List ? data['history'] : []),
      ].whereType<Map>().toList(); // 🔥 DÒNG QUAN TRỌNG


      setState(() {
        products = safeProducts;
        loading = false;
      });


      debugPrint("API PRODUCTS: ${products.length}");
    } catch (e) {
      debugPrint("API ERROR: $e");
      setState(() {
        products = [];
        loading = false;
      });
    }
  }

  void _showThemedSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        padding: EdgeInsets.zero,
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              colors: isError
                  ? [Colors.red.shade900, Colors.red.shade600]
                  : [Colors.blue.shade900, Colors.orange.shade700.withOpacity(.85)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.35),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.local_bar,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _closeKeo(dynamic keoId) async {
    if (keoId == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(.6),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: [
                Colors.blue.shade900,
                Colors.orange.shade700.withOpacity(.85),
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
              const Icon(Icons.local_bar, color: Colors.orangeAccent, size: 40),
              const SizedBox(height: 12),
              const Text(
                "Đóng kèo",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "Bạn có chắc muốn đóng kèo này không?\nHành động này không thể hoàn tác.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text("Huỷ"),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        "Đóng kèo",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirm != true) return;

    try {
      final token = await StorageHelper.read("jwt_token") ?? "";

      // Endpoint thật: POST /wp-json/nhau/v1/invite/close
      // Backend lấy user_id từ JWT, chỉ cần gửi invite_id lên.
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/invite/close"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: json.encode({"invite_id": keoId}),
      );

      debugPrint("CLOSE KEO STATUS = ${res.statusCode}");
      debugPrint("CLOSE KEO BODY = ${res.body}");

      // ⚠️ Backend trả HTTP 200 ngay cả khi thất bại (vd: "Không có quyền",
      // "Invite không tồn tại"), nên phải check field 'success' trong body,
      // không chỉ dựa vào statusCode.
      Map<String, dynamic>? data;
      try {
        final decoded = json.decode(res.body);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}

      final ok = res.statusCode == 200 && data != null && data['success'] == true;

      if (ok) {
        _showThemedSnackBar("Đã đóng kèo thành công");
        setState(() => loading = true);
        await _loadMyKeo(); // refresh lại danh sách
      } else {
        final msg = data?['message']?.toString() ?? "Đóng kèo thất bại, thử lại sau";
        _showThemedSnackBar(msg, isError: true);
      }
    } catch (e) {
      debugPrint("CLOSE KEO ERROR: $e");
      _showThemedSnackBar("Có lỗi xảy ra khi đóng kèo", isError: true);
    }
  }


  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [Colors.orange, Colors.red],
            ).createShader(bounds),
            child: const Text(
              "Kèo của tôi",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          bottom: const TabBar(
            indicatorColor: Colors.orange,
            labelColor: Colors.orange,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(text: "Kèo đang mở"),
              Tab(text: "Kèo tham gia"),
              Tab(text: "Lịch sử kèo"),
            ],
          ),
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.blue.shade900.withOpacity(.9),
                Colors.orange.shade700.withOpacity(.8),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: TabBarView(
              children: [
                _buildCurrent(context),
                _buildJoining(context),
                _buildHistory(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> normalizeImages(dynamic rawImages) {
    final List<Map<String, dynamic>> result = [];

    if (rawImages is List) {
      for (final img in rawImages) {
        if (img is Map && img['src'] != null) {
          result.add({'src': img['src'].toString()});
        }
        else if (img is String && img.isNotEmpty) {
          result.add({'src': img});
        }
      }
    }
    else if (rawImages is Map) {
      if (rawImages['src'] != null) {
        result.add({'src': rawImages['src'].toString()});
      }
    }
    else if (rawImages is String && rawImages.isNotEmpty) {
      result.add({'src': rawImages});
    }

    return result;
  }


  // ================= CURRENT =================

  Widget _buildCurrent(BuildContext context) {
    if (loading) return _buildKeoShimmer(); // ✅ THÊM
    final list = products.where((p) {
      if (p is! Map) return false; // 🔥 DÒNG CỨU MẠNG
      return p['host_id'].toString() == widget.myUserId &&
          p['status'].toString().trim() == 'open';
    }).toList();


    if (list.isEmpty) return const KeoEmpty("Chưa có kèo hiện tại");
    return _buildList(context, list);
  }

  // ================= JOINING =================

  Widget _buildJoining(BuildContext context) {
    if (loading) return _buildKeoShimmer(); // ✅ THÊM
    final list = products.where((p) {
      if (p is! Map) return false; // 🔥 DÒNG CỨU MẠNG
      return p['joined'].toString() == "1" &&
          p['host_id'].toString() != widget.myUserId &&
          p['status'].toString().trim() == 'open';
    }).toList();

    if (list.isEmpty) return const KeoEmpty("Bạn chưa tham gia kèo nào");
    return _buildList(context, list);
  }

  // ================= HISTORY =================

  Widget _buildHistory(BuildContext context) {
    if (loading) return _buildKeoShimmer();

    final now = DateTime.now();

    final list = products.where((p) {
      if (p is! Map) return false;

      final status = p['status'].toString().trim();

      // ❗ nếu backend có thời gian
      final timeStr = p['end_time']?.toString(); // đổi theo API bạn
      final endTime = timeStr != null ? DateTime.tryParse(timeStr) : null;

      final isEndedByTime = endTime != null && endTime.isBefore(now);

      // 🔥 CHỈ lấy kèo đã kết thúc
      return status == 'closed' || isEndedByTime;
    }).toList();

    if (list.isEmpty) return const KeoEmpty("Lịch sử kèo trống");
    return _buildList(context, list);
  }

  // ================= COMMON LIST =================

  Widget _buildList(BuildContext context, List data) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: .72,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: data.length,
      itemBuilder: (_, i) {
        final raw = data[i];
        if (raw is! Map) return const SizedBox.shrink();
        final p = raw;

        String image = '';

        final product = p['product'];
        if (product is Map && product['images'] is List) {
          final imgs = product['images'] as List;
          if (imgs.isNotEmpty && imgs.first is Map) {
            image = imgs.first['src']?.toString() ?? '';
          }
        }

        String title = '';

        if (product is Map && product['name'] != null) {
          title = product['name'].toString();
        } else if (p['name'] != null) {
          title = p['name'].toString();
        }






        return GestureDetector(
          onTap: () {
            Map<String, dynamic> product;

            if (p['product'] is Map) {
              product = Map<String, dynamic>.from(p['product']);
            } else {
              product = {
                'id': p['product_id'],
                'name': p['name'] ?? '',
                'price': p['price'] ?? '',
                'images': normalizeImages(p['images']),
                'meta_data': [
                  {
                    'key': 'slots',
                    'value': p['slots'] ?? '0',
                  }
                ],
                'joined': p['joined'],
                'status': p['status'],
              };
            }

            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProductDetailPage(
                  product: product,
                  onJoin: (_) {},
                ),
              ),
            );
          },

          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: Colors.white.withOpacity(.12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.25),
                  blurRadius: 10,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                /// ===== IMAGE (GIỮ EXPANDED) =====
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Image.network(
                            image.isNotEmpty
                                ? image
                                : 'https://via.placeholder.com/400',
                            fit: BoxFit.cover,
                          ),
                        ),

                        // ===== STATUS BADGE =====
                        Positioned(
                          top: 8,
                          left: 8,
                          child: _buildBadge(
                            p['status'] == 'open' ? 'Đang mở' : 'Đã đóng',
                            p['status'] == 'open' ? Colors.green : Colors.red,
                          ),
                        ),

                        // ===== SLOT BADGE =====
                        if (p['slots'] != null)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _buildBadge(
                              '${p['slots']} slot',
                              Colors.black.withOpacity(.7),
                            ),
                          ),

                        // ===== NÚT ĐÓNG KÈO (đè lên góc dưới-phải ảnh,
                        // chỉ hiện với kèo của chính host, đang mở) =====
                        if (p['host_id'].toString() == widget.myUserId &&
                            p['status'].toString().trim() == 'open')
                          Positioned(
                            bottom: 8,
                            right: 8,
                            child: GestureDetector(
                              onTap: () => _closeKeo(p['id']),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade600,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  "Đóng kèo",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),


                /// ===== TITLE (FIX KHÔNG BỊ MẤT) =====
                SizedBox(
                  height: 44, // 🔥 QUAN TRỌNG
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

}
Widget _buildBadge(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

Widget _buildKeoShimmer() {
  return GridView.builder(
    padding: const EdgeInsets.all(12),
    itemCount: 6,
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      childAspectRatio: .72,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    ),
    itemBuilder: (_, __) {
      return Shimmer.fromColors(
        baseColor: Colors.white.withOpacity(.15),
        highlightColor: Colors.white.withOpacity(.35),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      );
    },
  );
}


// ================= EMPTY =================

class KeoEmpty extends StatelessWidget {
  final String title;
  const KeoEmpty(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.local_bar, size: 60, color: Colors.white38),
          const SizedBox(height: 12),
          Text(title,
              style:
              const TextStyle(color: Colors.white70, fontSize: 16)),
        ],
      ),
    );
  }
}