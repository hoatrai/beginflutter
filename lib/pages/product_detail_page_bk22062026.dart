  import 'dart:convert';
  import 'dart:math';
  import 'package:flutter/material.dart';
  import 'package:cached_network_image/cached_network_image.dart';
  import 'package:flutter_html/flutter_html.dart';
  import 'package:intl/intl.dart';
  import 'package:video_player/video_player.dart';
  import 'package:http/http.dart' as http;
  import 'package:video_thumbnail/video_thumbnail.dart';

  import 'package:image_picker/image_picker.dart';
  import 'dart:io';

  import '../helpers/storage_helper.dart';
  import 'group_chat_page.dart';
  import '../helpers/user_helper.dart';
  import 'package:firebase_messaging/firebase_messaging.dart';
  import 'package:shimmer/shimmer.dart' as shimmer;
  import 'invite_map_page.dart';
  import 'spin_wheel.dart';
  import 'dart:async';
  import 'package:web_socket_channel/web_socket_channel.dart';
  
  
  
  class ProductDetailPage extends StatefulWidget {
    final Map<String, dynamic> product;
    final Function(Map<String, dynamic> updatedProduct)? onJoin;
  
    const ProductDetailPage({
      super.key,
      required this.product,
      this.onJoin,
    });
  
    @override
    State<ProductDetailPage> createState() => _ProductDetailPageState();
  }
  
  class _ProductDetailPageState extends State<ProductDetailPage> with SingleTickerProviderStateMixin {
    final GlobalKey<SpinWheelState> _wheelKey = GlobalKey();
    int _currentImage = 0;
    List<Map<String, dynamic>> participants = [];
    bool isLoadingJoin = false;
    int? _currentUserId;
    Map<String, dynamic> _spinResult = {};
    Map<int, VideoPlayerController> _videoMap = {};
    bool _videoInited = false;
  
    bool isJoined = false;
    bool isHost = false;
    bool isFull = false;
    String? inviteStatus; // null = chưa load
    bool allowRating = false;
  
    int joinedCount = 0;
    int maxPeople = 0;
  
    int viewerCount = 0;
  
    int? inviteId;
    bool isUpdatingAttendance = false;
    bool isUpdatingInviteStatus = false;
  
    late WebSocketChannel channel;
  
    Timer? heartbeatTimer;
  
    bool _socketJoined = false;

    List<Map<String, dynamic>> inviteMedia = [];
    bool isLoadingMedia = false;

    bool isUploadingMedia = false;
  
  
  
    late AnimationController _pulseController;
    late Animation<double> _pulseAnimation;
  
  
  
    bool get canJoin {
      if (inviteStatus == null) return false;
      if (inviteStatus != 'open') return false;
      if (isFull) return false;
      return true;
    }
  
  
  
  
  
  
    final Color primaryBlue = const Color(0xFF1E3A8A);
    final Color accentOrange = const Color(0xFFFF7F50);

  
    @override
    void initState() {
      super.initState();
  
      _loadUserId();
      connectSocket();
      _loadJoinStatus();
  
      _pulseController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      )..repeat(reverse: true);
  
      _pulseAnimation = Tween<double>(
        begin: 1.0,
        end: 1.08,
      ).animate(
        CurvedAnimation(
          parent: _pulseController,
          curve: Curves.easeInOut,
        ),
      );
    }
  
    @override
    void dispose() {
      // _leaveViewerRoom();
      heartbeatTimer?.cancel();
  
      channel.sink.close();
  
      _pulseController.dispose();
  
      // ✅ DISPOSE VIDEO CONTROLLERS
      for (final c in _videoMap.values) {
        c.dispose();
      }
      _videoMap.clear();
  
      super.dispose();
    }
  
    void _initVideos(List<Map<String, dynamic>> mediaList) {
      for (int i = 0; i < mediaList.length; i++) {
        final item = mediaList[i];
  
        if (item['type'] == 'video') {
          final controller = VideoPlayerController.networkUrl(
            Uri.parse(item['url']),
          );
  
          _videoMap[i] = controller;
  
          controller.initialize().then((_) {
            if (!mounted) return;
  
            controller.setLooping(true);
            controller.setVolume(1.0);
  
            // ✅ CHỈ PLAY VIDEO ĐẦU
            if (i == 0) {
              controller.play();
            }
  
            setState(() {});
          });
        }
      }
    }

    Future<void> _showMediaPicker() async {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) {
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primaryBlue.withOpacity(0.95),
                  accentOrange.withOpacity(0.9),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [

                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white30,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),

                const SizedBox(height: 16),

                const Text(
                  "📸 Thêm khoảnh khắc",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 20),

                _mediaButton(
                  icon: Icons.photo_library_rounded,
                  title: "Chọn ảnh",
                  subtitle: "Đăng ảnh lên bàn nhậu",
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage();
                  },
                ),

                const SizedBox(height: 12),

                _mediaButton(
                  icon: Icons.videocam_rounded,
                  title: "Chọn video",
                  subtitle: "Chia sẻ video cùng mọi người",
                  onTap: () {
                    Navigator.pop(context);
                    _pickVideo();
                  },
                ),

                const SizedBox(height: 16),
              ],
            ),
          );
        },
      );
    }

    Future<void> _pickImage() async {
      final picker = ImagePicker();

      final file = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (file == null) return;

      await _uploadMedia(
        File(file.path),
        'image',
      );
    }

    Future<void> _pickVideo() async {
      final picker = ImagePicker();

      final file = await picker.pickVideo(
        source: ImageSource.gallery,
      );

      if (file == null) return;

      await _uploadMedia(
        File(file.path),
        'video',
      );
    }
    Future<String> uploadVideoToCloudinary(File videoFile) async {
      const cloudName = "datm1erra";
      const uploadPreset = "flutter_upload";

      final uri = Uri.parse(
        "https://api.cloudinary.com/v1_1/$cloudName/video/upload",
      );

      final request = http.MultipartRequest("POST", uri);

      request.fields['upload_preset'] = uploadPreset;

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          videoFile.path,
        ),
      );

      final response = await request.send();
      final resBody = await response.stream.bytesToString();

      final data = jsonDecode(resBody);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return data['secure_url'];
      } else {
        throw Exception("Upload video failed: $resBody");
      }
    }
    Future<void> _uploadMedia(
        File file,
        String type,
        ) async {

      setState(() {
        isUploadingMedia = true;
      });

      try {

        final token = await StorageHelper.read("jwt_token");

        String mediaUrl;

        // ==========================
        // 1. UPLOAD
        // ==========================

        if (type == 'video') {

          mediaUrl = await uploadVideoToCloudinary(file);

        } else {

          final uploadRequest = http.MultipartRequest(
            'POST',
            Uri.parse(
              '${AppConfig.webDomain}/wp-json/nhau/v1/upload',
            ),
          );

          uploadRequest.headers['Authorization'] =
          'Bearer $token';

          uploadRequest.files.add(
            await http.MultipartFile.fromPath(
              'file',
              file.path,
            ),
          );

          final uploadResponse =
          await http.Response.fromStream(
            await uploadRequest.send(),
          );

          final uploadData =
          jsonDecode(uploadResponse.body);

          if (uploadData['success'] != true) {
            throw Exception(
              uploadData['message'] ??
                  'Upload ảnh thất bại',
            );
          }

          mediaUrl = uploadData['url'];
        }

        // ==========================
        // 2. SAVE INVITE MEDIA
        // ==========================

        final saveResponse = await http.post(
          Uri.parse(
            '${AppConfig.webDomain}/wp-json/nhau/v1/invite/media/add',
          ),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'invite_id': inviteId,
            'type': type,
            'url': mediaUrl,
          }),
        );

        final saveData =
        jsonDecode(saveResponse.body);

        if (saveData['success'] != true) {
          throw Exception(
            saveData['message'] ??
                'Không lưu được media',
          );
        }

        // ==========================
        // 3. RELOAD
        // ==========================

        await _fetchInviteMedia();

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              type == 'video'
                  ? "🎥 Video đã đăng"
                  : "📸 Ảnh đã đăng",
            ),
          ),
        );

      } catch (e) {

        debugPrint(
          "UPLOAD ERROR => $e",
        );

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "❌ $e",
            ),
          ),
        );

      } finally {

        if (mounted) {
          setState(() {
            isUploadingMedia = false;
          });
        }
      }
    }

  
    /*void _joinViewerRoom() {
      if (inviteId == null) return;
  
      channel.sink.add(
        jsonEncode({
          "topic": "viewer:$inviteId",
          "event": "join_viewer",
          "payload": {},
          "ref": DateTime.now().millisecondsSinceEpoch.toString(),
        }),
      );
    }*/
  
    /*void _leaveViewerRoom() {
      if (inviteId == null || !_socketJoined) return;
  
      try {
        channel.sink.add(
          jsonEncode({
            "topic": "viewer:$inviteId",
            "event": "leave_viewer",
            "payload": {},
            "ref": DateTime.now().millisecondsSinceEpoch.toString(),
          }),
        );
      } catch (e) {
        debugPrint("❌ leave_viewer error: $e");
      }
    }*/
  
  
    void connectSocket() {
      channel = WebSocketChannel.connect(
        Uri.parse(
          'wss://socket.spiritwebs.com/socket/websocket',
        ),
      );
      channel.sink.add(
        jsonEncode({
          "topic": "phoenix",
          "event": "phx_join",
          "payload": {},
          "ref": "1"
        }),
      );
  
      channel.stream.listen(
            (message) async {
          try {
            final decoded = jsonDecode(message);
  
            debugPrint("SOCKET => $decoded");
  
            final event = decoded['event'];
  
            debugPrint("EVENT=$event");
            debugPrint("TOPIC=${decoded['topic']}");
            debugPrint("PAYLOAD=${decoded['payload']}");
            debugPrint("SOCKET_JOINED=$_socketJoined");
  
            if (event == 'phx_reply' &&
                decoded['topic'] == 'phoenix' &&
                !_socketJoined) {
  
              _socketJoined = true;
  
              debugPrint("✅ SOCKET CONNECTED");
  
              if (inviteId != null) {
                joinInviteRoom(inviteId!);
                //_joinViewerRoom(); // thêm dòng này
              }
            }
            if (event == 'viewer_count') {
              final payload = decoded['payload'];
  
              debugPrint(
                "👀 COUNT FROM SERVER = ${payload['count']}",
              );
  
              if (!mounted) return;
  
              setState(() {
                viewerCount = payload['count'] ?? 0;
              });
            }
  
            if (event == 'user_joined') {
              final payload = decoded['payload'];
  
              if (payload['invite_id'] == inviteId) {
                await _fetchParticipants(inviteId!);
              }
            }
  
            if (event == 'user_left') {
              final payload = decoded['payload'];
  
              if (payload['invite_id'] == inviteId) {
                await _fetchParticipants(inviteId!);
              }
            }
  
            if (event == 'user_kicked') {
              final payload = decoded['payload'];
  
              if (payload['invite_id'] == inviteId) {
                await _fetchParticipants(inviteId!);
              }
            }
  
            if (event == 'invite_closed') {
              final payload = decoded['payload'];
  
              if (payload['invite_id'] == inviteId) {
                await _fetchParticipants(inviteId!);
              }
            }
  
            if (event == 'invite_opened') {
              final payload = decoded['payload'];
  
              if (payload['invite_id'] == inviteId) {
                await _fetchParticipants(inviteId!);
              }
            }
            if (event == 'attendance_updated') {
              final payload = decoded['payload'];
  
              if (payload['invite_id'] == inviteId) {
                await _fetchParticipants(inviteId!);
              }
            }
          } catch (e) {
            debugPrint("socket error => $e");
          }
        },
      );
  
      heartbeatTimer?.cancel();
  
      heartbeatTimer = Timer.periodic(
        const Duration(seconds: 30),
            (_) {
          channel.sink.add(
            jsonEncode({
              "topic": "phoenix",
              "event": "heartbeat",
              "payload": {},
              "ref": DateTime.now()
                  .millisecondsSinceEpoch
                  .toString(),
            }),
          );
        },
      );
    }
  
    /*void joinInviteRoom(int inviteId) {
      debugPrint("🚀 JOIN ROOM invite:$inviteId");
      channel.sink.add(
        jsonEncode({
          "topic": "invite:$inviteId",
          "event": "phx_join",
          "payload": {},
          "ref": DateTime.now()
              .millisecondsSinceEpoch
              .toString(),
          "join_ref": "1"
        }),
      );
  
      debugPrint("JOIN SOCKET invite:$inviteId");
    }*/
    /*void joinInviteRoom(int inviteId) {
      debugPrint("🚀 JOIN ROOM invite:$inviteId");
  
      final payload = {
        "topic": "invite:$inviteId",
        "event": "phx_join",
        "payload": {},
        "ref": DateTime.now().millisecondsSinceEpoch.toString(),
        "join_ref": "1"
      };
  
      debugPrint("📦 JOIN PAYLOAD = ${jsonEncode(payload)}");
  
      channel.sink.add(jsonEncode(payload));
    }*/

    Future<void> _fetchInviteMedia() async {
      debugPrint("🔥 CALL _fetchInviteMedia");
      debugPrint("👉 inviteId = $inviteId");
      if (inviteId == null) return;

      setState(() => isLoadingMedia = true);

      try {
        final res = await http.get(
          Uri.parse(
            '${AppConfig.webDomain}/wp-json/nhau/v1/invite/media?invite_id=$inviteId',
          ),
        );

        final data = jsonDecode(res.body);

        if (data['success'] == true) {
          setState(() {
            inviteMedia = List<Map<String, dynamic>>.from(
              data['items'] ?? [],
            );
          });
        }
      } catch (e) {
        debugPrint("Media error: $e");
      } finally {
        if (mounted) {
          setState(() => isLoadingMedia = false);
        }
      }
    }


    Future<void> joinInviteRoom(int inviteId) async {
      final userId = await StorageHelper.read("user_id");
  
      channel.sink.add(
        jsonEncode({
          "topic": "invite:$inviteId",
          "event": "phx_join",
          "payload": {
            "user_id": userId.toString(),
          },
          "ref": DateTime.now().millisecondsSinceEpoch.toString(),
          "join_ref": DateTime.now()
              .millisecondsSinceEpoch
              .toString(),
        }),
      );
    }
  
  
    Future<void> _loadUserId() async {
      final id = await StorageHelper.read("user_id");
      setState(() {
        _currentUserId = id != null ? int.tryParse(id.toString()) : null;
      });
    }
    Widget _mediaButton({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(0.12),
            ),
          ),
          child: Row(
            children: [

              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: Colors.orangeAccent,
                  size: 26,
                ),
              ),

              const SizedBox(width: 14),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 4),

                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              const Icon(
                Icons.arrow_forward_ios,
                color: Colors.white54,
                size: 16,
              ),
            ],
          ),
        ),
      );
    }
    Widget buildAvatarWithKick({
      required String? avatarUrl,
      required String name,
      bool showKick = false,
      VoidCallback? onKick,
    }) {
      return Stack(
        clipBehavior: Clip.none, // 🔥 quan trọng
        children: [
          ClipOval(
            child: Image.network(
              avatarUrl ?? '${AppConfig.webDomain}/media/2025/10/default-avatar.png',
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
              const Icon(Icons.person, size: 32, color: Colors.white54),
            ),
          ),
  
          if (showKick)
            Positioned(
              top: -6,
              right: -6,
              child: GestureDetector(
                onTap: onKick,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      );
    }
  
  
    Future<void> _kickUser(int targetUserId) async {
      if (inviteId == null) return;
  
      final token = await StorageHelper.read("jwt_token");
  
      try {
        final url = Uri.parse(
          '${AppConfig.webDomain}/wp-json/nhau/v1/invite/kick',
        );
  
        final res = await http.post(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'invite_id': inviteId,
            'user_id': targetUserId,
          }),
        );
  
        final data = jsonDecode(res.body);
  
        if (data['success'] != true) {
          throw Exception(data['message'] ?? 'Kick thất bại');
        }
  
        await _fetchParticipants(inviteId!);
  
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã kick thành viên')),
        );
      } catch (e) {
        debugPrint("❌ Kick error: $e");
  
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể kick: $e')),
        );
      }
    }
  
  
  
    //int get joinedCount => participants.length;
  
    Future<void> _loadJoinStatus() async {
      if (!mounted) return;
  
      setState(() => isLoadingJoin = true);
  
      try {
        final productId = int.parse(widget.product['id'].toString());
        final id = await _fetchInviteIdByProduct(productId);
  
        if (!mounted) return;
  
        if (id != null) {
          setState(() {
            inviteId = id;
          });
  
          //joinInviteRoom(id);
          debugPrint("🔥 INVITE ID = $id");
          debugPrint("🔥 SOCKET JOINED = $_socketJoined");
  
          if (_socketJoined) {
            joinInviteRoom(id);
            //_joinViewerRoom(); // thêm dòng này
          }
          await _fetchInviteMedia(); // 🔥 CHỈ GỌI Ở ĐÂY
          await _fetchParticipants(id);
        }
      } catch (e) {
        debugPrint("❌ _loadJoinStatus error: $e");
      }
  
      if (!mounted) return;
      setState(() => isLoadingJoin = false);
    }
  
    Future<int?> _fetchInviteIdByProduct(int productId) async {
      final token = await StorageHelper.read("jwt_token");
  
      try {
        final url = Uri.parse(
          '${AppConfig.webDomain}/wp-json/nhau/v1/invite/by-product?product_id=$productId',
        );
  
        debugPrint("🌐 CALL URL = $url");
  
        final res = await http.get(url, headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        });
  
        debugPrint("🌐 STATUS = ${res.statusCode}");
        debugPrint("🌐 RAW BODY = ${res.body}");
  
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          debugPrint("📦 PARSED = $data");
  
          if (data['success'] == true) {
            return int.tryParse(data['invite_id'].toString());
          }
        }
      } catch (e) {
        debugPrint("❌ Fetch invite by product error: $e");
      }
  
      return null;
    }

  
    Future<void> _fetchParticipants(int inviteId) async {
      final token = await StorageHelper.read("jwt_token");
  
      try {
        final url = Uri.parse(
            '${AppConfig.webDomain}/wp-json/nhau/v1/invite/detail?invite_id=$inviteId');
  
        final res = await http.get(url, headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        });
  
        if (res.statusCode == 200) {
          debugPrint("DETAIL STATUS = ${res.statusCode}");
          debugPrint("DETAIL BODY = ${res.body}");
          final data = jsonDecode(res.body);
  
          if (data['success'] == true) {
            final invite = data['invite'];
            final _inviteId = int.tryParse(invite['id'].toString());
            final List list = data['members'] ?? [];
  
            final _isJoined = data['is_joined'] ?? false;
            final _isHost = data['is_host'] ?? false;
            final _isFull = data['is_full'] ?? false;
  
            debugPrint("API is_joined = $_isJoined");
  
  
            final _joinedCount = int.tryParse(data['joined_count'].toString()) ?? 0;
            final _inviteStatus = invite['status'] ?? 'open';
            final _maxPeople = int.tryParse(invite['max_people'].toString()) ?? 0;

            final parsed = list.map((m) {
              return {
                'user_id': int.tryParse(m['user_id'].toString()) ?? 0,
                'name': m['display_name']?.toString() ?? '',
                'status': m['status']?.toString() ?? '',
                'role': m['role']?.toString() ?? '',
                'attendance_status': m['attendance_status']?.toString() ?? 'undecided',
                'trust_score': int.tryParse(m['trust_score']?.toString() ?? '') ?? 50,
              };
            }).toList();
  
  
            await _fetchAvatarsForParticipants(parsed);
  
            if (!mounted) return;
  
            setState(() {
              inviteId = _inviteId ?? 0;
              isJoined = _isJoined;
              isHost = _isHost;
              isFull = _isFull;
              joinedCount = _joinedCount;
              inviteStatus = _inviteStatus;
              maxPeople = _maxPeople;
              participants = parsed;
              // 🔥 THÊM DÒNG NÀY
              allowRating = (inviteStatus?.toString() == 'closed');
            });
  
            widget.onJoin?.call({
              'id': widget.product['id'],
              'joined_count': _joinedCount,
            });
  
  
  
            return;
          }
  
        }
      } catch (e) {
        debugPrint("❌ Fetch invite detail error: $e");
      }
    }
  
  
    Widget buildAttendanceBadge(String status) {
      String text = '';
      Color color = Colors.grey;
  
      switch (status) {
        case 'going':
          text = 'Đã tới';
          color = Colors.green;
          break;
        case 'on_the_way':
          text = 'Đang tới';
          color = Colors.orange;
          break;
        case 'late':
          text = 'Tới trễ';
          color = Colors.deepOrange;
          break;
        case 'not_going':
          text = 'Không đi';
          color = Colors.red;
          break;
        default:
          text = 'Vừa join';
          color = Colors.blue;
      }
  
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.85),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      );
    }
  
  
  
    Future<void> _fetchAvatarsForParticipants(List<Map<String, dynamic>> list) async {
      if (list.isEmpty) return;
      final url = Uri.parse('${AppConfig.webDomain}/wp-json/profile/v1/users');
      final token = await StorageHelper.read("jwt_token");
      final userIds = list.map((p) => p['user_id']).toList();
  
      try {
        final res = await http.post(
          url,
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
          body: jsonEncode({'ids': userIds}),
        );
  
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final users = List<Map<String, dynamic>>.from(data['users'] ?? []);
          final avatarMap = {for (var u in users) u['user_id']: u['avatar_url']};
  
          if (!mounted) return;
  
          setState(() {
            participants = list.map((p) {
              p['avatar'] = avatarMap[p['user_id']] ?? '${AppConfig.webDomain}/media/2025/10/default-avatar.png';
              return p;
            }).toList();
          });
  
        }
      } catch (e) {
        debugPrint('⚠️ Lỗi fetch avatars: $e');
      }
    }
  
    Future<void> _joinInvite(int inviteId) async {
      setState(() => isLoadingJoin = true);
  
      final token = await StorageHelper.read("jwt_token");
  
      if (!canJoin) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Không thể tham gia kèo này")),
        );
        return;
      }
  
  
      try {
        // ===== 1️⃣ JOIN API MỚI =====
        final urlNew = Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/invite/join');
  
        final resNew = await http.post(
          urlNew,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'invite_id': inviteId,
          }),
        );
        debugPrint("JOIN STATUS: ${resNew.statusCode}");
        debugPrint("JOIN BODY: ${resNew.body}");
  
  
        final dataNew = jsonDecode(resNew.body);
  
        if (dataNew['success'] != true) {
          throw Exception(dataNew['message'] ?? 'Join new API failed');
        }
  
        // ===== 2️⃣ JOIN API CŨ =====
  
  
        // ===== 3️⃣ RELOAD =====
  
        await _fetchParticipants(inviteId);
  
  
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bạn đã tham gia thành công!')),
        );
      } catch (e) {
        debugPrint("❌ Join error: $e");
  
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể tham gia: $e')),
        );
      } finally {
        setState(() => isLoadingJoin = false);
      }
    }
  
  
    Future<void> _leaveInvite(int inviteId) async {
      setState(() => isLoadingJoin = true);
      final token = await StorageHelper.read("jwt_token");
  
      try {
        // ===== 1️⃣ LEAVE API MỚI (TABLE) =====
        final urlNew = Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/invite/leave');
  
        final resNew = await http.post(
          urlNew,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'invite_id': inviteId,
          }),
        );
  
        final dataNew = jsonDecode(resNew.body);
  
        if (dataNew['success'] != true) {
          throw Exception(dataNew['message'] ?? 'Leave new API failed');
        }
  
        // ===== 2️⃣ LEAVE API CŨ (META) =====
  
  
        await _fetchParticipants(inviteId);
  
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã hủy tham gia')),
        );
      } catch (e) {
        debugPrint("❌ Leave error: $e");
  
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể hủy tham gia: $e')),
        );
      } finally {
        setState(() => isLoadingJoin = false);
      }
    }
  
  
    String formatVND(String value) {
      try {
        final numVal = double.parse(value);
        final formatter = NumberFormat('#,###', 'vi_VN');
        return "${formatter.format(numVal)}";
      } catch (e) {
        return value;
      }
    }
    void _pauseAllVideosExcept(int activeIndex) {
      _videoMap.forEach((index, controller) {
        if (!controller.value.isInitialized) return;
  
        if (index == activeIndex) {
          controller.play();
        } else {
          controller.pause();
  
          // ✅ GIẢM MEMORY
          controller.seekTo(Duration.zero);
        }
      });
    }

    Future<void> _deleteMedia(int mediaId) async {
      final token = await StorageHelper.read("jwt_token");

      final res = await http.post(
        Uri.parse(
          '${AppConfig.webDomain}/wp-json/nhau/v1/invite/media/delete',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'media_id': mediaId,
        }),
      );

      final data = jsonDecode(res.body);

      if (data['success'] == true) {
        await _fetchInviteMedia();
      }
    }
  
    @override
    Widget build(BuildContext context) {
      final product = widget.product;
      final name = product['name'] ?? '';
      final description = product['description'] ?? '';
      //final price = product['regular_price'] ?? product['price'] ?? '0';
      final images = product['images'] as List<dynamic>? ?? [];
      final categories = product['categories'] as List<dynamic>? ?? [];
      final metaData = product['meta_data'] as List<dynamic>? ?? [];

  
      List<String> videoUrls = [];
  
      for (final item in metaData) {
        if (item['key'] == 'videos') {
          final raw = item['value'];
  
          if (raw != null && raw.toString().isNotEmpty) {
            try {
              final decoded = jsonDecode(raw);
  
              if (decoded is String) {
                videoUrls = List<String>.from(jsonDecode(decoded));
              } else if (decoded is List) {
                videoUrls = List<String>.from(decoded);
              }
            } catch (e) {
              debugPrint("❌ video parse error: $e");
              videoUrls = [];
            }
          }
        }
      }
  
      final mediaList = [
        ...videoUrls.map((url) => {
          'type': 'video',
          'url': url,
        }),
        ...images.map((e) => {
          'type': 'image',
          'url': e['src'],
        }),
      ];
      if (!_videoInited) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _initVideos(mediaList);
        });
        _videoInited = true;
      }
      String? priceRange;
  
      for (final item in metaData) {
        if (item['key'] == 'price_range') {
          priceRange = item['value']?.toString();
          break;
        }
      }
  
      String priceText;
  
      switch (priceRange) {
        case null:
        case '':
        case '0':
          priceText = "Miễn phí";
          break;
  
        case '50-100':
          priceText = "50k - 100k";
          break;
  
        case '100-200':
          priceText = "100k - 200k";
          break;
  
        case '200-500':
          priceText = "200k - 500k";
          break;
  
        case '500+':
          priceText = "500k+";
          break;
  
        default:
          priceText = "$priceRange";
      }
  
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryBlue.withOpacity(0.95), accentOrange.withOpacity(0.85)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  expandedHeight: 280,
                  pinned: true,
                  backgroundColor: Colors.transparent,
                  leading: IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                      onPressed: () => Navigator.pop(context)),
                  flexibleSpace: FlexibleSpaceBar(
                    titlePadding: const EdgeInsets.only(
                      left: 72,
                      right: 16,
                      bottom: 30, // tăng số này để title lên cao hơn
                    ),
                    title: Text(name,
                        style: const TextStyle(fontSize: 20,color: Colors.white,
                            fontWeight: FontWeight.bold,
                            shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
                    background: Stack(
                      children: [
                        PageView.builder(
                          allowImplicitScrolling: false,
                          itemCount: mediaList.length,
                          onPageChanged: (index) {
                            setState(() => _currentImage = index);
                            _pauseAllVideosExcept(index);
                          },
                          itemBuilder: (context, index) {
                            final item = mediaList[index];
  
                            if (item['type'] == 'image') {
                              return CachedNetworkImage(
                                imageUrl: item['url'],
                                fit: BoxFit.cover,
                              );
                            }
  
                            if (item['type'] == 'video') {
                              final controller = _videoMap[index];
  
                              if (controller != null && controller.value.isInitialized) {
                                return GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => Scaffold(
                                          backgroundColor: Colors.black,
                                          body: Center(
                                            child: GestureDetector(
                                              onTap: () => Navigator.pop(context),
                                              child: AspectRatio(
                                                aspectRatio: controller.value.aspectRatio,
                                                child: VideoPlayer(controller),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                  child: Center(
                                    child: FittedBox(
                                      fit: BoxFit.contain,
                                      child: SizedBox(
                                        width: controller.value.size.width,
                                        height: controller.value.size.height,
                                        child: VideoPlayer(controller),
                                      ),
                                    ),
                                  ),
                                );
                              }
  
                              return const Center(child: CircularProgressIndicator());
  
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }
                            // 🔥 FIX CRASH HERE
                            return const SizedBox();
                          },
                        ),
                        if (mediaList.length > 1)
                          Positioned(
                            bottom: 12,
                            left: 0,
                            right: 0,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(mediaList.length, (index) {
                                return Container(
                                  width: 8,
                                  height: 8,
                                  margin: const EdgeInsets.symmetric(horizontal: 4),
                                  decoration: BoxDecoration(color: _currentImage == index ? Colors.white : Colors.white54, shape: BoxShape.circle),
                                );
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([

                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [

                          // ================= PRICE + ACTION =================


                          // ================= STATUS CARD (viewer + capacity) =================
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.1),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [

                                // ================= LEFT: viewer + capacity =================
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [

                                      ViewerIndicator(viewerCount: viewerCount),

                                      const SizedBox(height: 6),

                                      if (maxPeople > 0)
                                        Row(
                                          children: [
                                            const Icon(Icons.people_alt,
                                                color: Colors.orangeAccent, size: 16),
                                            const SizedBox(width: 6),
                                            Text(
                                              "$joinedCount / $maxPeople người tham gia",
                                              style: const TextStyle(
                                                color: Colors.orangeAccent,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),

                                const SizedBox(width: 10),

                                // ================= RIGHT: BUTTON =================
                                ScaleTransition(
                                  scale: _pulseAnimation,
                                  child: (inviteStatus == null || isUpdatingInviteStatus)
                                      ? _buildShimmerButton(width: 90, height: 30)
                                      : _buildInviteStatusBadge(),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 14),

                          // ================= PARTICIPANTS =================
                          if (participants.isNotEmpty) ...[
                            const Text(
                              "Thành viên",
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),

                            const SizedBox(height: 10),

                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: participants.map((p) {
                                final isMe = p['user_id'] == _currentUserId;
                                final canKick = isHost && !isMe;

                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        buildAvatarWithKick(
                                          avatarUrl: p['avatar'],
                                          name: p['name'],
                                          showKick: canKick,
                                          onKick: () => _kickUser(p['user_id']),
                                        ),

                                        Positioned(
                                          bottom: -4,
                                          right: -4,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.green,
                                              borderRadius: BorderRadius.circular(10),
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 1,
                                              ),
                                            ),
                                            child: Text(
                                              "${p['trust_score'] ?? 50}",
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 9,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 2),

                                    Text(
                                      p['name'] ?? '',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                      ),
                                    ),


                                    const SizedBox(height: 3),

                                    isMe && isUpdatingAttendance
                                        ? _buildAttendanceShimmer()
                                        : buildAttendanceBadge(p['attendance_status']),
                                  ],
                                );
                              }).toList(),
                            ),

                            const SizedBox(height: 16),
                          ],
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [

                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (allowRating)
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.blueAccent,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        minimumSize: const Size(0, 32), // 👈 QUAN TRỌNG: giảm chiều cao tối thiểu
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        visualDensity: VisualDensity.compact, // 👈 làm nút gọn lại
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                      ),
                                      onPressed: _openRatingSheet,
                                      icon: const Icon(Icons.star, color: Colors.white, size: 16),
                                      label: const Text(
                                        "Đánh giá",
                                        style: TextStyle(color: Colors.white, fontSize: 12),
                                      ),
                                    ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [

                                      const Text(
                                        "📸 Khoảnh khắc bàn nhậu",
                                        style: TextStyle(
                                          color: Colors.orangeAccent,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),


                                      if (isHost || isJoined)
                                        IconButton(
                                          icon: const Icon(
                                            Icons.add_circle,
                                            color: Colors.orangeAccent,
                                          ),
                                          onPressed: _showMediaPicker,
                                        ),
                                    ],
                                  ),

                                  if (isUploadingMedia) ...[
                                    const SizedBox(height: 8),

                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: const LinearProgressIndicator(
                                        minHeight: 6,
                                      ),
                                    ),

                                    const SizedBox(height: 6),

                                    const Text(
                                      "Đang đăng khoảnh khắc...",
                                      style: TextStyle(
                                        color: Colors.orangeAccent,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),

                              const SizedBox(height: 12),

                              if (inviteMedia.isEmpty)

                                Container(
                                  height: 100,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text(
                                    "Chưa có ảnh hoặc video",
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                )

                              else

                                SizedBox(
                                  height: 120,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: inviteMedia.length,
                                    itemBuilder: (context, index) {

                                      final item = inviteMedia[index];

                                      final isVideo =
                                          item['type'] == 'video' ||
                                              item['url'].toString().contains('.mp4');
                                      final canDelete =
                                          isHost ||
                                              (int.tryParse(item['user_id']?.toString() ?? '') == _currentUserId);

                                      return Container(
                                        width: 100,
                                        margin: const EdgeInsets.only(right: 10),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [

                                              // MEDIA
                                              isVideo
                                                  ? GestureDetector(
                                                onTap: () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (_) => FullScreenVideoPage(
                                                        videoUrl: item['url'],
                                                      ),
                                                    ),
                                                  );
                                                },
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [

                                                    Container(
                                                      color: Colors.black26,
                                                    ),

                                                    const Center(
                                                      child: Icon(
                                                        Icons.play_circle_fill,
                                                        size: 50,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              )
                                                  : Image.network(
                                                item['url'],
                                                fit: BoxFit.cover,
                                              ),

                                              // NÚT XOÁ
                                              if (canDelete)
                                                Positioned(
                                                  top: 4,
                                                  right: 4,
                                                  child: GestureDetector(
                                                    onTap: () {
                                                      _deleteMedia(int.parse(item['id'].toString()));
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(4),
                                                      decoration: BoxDecoration(
                                                        color: Colors.red.withOpacity(0.9),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: const Icon(
                                                        Icons.close,
                                                        size: 14,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),

                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),

                              const SizedBox(height: 20),

                            ],
                          ),
                        ],
                      ),



                      if (metaData.isNotEmpty) const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            //Text("inviteStatus=$inviteStatus | isJoined=$isJoined | allowRating=$allowRating"),
                            if (isHost || isJoined)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isHost)
                                    inviteStatus == null || isUpdatingInviteStatus
                                        ? _buildShimmerButton(width: 110, height: 36)
                                        : chipButton(
                                      label: inviteStatus == 'open'
                                          ? "Đóng bàn"
                                          : "Mở lại bàn",
                                      icon: inviteStatus == 'open'
                                          ? Icons.lock
                                          : Icons.lock_open,
                                      onTap: () async {
                                        if (inviteId == null) return;

                                        setState(() => isUpdatingInviteStatus = true);

                                        if (inviteStatus == 'open') {
                                          await _closeInvite(inviteId!);
                                        } else {
                                          await _openInvite(inviteId!);
                                        }

                                        if (mounted) {
                                          setState(() => isUpdatingInviteStatus = false);
                                        }
                                      },
                                    ),

                                  if (isHost && isJoined)
                                    const SizedBox(width: 8), // ✅ KHOẢNG CÁCH

                                  if (isJoined)
                                    isUpdatingAttendance
                                        ? _buildShimmerButton(width: 110, height: 36)
                                        : chipButton(
                                      label: "Trạng thái",
                                      icon: Icons.flag,
                                      onTap: _showAttendancePicker,
                                    ),
                                ],
                              ),



                          ],
                        ),
                      ),

                      const SizedBox(height: 12),


                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(.08),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withOpacity(.08),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(.2),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Stack(
                          children: [

                            Positioned(
                              right: -20,
                              top: -20,
                              child: Icon(
                                Icons.local_bar_rounded,
                                size: 120,
                                color: Colors.white.withOpacity(.03),
                              ),
                            ),

                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [

                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.12),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.payments_outlined,
                                        color: Colors.greenAccent,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        "$priceText / người",
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.greenAccent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 12),
                                /// CATEGORY
                                if (categories.isNotEmpty)
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: categories.map((cat) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.withOpacity(.15),
                                          borderRadius: BorderRadius.circular(30),
                                          border: Border.all(
                                            color: Colors.orange.withOpacity(.25),
                                          ),
                                        ),
                                        child: Text(
                                          cat['name'] ?? '',
                                          style: const TextStyle(
                                            color: Colors.orangeAccent,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),

                                if (categories.isNotEmpty)
                                  const SizedBox(height: 20),

                                /// SLOTS + TIME
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: metaData.where((e) {
                                    return ['slots', 'time'].contains(e['key']);
                                  }).map((meta) {

                                    final icon = meta['key'] == 'slots'
                                        ? Icons.people_alt_rounded
                                        : Icons.access_time_rounded;

                                    return Container(
                                      width: 160,
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Colors.orange.withOpacity(.18),
                                            Colors.deepOrange.withOpacity(.08),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: Colors.orange.withOpacity(.15),
                                        ),
                                      ),
                                      child: Row(
                                        children: [

                                          Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: Colors.orange.withOpacity(.18),
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              icon,
                                              color: Colors.orangeAccent,
                                              size: 20,
                                            ),
                                          ),

                                          const SizedBox(width: 10),

                                          Expanded(
                                            child: Text(
                                              meta['value']?.toString() ?? '',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),

                                const SizedBox(height: 18),

                                /// CONTACT + ADDRESS + NOTE
                                ...metaData.where((e) {
                                  return [
                                    'contact',
                                    'address',
                                    'note',
                                  ].contains(e['key']);
                                }).map((meta) {

                                  final key = meta['key'];

                                  final icons = {
                                    'contact': Icons.phone_rounded,
                                    'address': Icons.location_on_rounded,
                                    'note': Icons.notes_rounded,
                                  };

                                  return Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(.04),
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [

                                        Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: Colors.orange.withOpacity(.12),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Icon(
                                            icons[key],
                                            color: Colors.orangeAccent,
                                            size: 18,
                                          ),
                                        ),

                                        const SizedBox(width: 12),

                                        Expanded(
                                          child: Text(
                                            meta['value']?.toString() ?? '',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              height: 1.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }),

                                if (description.isNotEmpty) ...[

                                  const SizedBox(height: 12),

                                  Container(
                                    height: 1,
                                    color: Colors.white.withOpacity(.08),
                                  ),

                                  const SizedBox(height: 14),

                                  Html(
                                    data: description,
                                    style: {
                                      "body": Style(
                                        fontSize: FontSize(15),
                                        color: Colors.white.withOpacity(.9),
                                        lineHeight: LineHeight(1.8),
                                        margin: Margins.zero,
                                        padding: HtmlPaddings.zero,
                                      ),
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),




                      const SizedBox(height: 32),
                      Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: isLoadingJoin
                              ? _buildShimmerButton()
                              : isJoined
                              ? Column(
                            key: const ValueKey("joined"),
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
  
  
                              // 🎯 ===== BUTTON QUAY =====
                              /*buildSpinButton(() {
                                if (_wheelKey.currentState?.isSpinning == true) return;
                                _openSpinDialog();
                              }),
  
                              const SizedBox(height: 20),*/
  
                              // 🎯 ===== ROW BUTTON =====
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
  
                                  // ===== CHAT =====
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(30),
                                      ),
                                    ),
                                    onPressed: () async {
                                      if (_currentUserId == null) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text("Chưa xác định được user")),
                                        );
                                        return;
                                      }
  
                                      final currentUser = await UserHelper.getCurrentUser();
                                      final username = currentUser["username"] ?? "Người dùng";

                                      final me = participants.firstWhere(
                                            (e) => e['user_id'] == _currentUserId,
                                        orElse: () => <String, Object>{},
                                      );
  
                                      final avatar = me['avatar'] ?? '';
  
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => GroupChatPage(
                                            username: username,
                                            userId: _currentUserId!,
                                            groupAvatar: avatar,
                                            groupId: inviteId!,
                                            groupName: widget.product['name'] ?? 'Nhóm',
                                          ),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.chat, color: Colors.white),
                                    label: Text(
                                      "Chat ($joinedCount)",
                                      style: const TextStyle(color: Colors.white),
                                    ),
                                  ),
  
                                  const SizedBox(width: 10),
  
                                  // ===== LEAVE =====
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(30),
                                      ),
                                    ),
                                    onPressed: () => _leaveInvite(inviteId!),
                                    icon: const Icon(Icons.cancel, color: Colors.white),
                                    label: const Text(
                                      "Rời phòng",
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          )
                              : (inviteStatus != 'open' || isFull)
                              ? ElevatedButton(
                            key: const ValueKey("closed"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey,
                              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                            onPressed: null,
                            child: Text(
                              inviteStatus != 'open' ? "Bàn đã đóng" : "Đã đủ người",
                              style: const TextStyle(color: Colors.white),
                            ),
                          )
                              : ElevatedButton.icon(
                            key: const ValueKey("join"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orangeAccent,
                              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                            onPressed: inviteId == null
                                ? null
                                : () => _joinInvite(inviteId!),
                            icon: const Icon(Icons.group_add, color: Colors.white),
                            label: const Text(
                              "Tham gia buổi nhậu",
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
  
                      const SizedBox(height: 40),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    void _openRatingSheet() {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) {
          return StatefulBuilder(
            builder: (context, setModalState) {
              return FractionallySizedBox(
                heightFactor: 0.65,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primaryBlue.withOpacity(0.95),
                        accentOrange.withOpacity(0.85),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                  ),
                  child: SafeArea(
                    child: Column(
                      children: [
                        const SizedBox(height: 10),

                        const Text(
                          "Đánh giá thành viên",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),

                        const SizedBox(height: 10),

                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: participants.length,
                            itemBuilder: (context, index) {
                              final p = participants[index];

                              final avatar = p['avatar'] ??
                                  "https://ui-avatars.com/api/?name=${p['name']}";

                              final isRated =
                                  p['is_rated'] == 1;

                              final myRating = p['my_rating'];

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.35),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundImage: NetworkImage(avatar),
                                    ),

                                    const SizedBox(width: 12),

                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            p['name'] ?? '',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),

                                          Text(
                                            "Uy tín: ${p['trust_score'] ?? 50}",
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(0.6),
                                              fontSize: 12,
                                            ),
                                          ),

                                          if (isRated)
                                            Text(
                                              myRating == 1
                                                  ? "Đã 👍 đánh giá"
                                                  : "Đã 👎 đánh giá",
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(0.4),
                                                fontSize: 11,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),

                                    Row(
                                      children: [
                                        _buildVoteButton(
                                          icon: Icons.thumb_up,
                                          color: Colors.green,
                                          disabled: isRated,
                                          active: isRated && myRating == 1,
                                          onTap: () async {
                                            await _rateUser(p['user_id'], 1);
                                            setModalState(() {}); // 🔥 FORCE UI UPDATE
                                          },
                                        ),

                                        const SizedBox(width: 6),

                                        _buildVoteButton(
                                          icon: Icons.thumb_down,
                                          color: Colors.red,
                                          disabled: isRated,
                                          active: isRated && myRating == -1,
                                          onTap: () async {
                                            await _rateUser(p['user_id'], -1);
                                            setModalState(() {}); // 🔥 FORCE UI UPDATE
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    }
    Widget _buildVoteButton({
      required IconData icon,
      required Color color,
      required bool disabled,
      required bool active,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: disabled ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? color.withOpacity(0.9)
                : color.withOpacity(0.15),
          ),
          child: Icon(
            icon,
            size: 16,
            color: active
                ? Colors.white
                : (disabled ? Colors.white24 : color),
          ),
        ),
      );
    }

    Future<void> _rateUser(int userId, int point) async {
      final token = await StorageHelper.read("jwt_token");

      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/rating/trust"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "user_id": userId,
          "point": point,
          "invite_id": inviteId,
        }),
      );

      final data = jsonDecode(res.body);

      if (data['success'] == true) {
        // 🔥 update local trước (UI đổi liền)
        setState(() {
          participants = participants.map((p) {
            if (p['user_id'] == userId) {
              return {
                ...p,
                'is_rated': 1,
                'my_rating': point,
              };
            }
            return p;
          }).toList();
        });

        // 🔥 sau đó sync lại server
        await _fetchParticipants(inviteId!);
        if (mounted) setState(() {}); // 🔥 đặt ở đây
      } else {
        debugPrint(data['message']);
      }
    }
  
    Future<void> _updateAttendance(String status) async {
      setState(() => isUpdatingAttendance = true);
  
      final token = await StorageHelper.read("jwt_token");
  
      try {
        final url = Uri.parse(
          '${AppConfig.webDomain}/wp-json/nhau/v1/invite/update-attendance',
        );
  
        final res = await http.post(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'invite_id': inviteId,
            'status': status,
          }),
        );
  
        final data = jsonDecode(res.body);
  
        /*if (data['success'] == true) {
          await _fetchParticipants(inviteId!);
  
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Đã cập nhật trạng thái')),
          );
        }*/
        if (data['success'] == true) {
          setState(() {
            final index = participants.indexWhere(
                  (p) => p['user_id'] == _currentUserId,
            );
  
            if (index != -1) {
              participants[index]['attendance_status'] = status;
            }
          });
  
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Đã cập nhật trạng thái')),
          );
        }else {
          throw Exception(data['message']);
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Lỗi cập nhật: $e')),
        );
      } finally {
        if (mounted) {
          setState(() => isUpdatingAttendance = false);
        }
      }
    }
  
    Future<Map<String, dynamic>> _spinWheelApi() async {
      final token = await StorageHelper.read("jwt_token");
  
      final res = await http.post(
        Uri.parse('${AppConfig.webDomain}/wp-json/spiritwebs/v1/spin'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'invite_id': inviteId}),
      );
  
      debugPrint("STATUS: ${res.statusCode}");
      debugPrint("HEADERS: ${res.headers}");
      debugPrint("BODY LENGTH: ${res.body.length}");
      debugPrint("RAW: ${res.body}");
  
      final data = jsonDecode(res.body);
  
      if (data == null) {
        throw Exception("API trả null");
      }
  
      if (data['success'] != true) {
        throw Exception(data['message'] ?? 'Spin failed');
      }
  
      if (data['result'] == null) {
        throw Exception("result = null từ server");
      }
  
      return data;
    }
  
  
  
    void _showSpinResult(String user, String action) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF1E3A8A).withOpacity(0.95), // primaryBlue
                    const Color(0xFFFF7F50).withOpacity(0.9),  // accentOrange
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 🎯 icon
                  const Icon(Icons.emoji_events, color: Colors.yellow, size: 48),
  
                  const SizedBox(height: 10),
  
                  const Text(
                    "KẾT QUẢ",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      letterSpacing: 1.2,
                    ),
                  ),
  
                  const SizedBox(height: 12),
  
                  // 👤 user
                  Text(
                    user,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
  
                  const SizedBox(height: 10),
  
                  // 🍻 action
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      action,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
  
                  const SizedBox(height: 20),
  
                  // 🔘 button
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                      padding:
                      const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      "OK",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }
  
    void _showAttendancePicker() {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.black87,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _attendanceItem('going', '🟢 Đã tới'),
              _attendanceItem('on_the_way', '🟡 Đang tới'),
              _attendanceItem('late', '🟠 Tới trễ'),
              _attendanceItem('not_going', '🔴 Không đi'),
              _attendanceItem('undecided', '⚪ Chưa xác nhận'),
            ],
          );
        },
      );
    }
  
    Widget _attendanceItem(String value, String label) {
      return ListTile(
        title: Text(label, style: const TextStyle(color: Colors.white)),
        onTap: () async {
          Navigator.pop(context);
          await _updateAttendance(value);
        },
      );
    }
    Widget buildSpinButton(VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xFFFF7F50), // cam
                Color(0xFFFF3D00), // đỏ cam
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.orangeAccent.withOpacity(0.6),
                blurRadius: 12,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.casino, color: Colors.white),
              SizedBox(width: 8),
              Text(
                "Quay trò chơi",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }
    void _openSpinDialog() {
      final GlobalKey<SpinWheelState> wheelKey = GlobalKey();
  
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return Dialog(
            backgroundColor: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    primaryBlue.withOpacity(0.95),
                    accentOrange.withOpacity(0.9),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "🎡 Vòng quay nhậu",
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
  
                  const SizedBox(height: 16),
  
                  SpinWheel(
                    key: wheelKey,
                    items: const [
                      "Uống 1 ly",
                      "Uống 2 ly",
                      "Chỉ định người khác",
                      "Cả bàn uống",
                    ],
                    onFinish: (index) {
                      Navigator.pop(context);
  
                      final result = _spinResult;
  
                      _showSpinResult(
                        result['user_name'] ?? '',
                        result['action'] ?? '',
                      );
                    },
                  ),
  
                  const SizedBox(height: 16),
  
                  ElevatedButton(
                    onPressed: () async {
                      if (wheelKey.currentState?.isSpinning == true) return;
  
                      // 🔥 1. quay UI ngay lập tức
                      wheelKey.currentState?.spinTo(0); // tạm quay fake trước
  
                      // 🔥 2. gọi API song song
                      final data = await _spinWheelApi();
  
                      if (data['result'] == null) return;
  
                      setState(() {
                        _spinResult = Map<String, dynamic>.from(data['result']);
                      });
  
                      final index = _spinResult['index'];
  
                      // 🔥 3. cập nhật lại đích sau
                      wheelKey.currentState?.spinTo(index);
                    },
                    child: const Text("Quay"),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }
  
    Future<void> _closeInvite(int inviteId) async {
      final token = await StorageHelper.read("jwt_token");
  
      try {
        final url = Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/invite/close');
  
        final res = await http.post(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'invite_id': inviteId}),
        );
  
        final data = jsonDecode(res.body);
  
        if (data['success'] == true) {
          await _fetchParticipants(inviteId);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Đã đóng bàn')),
          );
        }
      } catch (e) {
        debugPrint("❌ Close invite error: $e");
      }
    }
    Future<void> _openInvite(int inviteId) async {
      final token = await StorageHelper.read("jwt_token");
  
      try {
        final url = Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/invite/open');
  
        final res = await http.post(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'invite_id': inviteId}),
        );
  
        final data = jsonDecode(res.body);
  
        if (data['success'] == true) {
          await _fetchParticipants(inviteId);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Đã mở lại bàn')),
          );
        }
      } catch (e) {
        debugPrint("❌ Open invite error: $e");
      }
    }
  
  
    Widget buildAvatar(String? avatarUrl, String name) {
      return ClipOval(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [Colors.white.withOpacity(0.1), Colors.white.withOpacity(0.3)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
            ),
            Positioned.fill(
              child: Image.network(
                avatarUrl ?? '${AppConfig.webDomain}/media/2025/10/default-avatar.png',
                fit: BoxFit.cover,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  final progress = (loadingProgress.expectedTotalBytes != null)
                      ? loadingProgress.cumulativeBytesLoaded / (loadingProgress.expectedTotalBytes ?? 1)
                      : null;
                  return Opacity(opacity: 0.3 + (progress ?? 0) * 0.7, child: const Icon(Icons.person, size: 32, color: Colors.white54));
                },
                errorBuilder: (context, error, stackTrace) => const Icon(Icons.person, size: 32, color: Colors.white54),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.4), width: 1)),
              ),
            ),
          ],
        ),
      );
    }
  
    Widget _buildShimmerButton({
      double width = 180,
      double height = 48,
    }) {
      return shimmer.Shimmer.fromColors(
        baseColor: Colors.white.withOpacity(0.08),
        highlightColor: Colors.white.withOpacity(0.5),
        period: const Duration(milliseconds: 900),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(30),
          ),
        ),
      );
    }
    Widget _buildInviteStatusBadge() {
      String text = '';
      Color color = Colors.grey;
  
      if (inviteStatus != 'open') {
        text = "Đã đóng";
        color = Colors.redAccent;
      } else if (isFull) {
        text = "Đã đủ người";
        color = Colors.orangeAccent;
      } else {
        text = "Đang mở";
        color = Colors.green;
      }
  
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      );
    }
  
    Widget _buildAttendanceShimmer() {
      return shimmer.Shimmer.fromColors(
        baseColor: Colors.white.withOpacity(0.15),
        highlightColor: Colors.white.withOpacity(0.6),
        period: const Duration(milliseconds: 800),
        child: Container(
          width: 52,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
  
  
  
  }
  Widget chipButton({
    required String label,
    IconData? icon,
    required VoidCallback? onTap,
    List<Color>? colors,
  }) {
    final gradientColors = colors ?? [Colors.orange, Colors.redAccent];
  
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: gradientColors),
          borderRadius: BorderRadius.circular(12), // giống danh mục
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14, // giống danh mục
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  class ViewerIndicator extends StatefulWidget {
    final int viewerCount;

    const ViewerIndicator({super.key, required this.viewerCount});

    @override
    State<ViewerIndicator> createState() => _ViewerIndicatorState();
  }

  class _ViewerIndicatorState extends State<ViewerIndicator>
      with SingleTickerProviderStateMixin {
    late AnimationController _controller;

    @override
    void initState() {
      super.initState();
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      )..repeat(reverse: true);
    }

    @override
    void dispose() {
      _controller.dispose();
      super.dispose();
    }

    @override
    Widget build(BuildContext context) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Opacity(
                opacity: 0.3 + (_controller.value * 0.7),
                child: Icon(
                  Icons.remove_red_eye,
                  size: 16,
                  color: Colors.cyanAccent,
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  "${widget.viewerCount}",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  "đang xem",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
  }
  class FullScreenVideoPage extends StatefulWidget {
    final String videoUrl;

    const FullScreenVideoPage({
      super.key,
      required this.videoUrl,
    });

    @override
    State<FullScreenVideoPage> createState() =>
        _FullScreenVideoPageState();
  }

  class _FullScreenVideoPageState
      extends State<FullScreenVideoPage> {

    late VideoPlayerController controller;

    @override
    void initState() {
      super.initState();

      controller =
      VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
      )
        ..initialize().then((_) {
          setState(() {});
          controller.play();
        });
    }

    @override
    void dispose() {
      controller.dispose();
      super.dispose();
    }

    @override
    Widget build(BuildContext context) {

      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: controller.value.isInitialized
              ? AspectRatio(
            aspectRatio:
            controller.value.aspectRatio,
            child: VideoPlayer(controller),
          )
              : const CircularProgressIndicator(),
        ),
      );
    }
  }