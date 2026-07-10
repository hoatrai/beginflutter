import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';
import '../helpers/storage_helper.dart';



// ------------------- Helper định dạng giờ Việt (+7) -------------------
String formatVietnamTime(String? utcTime) {
  if (utcTime == null || utcTime.isEmpty) return '';
  try {
    final dt = DateTime.parse(utcTime).toUtc().add(const Duration(hours: 7));
    return DateFormat('HH:mm dd/MM').format(dt);
  } catch (_) {
    return '';
  }
}

class UserInfoPage extends StatefulWidget {
  final int userId; // Người đang login
  final String username;
  final String? avatarUrl;
  final int targetUserId; // Người mà bạn đang xem profile / comment

  const UserInfoPage({
    super.key,
    required this.userId,
    required this.username,
    required this.targetUserId,
    this.avatarUrl,
  });

  @override
  State<UserInfoPage> createState() => _UserInfoPageState();
}

class _UserInfoPageState extends State<UserInfoPage> {
  double userRating = 0.0; // Rating người đang đánh giá
  List<Map<String, dynamic>> comments = [];
  Map<String, dynamic>? userStats;
  final TextEditingController commentController = TextEditingController();
  bool loadingComments = true;
  bool isSubmitting = false;
  bool get isSelfProfile => widget.userId == widget.targetUserId;

  final String baseUrl = "${AppConfig.webDomain}/wp-json/custom/v1";

  @override
  void initState() {
    super.initState();
    _fetchComments();
    _fetchUserStats(); // THÊM DÒNG NÀY
  }

  Widget _buildShimmerComment() {
    return shimmer.Shimmer.fromColors(
      baseColor: Colors.white.withOpacity(0.15),
      highlightColor: Colors.white.withOpacity(0.35),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 12, width: 120, color: Colors.white),
            const SizedBox(height: 8),
            Container(height: 10, width: double.infinity, color: Colors.white),
            const SizedBox(height: 6),
            Container(height: 10, width: 180, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchUserStats() async {
    try {
      final res = await http.get(
        Uri.parse(
          '${AppConfig.webDomain}/wp-json/nhau/v1/user-stats/${widget.targetUserId}',
        ),
      );

      final data = jsonDecode(res.body);

      if (data['success'] == true) {
        setState(() {
          userStats = data['stats'];
        });
      }
    } catch (e) {
      print(e);
    }
  }


  // ------------------- Fetch comment của target user -------------------
  Future<void> _fetchComments() async {
    setState(() => loadingComments = true);
    try {
      final url = Uri.parse('$baseUrl/comments/${widget.targetUserId}');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          comments = List<Map<String, dynamic>>.from(data['comments'] ?? []);
        });
      } else {
        debugPrint('Failed to fetch comments: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error fetching comments: $e');
    } finally {
      setState(() => loadingComments = false);
    }
  }

  // ------------------- Thêm comment mới -------------------
  Future<void> _addComment() async {
    if (isSubmitting) return;

    final text = commentController.text.trim();
    if (text.isEmpty) return;

    // 🚀 Bắt buộc chọn sao trước khi gửi — trước đây userRating mặc định
    // 0.0, người dùng quên chạm sao vẫn lưu thành review 0 sao, kéo tụt
    // trung bình của người được đánh giá một cách không cố ý.
    if (userRating <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Vui lòng chọn số sao đánh giá trước khi gửi")),
      );
      return;
    }

    setState(() => isSubmitting = true);

    final payload = {
      'user_id': widget.userId,
      'target_user_id': widget.targetUserId,
      'username': widget.username,
      'avatar_url': widget.avatarUrl,
      'comment': text,
      'rating': userRating,
    };

    try {
      final url = Uri.parse('$baseUrl/comments/add');
      // 🚀 Gửi kèm JWT để backend xác thực đúng người đang đăng nhập,
      // thay vì chỉ tin user_id do client tự khai trong body.
      final token = await StorageHelper.read("jwt_token") ?? "";

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: json.encode(payload),
      );

