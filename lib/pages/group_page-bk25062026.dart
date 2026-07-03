import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'group_detail_page.dart';
import '../helpers/storage_helper.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import 'package:url_launcher/url_launcher.dart';
import 'near_pub.dart';


class GroupPage extends StatefulWidget {
  const GroupPage({super.key});

  @override
  State<GroupPage> createState() => _GroupPageState();
}

class _GroupPageState extends State<GroupPage> {
  List<Map<String, dynamic>> groupList = [];
  bool isLoading = true;

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;

  @override
  void initState() {
    super.initState();
    fetchGroups();
  }

  // Hàm mở Google Maps dựa theo địa chỉ


  Future<void> fetchGroups() async {
    try {
      final userId = await StorageHelper.read("user_id");

      if (userId == null) {
        setState(() => isLoading = false);
        return;
      }

      final res = await http.get(
        Uri.parse(
          '${AppConfig.webDomain}/wp-json/app/v1/groups?user_id=$userId',
        ),
      );

      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);

        if (decoded is Map && decoded['error'] != null) {
          debugPrint('GROUP API ERROR: ${decoded['error']}');
          setState(() => isLoading = false);
          return;
        }

        setState(() {
          groupList = List<Map<String, dynamic>>.from(decoded);
          isLoading = false;
        });
      } else {
        isLoading = false;
      }
    } catch (e) {
      debugPrint('FETCH GROUP ERROR: $e');
      setState(() => isLoading = false);
    }
  }

  // =====================================================
  // SKELETON
  // =====================================================
  Widget _buildSkeleton() {
    final baseColor = Colors.white.withOpacity(0.12);
    final highlightColor = Colors.white.withOpacity(0.28);

    return shimmer.Shimmer.fromColors(
      baseColor: baseColor,
      highlightColor: highlightColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),

          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            height: 22,
            width: 160,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            height: 200,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 5,
              itemBuilder: (_, __) => Container(
                width: 220,
                margin: const EdgeInsets.only(left: 16, right: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 6,
              itemBuilder: (_, __) => Container(
                height: 72,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }


  // =====================================================
  // CONTENT
  // =====================================================
  // ... giữ nguyên imports và initState

// Hàm mở Google Maps vẫn giữ nguyên
  Future<void> openGoogleMaps(String address) async {
    final Uri googleMapsUrl = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}');

    if (await canLaunchUrl(googleMapsUrl)) {
      await launchUrl(googleMapsUrl, mode: LaunchMode.externalApplication);
    } else {
      debugPrint('Could not launch Google Maps for $address');
    }
  }

// =====================================================
// CONTENT (Chỉ sửa phần hiển thị địa chỉ + icon chỉ đường)
// =====================================================
  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        // ================= TOP HEADER =================
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Quán nổi bật",
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: textWhite,
                ),
              ),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => NearPubPage(
                        userId: 1,
                        username: 'demo',
                        email: 'demo@gmail.com',
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.location_on, color: Colors.white, size: 16),
                      SizedBox(width: 4),
                      Text(
                        "Xem bản đồ quán",
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: groupList.length >= 20 ? 20 : groupList.length,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemBuilder: (context, index) {
              final group = groupList[index];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              GroupDetailPage(groupId: group['id'])),
                    );
                  },
                  child: Container(
                    width: 220,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.white.withOpacity(0.12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          GroupImageWidget(imageUrl: group['image']),
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.black.withOpacity(0.6),
                                  Colors.transparent
                                ],
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  group['name'],
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.star,
                                        color: Colors.amber, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      (group['rating'] ?? '0').toString(),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        group['address'] ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.7),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () {
                                        if ((group['address'] ?? '').isNotEmpty) {
                                          openGoogleMaps(group['address']);
                                        }
                                      },
                                      child: Icon(
                                        Icons.directions,
                                        size: 18,
                                        color: Colors.white70,
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
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 24),

        // ================= GRID BOTTOM =================
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            "Các quán khác",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: textWhite,
            ),
          ),
        ),
        const SizedBox(height: 12),

        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.85,
              ),
              itemCount: groupList.length > 20 ? groupList.length - 20 : 0,
              itemBuilder: (context, index) {
                final group = groupList[index + 20];
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              GroupDetailPage(groupId: group['id'])),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(16)),
                            child: GroupImageWidget(imageUrl: group['image']),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                group['name'],
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.star,
                                      color: Colors.amber, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    (group['rating'] ?? '0').toString(),
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.9),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      group['address'] ?? '',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.7),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      if ((group['address'] ?? '').isNotEmpty) {
                                        openGoogleMaps(group['address']);
                                      }
                                    },
                                    child: Icon(
                                      Icons.directions,
                                      size: 16,
                                      color: Colors.white70,
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
                );
              },
            ),
          ),
        ),
      ],
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
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
        child: SafeArea(
          child: isLoading ? _buildSkeleton() : _buildContent(),
        ),
      ),
    );
  }
}

// =====================================================
// IMAGE LOAD FADE
// =====================================================
class GroupImageWidget extends StatefulWidget {
  final String imageUrl;

  const GroupImageWidget({super.key, required this.imageUrl});

  @override
  State<GroupImageWidget> createState() => _GroupImageWidgetState();
}

class _GroupImageWidgetState extends State<GroupImageWidget> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final image = NetworkImage(widget.imageUrl);
    image.resolve(const ImageConfiguration()).addListener(
      ImageStreamListener((_, __) {
        if (mounted) setState(() => _loaded = true);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black.withOpacity(0.15)),
        AnimatedOpacity(
          opacity: _loaded ? 1 : 0,
          duration: const Duration(milliseconds: 400),
          child: Image.network(
            widget.imageUrl,
            fit: BoxFit.cover,
          ),
        ),
      ],
    );
  }
}