      if (response.statusCode == 200) {
        commentController.clear();
        setState(() => userRating = 0.0);
        await _fetchComments();
      } else {
        debugPrint('Error adding comment: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error adding comment: $e');
    } finally {
      setState(() => isSubmitting = false);
    }
  }

  // ------------------- Widget chọn rating -------------------
  Widget _buildRatingStars({double rating = 0.0, void Function(double)? onTap}) {
    return Row(
      children: List.generate(5, (index) {
        final isActive = index < rating;

        return GestureDetector(
          onTap: onTap != null ? () => onTap(index + 1.0) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(right: 2),
            child: Icon(
              isActive ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 18,
              color: isActive
                  ? const Color(0xFFFFC107) // vàng chuẩn
                  : Colors.white24,
            ),
          ),
        );
      }),
    );
  }
  Widget _buildMiniStat({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  // ------------------- Tính trung bình rating từ tất cả comment -------------------
  double get averageRating {
    if (comments.isEmpty) return 0.0;
    double total = 0;
    for (var c in comments) {
      total += double.tryParse(c['rating']?.toString() ?? '0') ?? 0;
    }
    return total / comments.length;
  }

  @override
  Widget build(BuildContext context) {
    const Color primaryBlue = Color(0xFF1E3A8A);
    const Color accentOrange = Color(0xFFFF7F50);

    return Scaffold(
      resizeToAvoidBottomInset: true,
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
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
                child: Row(
                  children: [
                    GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Icon(Icons.arrow_back, color: Colors.white)),
                    const SizedBox(width: 10),
                    ShaderMask(
                      shaderCallback: (bounds) =>
                          const LinearGradient(colors: [Colors.orange, Colors.red])
                              .createShader(bounds),
                      child: Text(
                        widget.username,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.person, color: Colors.white, size: 26),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              // User Info Card
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                elevation: 6,
                color: Colors.white.withOpacity(0.2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0), // giảm padding
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min, // giảm chiếm không gian dọc
                          children: [
                            /* Text(
                              widget.username,
                              style: const TextStyle(
                                fontSize: 28,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),*/
                            const SizedBox(height: 1), // giảm khoảng cách
                            Row(
                              children: [
                                _buildRatingStars(rating: averageRating),
                                const SizedBox(width: 8),
                                Text(
                                  "${averageRating.toStringAsFixed(1)} / 5.0",
                                  style: const TextStyle(color: Colors.white, fontSize: 20),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.08),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [

                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          "${userStats?['total_keo'] ?? 0}",
                                          style: const TextStyle(
                                            color: Colors.orangeAccent,
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        const Text(
                                          "Kèo tổ chức",
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  Container(
                                    width: 1,
                                    height: 35,
                                    color: Colors.white.withOpacity(0.15),
                                  ),

                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          "${userStats?['real_join_percent'] ?? 0}%",
                                          style: const TextStyle(
                                            color: Colors.greenAccent,
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        const Text(
                                          "Xác nhận",
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  Container(
                                    width: 1,
                                    height: 35,
                                    color: Colors.white.withOpacity(0.15),
                                  ),

                                  Expanded(
                                    child: Column(
                                      children: [
                                        Text(
                                          "${userStats?['joined_users'] ?? 0}",
                                          style: const TextStyle(
                                            color: Colors.lightBlueAccent,
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        const Text(
                                          "Tham gia",
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),

                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.08),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [

                                  const Row(
                                    children: [
                                      Icon(
                                        Icons.local_activity,
                                        color: Colors.orangeAccent,
                                        size: 16,
                                      ),
                                      SizedBox(width: 6),
                                      Text(
                                        "Hoạt động tham gia",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 12),

                                  Row(
                                    children: [

                                      Expanded(
                                        child: _buildMiniStat(
                                          icon: Icons.sports_bar,
                                          value: "${userStats?['joined_keo'] ?? 0}",
                                          label: "Kèo tham gia",
                                          color: Colors.orangeAccent,
                                        ),
                                      ),

                                      const SizedBox(width: 8),

                                      Expanded(
                                        child: _buildMiniStat(
                                          icon: Icons.check_circle,
                                          value: "${userStats?['attendance_count'] ?? 0}",
                                          label: "Có mặt",
                                          color: Colors.greenAccent,
                                        ),
                                      ),

                                      const SizedBox(width: 8),

                                      Expanded(
                                        child: _buildMiniStat(
                                          icon: Icons.trending_up,
                                          value: "${userStats?['attendance_percent'] ?? 0}%",
                                          label: "Uy tín",
                                          color: Colors.lightBlueAccent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),

                      Column(
                        children: [

                          const SizedBox(height: 6),

                          Hero(
                            tag: 'avatar_${widget.userId}',
                            child: GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => AvatarFullscreenPage(
                                      imageUrl: widget.avatarUrl,
                                      username: widget.username,
                                      tag: 'avatar_${widget.userId}',
                                    ),
                                  ),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    colors: [
                                      Colors.orange,
                                      Colors.deepOrange,
                                      Colors.redAccent,
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.orange.withOpacity(0.25),
                                      blurRadius: 14,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: CircleAvatar(
                                  radius: 52,
                                  backgroundColor: const Color(0xFF1E293B),
                                  backgroundImage:
                                  (widget.avatarUrl != null &&
                                      widget.avatarUrl!.isNotEmpty)
                                      ? NetworkImage(widget.avatarUrl!)
                                      : null,
                                  child: (widget.avatarUrl == null ||
                                      widget.avatarUrl!.isEmpty)
                                      ? Text(
                                    widget.username[0].toUpperCase(),
                                    style: const TextStyle(
                                      fontSize: 34,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  )
                                      : null,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 8),

                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.greenAccent.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.greenAccent.withOpacity(0.3),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.verified,
                                  size: 12,
                                  color: Colors.greenAccent,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  "Active",
                                  style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Bình luận + rating + gửi
              Flexible(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(12.0),
                        child: Text(
                          "Bình luận & đánh giá",
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      Expanded(
                        child: loadingComments
                            ? ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          itemCount: 5, // số skeleton
                          itemBuilder: (_, __) => _buildShimmerComment(),
                        )
                            : comments.isEmpty
                            ? const Center(
                          child: Text(
                            "Chưa có bình luận nào",
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                            : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          itemCount: comments.length,
                          itemBuilder: (_, i) {
                            final c = comments[i];
                            final commentRating =
                                double.tryParse(c['rating']?.toString() ?? '0') ?? 0;
                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        c['username']?.toString() ?? 'Người dùng',
                                        style: const TextStyle(
                                          fontFamily: 'Roboto',
                                          color: Colors.orangeAccent,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      _buildRatingStars(rating: commentRating),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    c['comment']?.toString() ?? '',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    formatVietnamTime(c['created_at']?.toString()),
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white54),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      // Widget chọn rating + textfield + gửi
                      isSelfProfile
                          ? Container(
                        padding: const EdgeInsets.all(12),
                        child: const Text(
                          "Bạn không thể đánh giá chính mình",
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                          : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Colors.white.withOpacity(0.2)),
                          ),
                        ),
                        child: Column(
                          children: [
                            _buildRatingStars(
                              rating: userRating,
                              onTap: (v) => setState(() => userRating = v),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: commentController,
                                    style: const TextStyle(color: Colors.white),
                                    decoration: const InputDecoration(
                                      hintText: "Viết bình luận...",
                                      hintStyle: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 14,
                                      ),
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: isSubmitting ? null : _addComment,
                                  child: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: isSubmitting
                                            ? [Colors.grey, Colors.grey]
                                            : [Colors.orange, Colors.red],
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: isSubmitting
                                        ? const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                        : const Icon(
                                      Icons.send,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class AvatarFullscreenPage extends StatelessWidget {
  final String? imageUrl;
  final String username;
  final String tag;

  const AvatarFullscreenPage({
    super.key,
    required this.imageUrl,
    required this.username,
    required this.tag,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: Hero(
            tag: tag,
            child: imageUrl != null && imageUrl!.isNotEmpty
                ? Image.network(
              imageUrl!,
              fit: BoxFit.contain,
            )
                : CircleAvatar(
              radius: 120,
              backgroundColor: Colors.orangeAccent,
              child: Text(
                username[0].toUpperCase(),
                style: const TextStyle(fontSize: 60, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}