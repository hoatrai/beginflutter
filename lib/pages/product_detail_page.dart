// =============================================================================
// product_detail_page.dart
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../helpers/storage_helper.dart';
import '../helpers/user_helper.dart';
import 'group_chat_page.dart';
import 'invite_map_page.dart';
import 'spin_wheel.dart';
import '../config/app_config.dart';
import '../app_globals.dart';

// =============================================================================
// CONSTANTS
// =============================================================================

abstract class _AppColors {
  static const primaryBlue   = Color(0xFF1E3A8A);
  static const accentOrange  = Color(0xFFFF7F50);
  static const surface       = Color(0x12FFFFFF);
  static const border        = Color(0x14FFFFFF);
}

abstract class _ApiUrls {
  static const base = '${AppConfig.webDomain}/wp-json/nhau/v1';
  static String inviteByProduct(int productId) =>
      '$base/invite/by-product?product_id=$productId';
  static String inviteDetail(int inviteId) =>
      '$base/invite/detail?invite_id=$inviteId';
  static String inviteMedia(int inviteId) =>
      '$base/invite/media?invite_id=$inviteId';
  static const inviteJoin        = '$base/invite/join';
  static const inviteLeave       = '$base/invite/leave';
  static const inviteClose       = '$base/invite/close';
  static const inviteOpen        = '$base/invite/open';
  static const inviteKick        = '$base/invite/kick';
  static const inviteMediaAdd    = '$base/invite/media/add';
  static const inviteMediaDelete = '$base/invite/media/delete';
  static const ratingTrust       = '$base/rating/trust';
  static const attendanceUpdate  = '$base/invite/update-attendance';
  static const imageUpload       = '${AppConfig.webDomain}/wp-json/nhau/v1/upload';
  static const profileUsers      = '${AppConfig.webDomain}/wp-json/profile/v1/users';
  static const spinWheel         = '${AppConfig.webDomain}/wp-json/spiritwebs/v1/spin';
  static const socketUrl         = AppConfig.websocketUrl;
  static const defaultAvatar     = '${AppConfig.webDomain}/media/2025/10/default-avatar.png';

  // 🆕 Upload video lên server riêng (giống create_invite_page) thay vì
  // Cloudinary — cùng endpoint REST WordPress + Application Password.
  static const videoUpload       = '${AppConfig.webDomain}/wp-json/nhau/v1/upload-video';
  static const wpUsername        = 'admin';
  static const wpAppPassword     = 'hWfZ33bkTXZGsuK18zFilY1D';
}

// =============================================================================
// DATA MODELS
// =============================================================================

enum AttendanceStatus { going, onTheWay, late, notGoing, undecided }

extension AttendanceStatusExt on AttendanceStatus {
  String get key {
    switch (this) {
      case AttendanceStatus.going:     return 'going';
      case AttendanceStatus.onTheWay:  return 'on_the_way';
      case AttendanceStatus.late:      return 'late';
      case AttendanceStatus.notGoing:  return 'not_going';
      case AttendanceStatus.undecided: return 'undecided';
    }
  }

  String get label {
    switch (this) {
      case AttendanceStatus.going:     return '🟢 Đã tới';
      case AttendanceStatus.onTheWay:  return '🟡 Đang tới';
      case AttendanceStatus.late:      return '🟠 Tới trễ';
      case AttendanceStatus.notGoing:  return '🔴 Không đi';
      case AttendanceStatus.undecided: return '⚪ Chưa xác nhận';
    }
  }

  String get shortLabel {
    switch (this) {
      case AttendanceStatus.going:     return 'Đã tới';
      case AttendanceStatus.onTheWay:  return 'Đang tới';
      case AttendanceStatus.late:      return 'Tới trễ';
      case AttendanceStatus.notGoing:  return 'Không đi';
      case AttendanceStatus.undecided: return 'Vừa join';
    }
  }

  Color get color {
    switch (this) {
      case AttendanceStatus.going:     return Colors.green;
      case AttendanceStatus.onTheWay:  return Colors.orange;
      case AttendanceStatus.late:      return Colors.deepOrange;
      case AttendanceStatus.notGoing:  return Colors.red;
      case AttendanceStatus.undecided: return Colors.blue;
    }
  }

  static AttendanceStatus fromKey(String? key) =>
      AttendanceStatus.values.firstWhere(
            (e) => e.key == key,
        orElse: () => AttendanceStatus.undecided,
      );
}

class Participant {
  final int userId;
  final String name;
  final String status;
  final String role;
  final AttendanceStatus attendanceStatus;
  final int trustScore;
  String? avatar;
  bool isRated;
  int? myRating;

  Participant({
    required this.userId,
    required this.name,
    required this.status,
    required this.role,
    required this.attendanceStatus,
    required this.trustScore,
    this.avatar,
    this.isRated = false,
    this.myRating,
  });

  factory Participant.fromMap(Map<String, dynamic> m) => Participant(
    userId:           int.tryParse(m['user_id']?.toString() ?? '') ?? 0,
    name:             m['display_name']?.toString() ?? '',
    status:           m['status']?.toString() ?? '',
    role:             m['role']?.toString() ?? '',
    attendanceStatus: AttendanceStatusExt.fromKey(m['attendance_status']?.toString()),
    trustScore:       int.tryParse(m['trust_score']?.toString() ?? '') ?? 50,
    isRated:          m['is_rated'] == 1,
    myRating:         m['my_rating'] != null ? int.tryParse(m['my_rating'].toString()) : null,
  );

  Participant copyWith({
    AttendanceStatus? attendanceStatus,
    bool? isRated,
    int? myRating,
    String? avatar,
  }) =>
      Participant(
        userId:           userId,
        name:             name,
        status:           status,
        role:             role,
        attendanceStatus: attendanceStatus ?? this.attendanceStatus,
        trustScore:       trustScore,
        avatar:           avatar ?? this.avatar,
        isRated:          isRated ?? this.isRated,
        myRating:         myRating ?? this.myRating,
      );
}

class MediaItem {
  final int id;
  final String url;
  final String type;
  final int? userId;

  const MediaItem({
    required this.id,
    required this.url,
    required this.type,
    this.userId,
  });

  bool get isVideo => type == 'video' || url.toLowerCase().contains('.mp4');

  factory MediaItem.fromMap(Map<String, dynamic> m) => MediaItem(
    id:     int.tryParse(m['id']?.toString() ?? '') ?? 0,
    url:    m['url']?.toString() ?? '',
    type:   m['type']?.toString() ?? 'image',
    userId: int.tryParse(m['user_id']?.toString() ?? ''),
  );
}

// 🆕 Media đang được chọn/nén/tải lên — hiển thị ngay (đẩy lên đầu danh sách)
// trước khi server trả URL thật, để user thấy phản hồi tức thì thay vì chờ.
class _PendingMedia {
  final File file;
  final String type; // 'image' | 'video'
  Uint8List? thumbnail;
  bool generatingThumb;
  double progress; // 0.0 - 1.0, chỉ dùng cho video
  bool uploading;
  bool error;

  _PendingMedia({
    required this.file,
    required this.type,
    this.thumbnail,
    this.generatingThumb = false,
    this.progress = 0.0,
    this.uploading = true,
    this.error = false,
  });
}

// =============================================================================
// WIDGET CHÍNH
// =============================================================================

class ProductDetailPage extends StatefulWidget {
  final Map<String, dynamic> product;
  final void Function(Map<String, dynamic> updatedProduct)? onJoin;
  // 🆕 Báo ngược ra trang danh sách (ShopPage) ngay khi 1 ảnh/video "khoảnh
  // khắc bàn nhậu" upload thành công, để card ngoài list cập nhật tức thì
  // mà không cần load lại toàn bộ danh sách sản phẩm.
  final void Function(String url, String type)? onMediaAdded;

  const ProductDetailPage({
    super.key,
    required this.product,
    this.onJoin,
    this.onMediaAdded,
  });

  @override
  State<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends State<ProductDetailPage>
    with SingleTickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────────────
  int _currentMediaIndex = 0;
  List<Participant> _participants = [];
  List<MediaItem> _inviteMedia = [];
  final List<_PendingMedia> _pendingMedia = []; // 🆕 upload đang chạy, hiển thị optimistic

  // 🆕 Cache thumbnail cho video ĐÃ được server confirm (trong _inviteMedia).
  // Key theo item.id — mỗi video có id riêng nên video thêm SAU không bao
  // giờ vô tình hiện lại ảnh thumbnail của video thêm TRƯỚC.
  final Map<int, Uint8List?> _confirmedVideoThumbCache = {};

  bool _isLoadingJoin          = false;
  bool _isUploadingMedia       = false;
  bool _isUpdatingAttendance   = false;
  bool _isUpdatingInviteStatus = false;
  // 🔧 FIX: theo dõi danh sách URL video đã init lần gần nhất, thay cho cờ
  // boolean cũ chỉ cho phép init MỘT LẦN trong suốt vòng đời State.
  List<String> _initedVideoUrls = [];

  bool isJoined    = false;
  bool isHost      = false;
  bool isFull      = false;
  bool allowRating = false;

  int? _currentUserId;
  String? _currentUserName;
  int? inviteId;
  int joinedCount = 0;
  int maxPeople   = 0;
  int viewerCount = 0;

  String? inviteStatus;

  // ── Video ──────────────────────────────────────────────────────────────────
  // key = index in the carousel mediaList
  final Map<int, VideoPlayerController> _videoMap = {};
  Map<String, dynamic> _spinResult = {};

  // ── Story-style carousel controller ─────────────────────────────────────────
  final StoryProgressController _storyController = StoryProgressController();

  // ── WebSocket ──────────────────────────────────────────────────────────────
  late WebSocketChannel _channel;
  Timer? _heartbeatTimer;
  bool _socketJoined = false;

  // ── Animation (join button pulse) ──────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ── Carousel page controller ───────────────────────────────────────────────
  final PageController _pageController = PageController();

  bool get canJoin => inviteStatus == 'open' && !isFull;

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  @override
  void initState() {
    super.initState();
    _initAnimation();
    _connectSocket();
    _loadUserId();
    _loadJoinStatus();
  }

  void _initAnimation() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    if (currentInviteId == inviteId) {
      isInviteDetailOpen = false;
      currentInviteId = null;
    }
    _heartbeatTimer?.cancel();
    _channel.sink.close();
    _pulseController.dispose();
    _pageController.dispose();
    for (final c in _videoMap.values) c.dispose();
    _videoMap.clear();
    VideoCompress.deleteAllCache();
    super.dispose();
  }

  // ==========================================================================
  // VIDEO — initialise & control
  // ==========================================================================

  /// Khởi tạo lại toàn bộ video của carousel.
  /// 🔧 FIX: trước đây hàm này chỉ được gọi MỘT LẦN nhờ cờ `_videoInited`,
  /// nên nếu sản phẩm được sửa sau đó (danh sách video/ảnh trong
  /// `widget.product` thay đổi — ví dụ user edit lại bài đăng) thì carousel
  /// vẫn tiếp tục phát video CŨ vì `_videoMap` không được dispose/tạo lại.
  /// Giờ hàm này được gọi lại bất cứ khi nào danh sách URL video thực sự
  /// đổi (xem chỗ gọi trong `build()`), và luôn dispose sạch controller cũ
  /// trước khi tạo controller mới để không bị lẫn video của lần load trước.
  void _initVideos(List<Map<String, dynamic>> mediaList) {
    for (final c in _videoMap.values) {
      c.dispose();
    }
    _videoMap.clear();

    for (int i = 0; i < mediaList.length; i++) {
      final item = mediaList[i];
      if (item['type'] != 'video') continue;

      final ctrl =
      VideoPlayerController.networkUrl(Uri.parse(item['url'] as String));
      _videoMap[i] = ctrl;

      ctrl.initialize().then((_) {
        if (!mounted) return;
        ctrl.setLooping(true);
        ctrl.setVolume(1.0);
        // Auto-play only the first video
        if (i == 0 && _currentMediaIndex == 0) ctrl.play();
        setState(() {});
      });
    }
  }

  /// When the carousel page changes: pause all except the active one.
  void _onPageChanged(int index) {
    setState(() => _currentMediaIndex = index);
    _videoMap.forEach((i, ctrl) {
      if (!ctrl.value.isInitialized) return;
      if (i == index) {
        ctrl.play();
      } else {
        ctrl.pause();
        ctrl.seekTo(Duration.zero);
      }
    });
  }

  // ==========================================================================
  // WEBSOCKET
  // ==========================================================================

  void _connectSocket() {
    _channel = WebSocketChannel.connect(Uri.parse(_ApiUrls.socketUrl));
    _channel.sink.add(jsonEncode({
      'topic': 'phoenix',
      'event': 'phx_join',
      'payload': {},
      'ref': '1',
    }));
    _channel.stream.listen(_handleSocketMessage, onError: (e) {
      debugPrint('❌ Socket error: $e');
    });
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _channel.sink.add(jsonEncode({
        'topic': 'phoenix',
        'event': 'heartbeat',
        'payload': {},
        'ref': _nowRef(),
      }));
    });
  }

  Future<void> _handleSocketMessage(dynamic message) async {
    try {
      final decoded = jsonDecode(message as String) as Map<String, dynamic>;
      final event   = decoded['event'] as String?;
      final payload = decoded['payload'] as Map<String, dynamic>? ?? {};

      if (event == 'phx_reply' &&
          decoded['topic'] == 'phoenix' &&
          !_socketJoined) {
        _socketJoined = true;
        if (inviteId != null) _joinInviteRoom(inviteId!);
        return;
      }

      if (event == 'viewer_count') {
        if (!mounted) return;
        setState(() => viewerCount = (payload['count'] as int?) ?? 0);
        return;
      }

      const reloadEvents = {
        'user_joined', 'user_left', 'user_kicked',
        'invite_closed', 'invite_opened', 'attendance_updated',
      };
      if (reloadEvents.contains(event) && payload['invite_id'] == inviteId) {
        await _fetchParticipants(inviteId!);
        if (mounted) _showInviteNotification(event!, payload);
      }
    } catch (e) {
      debugPrint('❌ Socket parse error: $e');
    }
  }

  Future<void> _joinInviteRoom(int id) async {
    final userId = await StorageHelper.read('user_id');
    _channel.sink.add(jsonEncode({
      'topic':    'invite:$id',
      'event':    'phx_join',
      'payload':  {'user_id': userId?.toString()},
      'ref':      _nowRef(),
      'join_ref': _nowRef(),
    }));
  }

  String _nowRef() => DateTime.now().millisecondsSinceEpoch.toString();

  /// Bắn một event lên topic "invite:$inviteId" để các client khác đang
  /// mở cùng invite này nhận được realtime (server sẽ broadcast_from!,
  /// nghĩa là chính máy mình sẽ KHÔNG nhận lại event của chính mình).
  void _pushInviteEvent(String event, Map<String, dynamic> payload) {
    if (inviteId == null) return;
    _channel.sink.add(jsonEncode({
      'topic':   'invite:$inviteId',
      'event':   event,
      'payload': {...payload, 'invite_id': inviteId},
      'ref':     _nowRef(),
    }));
  }

  /// Hiện snackbar thông báo khi nhận được event từ người khác trong nhóm.
  void _showInviteNotification(String event, Map<String, dynamic> payload) {
    final name = payload['user_name']?.toString() ?? 'Ai đó';
    String? msg;
    switch (event) {
      case 'user_joined':
        msg = '🙋 $name vừa tham gia bàn nhậu';
        break;
      case 'user_left':
        msg = '🚪 $name đã rời bàn';
        break;
      case 'user_kicked':
        msg = '⛔ $name đã bị mời ra khỏi bàn';
        break;
      case 'invite_closed':
        msg = '🔒 Chủ phòng đã đóng bàn';
        break;
      case 'invite_opened':
        msg = '🔓 Chủ phòng đã mở lại bàn';
        break;
      case 'attendance_updated':
        final status = AttendanceStatusExt.fromKey(payload['status']?.toString());
        msg = '📍 $name: ${status.label}';
        break;
    }
    if (msg != null) _showSnack(msg);
  }

  // ==========================================================================
  // API — AUTH
  // ==========================================================================

  Future<Map<String, String>> _authHeaders() async {
    final token = await StorageHelper.read('jwt_token');
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  // ==========================================================================
  // API — LOAD DATA
  // ==========================================================================

  Future<void> _loadUserId() async {
    final id = await StorageHelper.read('user_id');
    if (!mounted) return;
    setState(() {
      _currentUserId = id != null ? int.tryParse(id.toString()) : null;
    });
    try {
      final currentUser = await UserHelper.getCurrentUser();
      if (!mounted) return;
      setState(() {
        _currentUserName = (currentUser['username'] as String?) ?? 'Ai đó';
      });
    } catch (e) {
      debugPrint('⚠️ _loadUserId (username): $e');
    }
  }

  Future<void> _loadJoinStatus() async {
    if (!mounted) return;
    setState(() => _isLoadingJoin = true);
    try {
      final productId = int.parse(widget.product['id'].toString());
      final id = await _fetchInviteIdByProduct(productId);
      if (id != null && mounted) {
        setState(() => inviteId = id);
        isInviteDetailOpen = true;
        currentInviteId = id;
        if (_socketJoined) _joinInviteRoom(id);
        await Future.wait([_fetchInviteMedia(), _fetchParticipants(id)]);
      }
    } catch (e) {
      debugPrint('❌ _loadJoinStatus: $e');
    } finally {
      if (mounted) setState(() => _isLoadingJoin = false);
    }
  }

  Future<int?> _fetchInviteIdByProduct(int productId) async {
    try {
      final res = await http.get(
        Uri.parse(_ApiUrls.inviteByProduct(productId)),
        headers: await _authHeaders(),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          return int.tryParse(data['invite_id'].toString());
        }
      }
    } catch (e) {
      debugPrint('❌ _fetchInviteIdByProduct: $e');
    }
    return null;
  }

  Future<void> _fetchParticipants(int id) async {
    try {
      final res = await http.get(
        Uri.parse(_ApiUrls.inviteDetail(id)),
        headers: await _authHeaders(),
      );
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] != true) return;

      final invite = data['invite'] as Map<String, dynamic>;
      final parsed = (data['members'] as List? ?? [])
          .map((m) => Participant.fromMap(m as Map<String, dynamic>))
          .toList();

      await _enrichWithAvatars(parsed);
      if (!mounted) return;

      setState(() {
        inviteId     = int.tryParse(invite['id'].toString()) ?? inviteId;
        isJoined     = data['is_joined'] ?? false;
        isHost       = data['is_host'] ?? false;
        isFull       = data['is_full'] ?? false;
        joinedCount  = int.tryParse(data['joined_count'].toString()) ?? 0;
        inviteStatus = invite['status']?.toString() ?? 'open';
        maxPeople    = int.tryParse(invite['max_people'].toString()) ?? 0;
        allowRating  = inviteStatus == 'closed';
        _participants = parsed;
      });

      widget.onJoin?.call({
        'id': widget.product['id'],
        'joined_count': joinedCount,
      });
    } catch (e) {
      debugPrint('❌ _fetchParticipants: $e');
    }
  }

  Future<void> _enrichWithAvatars(List<Participant> list) async {
    if (list.isEmpty) return;
    try {
      final res = await http.post(
        Uri.parse(_ApiUrls.profileUsers),
        headers: await _authHeaders(),
        body: jsonEncode({'ids': list.map((p) => p.userId).toList()}),
      );
      if (res.statusCode != 200) return;
      final data  = jsonDecode(res.body) as Map<String, dynamic>;
      final users = data['users'] as List? ?? [];
      final map   = <int, String>{
        for (final u in users.cast<Map<String, dynamic>>())
          (u['user_id'] as int): u['avatar_url']?.toString() ?? _ApiUrls.defaultAvatar,
      };
      for (final p in list) {
        p.avatar = map[p.userId] ?? _ApiUrls.defaultAvatar;
      }
    } catch (e) {
      debugPrint('⚠️ _enrichWithAvatars: $e');
    }
  }

  Future<void> _fetchInviteMedia() async {
    if (inviteId == null) return;
    try {
      final res  = await http.get(Uri.parse(_ApiUrls.inviteMedia(inviteId!)));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true && mounted) {
        setState(() {
          _inviteMedia = (data['items'] as List? ?? [])
              .map((m) => MediaItem.fromMap(m as Map<String, dynamic>))
              .toList();
        });
      }
    } catch (e) {
      debugPrint('❌ _fetchInviteMedia: $e');
    }
  }

  /// 🆕 Sinh thumbnail thật cho video đã upload xong (server confirm), để
  /// mục "Khoảnh khắc bàn nhậu" hiện ảnh thay vì chỉ ô đen + icon play.
  /// Cache theo `item.id` — KHÔNG dùng biến/field dùng chung — nên video
  /// được thêm sau luôn hiện đúng ảnh của chính nó, không bị lẫn với ảnh
  /// của video thêm trước đó.
  Future<Uint8List?> _getConfirmedVideoThumb(MediaItem item) async {
    if (_confirmedVideoThumbCache.containsKey(item.id)) {
      return _confirmedVideoThumbCache[item.id];
    }
    try {
      final thumb = await VideoThumbnail.thumbnailData(
        video: item.url,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 200,
        quality: 40,
      );
      _confirmedVideoThumbCache[item.id] = thumb;
      return thumb;
    } catch (e) {
      debugPrint('⚠️ _getConfirmedVideoThumb: $e');
      _confirmedVideoThumbCache[item.id] = null;
      return null;
    }
  }

  // ==========================================================================
  // API — ACTIONS
  // ==========================================================================

  Future<void> _joinInvite() async {
    if (!canJoin || inviteId == null) {
      _showSnack('Không thể tham gia kèo này');
      return;
    }
    setState(() => _isLoadingJoin = true);
    try {
      final res = await http.post(
        Uri.parse(_ApiUrls.inviteJoin),
        headers: await _authHeaders(),
        body: jsonEncode({'invite_id': inviteId}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] != true) throw Exception(data['message']);
      await _fetchParticipants(inviteId!);
      _pushInviteEvent('user_joined', {'user_name': _currentUserName});
      _showSnack('Bạn đã tham gia thành công! 🎉');
    } catch (e) {
      _showSnack('Không thể tham gia: $e');
    } finally {
      if (mounted) setState(() => _isLoadingJoin = false);
    }
  }

  Future<void> _leaveInvite() async {
    if (inviteId == null) return;

    // Chủ phòng không được rời
    if (isHost) {
      await showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E3A8A), Color(0xFF2D1B69)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 30),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.orangeAccent.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_rounded,
                      color: Colors.orangeAccent, size: 30),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Chủ phòng không thể rời',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Text(
                  'Bạn là 👑 chủ phòng.\nHãy đóng bàn hoặc nhường quyền cho thành viên khác trước khi rời.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.65),
                      fontSize: 13,
                      height: 1.6),
                ),
                const SizedBox(height: 22),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withOpacity(0.15)),
                    ),
                    child: const Text(
                      'Đã hiểu',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return;
    }

    setState(() => _isLoadingJoin = true);
    try {
      final res = await http.post(
        Uri.parse(_ApiUrls.inviteLeave),
        headers: await _authHeaders(),
        body: jsonEncode({'invite_id': inviteId}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] != true) throw Exception(data['message']);
      await _fetchParticipants(inviteId!);
      _pushInviteEvent('user_left', {'user_name': _currentUserName});
      _showSnack('Đã rời phòng');
    } catch (e) {
      _showSnack('Không thể rời phòng: $e');
    } finally {
      if (mounted) setState(() => _isLoadingJoin = false);
    }
  }

  Future<void> _kickUser(int targetUserId) async {
    if (inviteId == null) return;
    final target = _participants.firstWhere(
          (p) => p.userId == targetUserId,
      orElse: () => Participant(
        userId: 0, name: 'Thành viên', status: '', role: '',
        attendanceStatus: AttendanceStatus.undecided,
        trustScore: 50,
      ),
    );
    try {
      final res = await http.post(
        Uri.parse(_ApiUrls.inviteKick),
        headers: await _authHeaders(),
        body: jsonEncode({'invite_id': inviteId, 'user_id': targetUserId}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] != true) throw Exception(data['message']);
      await _fetchParticipants(inviteId!);
      _pushInviteEvent('user_kicked', {
        'user_name': target.name,
        'target_user_id': targetUserId,
      });
      _showSnack('Đã kick thành viên');
    } catch (e) {
      _showSnack('Không thể kick: $e');
    }
  }

  Future<void> _toggleInviteStatus() async {
    if (inviteId == null) return;
    setState(() => _isUpdatingInviteStatus = true);
    try {
      final wasOpen = inviteStatus == 'open';
      final url = wasOpen ? _ApiUrls.inviteClose : _ApiUrls.inviteOpen;
      final res = await http.post(
        Uri.parse(url),
        headers: await _authHeaders(),
        body: jsonEncode({'invite_id': inviteId}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        await _fetchParticipants(inviteId!);
        _pushInviteEvent(wasOpen ? 'invite_closed' : 'invite_opened', {});
        _showSnack(wasOpen ? 'Đã đóng bàn' : 'Đã mở lại bàn');
      }
    } catch (e) {
      debugPrint('❌ _toggleInviteStatus: $e');
    } finally {
      if (mounted) setState(() => _isUpdatingInviteStatus = false);
    }
  }

  Future<void> _updateAttendance(AttendanceStatus status) async {
    if (inviteId == null) return;
    setState(() => _isUpdatingAttendance = true);
    try {
      final res = await http.post(
        Uri.parse(_ApiUrls.attendanceUpdate),
        headers: await _authHeaders(),
        body: jsonEncode({'invite_id': inviteId, 'status': status.key}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        setState(() {
          final idx = _participants.indexWhere((p) => p.userId == _currentUserId);
          if (idx != -1) {
            _participants[idx] =
                _participants[idx].copyWith(attendanceStatus: status);
          }
        });
        _pushInviteEvent('attendance_updated', {
          'user_name': _currentUserName,
          'status': status.key,
        });
        _showSnack('✅ Đã cập nhật trạng thái');
      } else {
        throw Exception(data['message']);
      }
    } catch (e) {
      _showSnack('❌ Lỗi cập nhật: $e');
    } finally {
      if (mounted) setState(() => _isUpdatingAttendance = false);
    }
  }

  Future<void> _rateUser(int userId, int point) async {
    try {
      final res = await http.post(
        Uri.parse(_ApiUrls.ratingTrust),
        headers: await _authHeaders(),
        body: jsonEncode(
            {'user_id': userId, 'point': point, 'invite_id': inviteId}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        setState(() {
          _participants = _participants.map((p) {
            if (p.userId == userId) return p.copyWith(isRated: true, myRating: point);
            return p;
          }).toList();
        });
        await _fetchParticipants(inviteId!);
      } else {
        _showSnack('❌ ${data['message'] ?? 'Đánh giá thất bại'}');
      }
    } catch (e) {
      debugPrint('❌ _rateUser: $e');
      _showSnack('❌ Lỗi kết nối, thử lại sau');
    }
  }

  // ==========================================================================
  // API — MEDIA UPLOAD
  // ==========================================================================

  Future<void> _pickAndUpload(String type) async {
    final picker = ImagePicker();
    final file = type == 'video'
        ? await picker.pickVideo(source: ImageSource.gallery)
        : await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null) return;

    // 🆕 Đẩy ngay item lên ĐẦU danh sách hiển thị (trước cả _inviteMedia đã
    // có) để user thấy media của mình xuất hiện tức thì, không cần đợi
    // upload + fetch lại từ server.
    final pending = _PendingMedia(
      file: File(file.path),
      type: type,
      generatingThumb: type == 'video',
    );
    setState(() => _pendingMedia.insert(0, pending));

    if (type == 'video') {
      final thumb = await VideoThumbnail.thumbnailData(
        video: pending.file.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 200,
        quality: 25,
      );
      if (!mounted) return;
      setState(() {
        pending.thumbnail = thumb;
        pending.generatingThumb = false;
      });
    }

    await _uploadMedia(pending);
  }

  Future<void> _uploadMedia(_PendingMedia pending) async {
    final type = pending.type;
    setState(() => _isUploadingMedia = true);
    try {
      final headers = await _authHeaders();
      String mediaUrl;

      if (type == 'video') {
        // 🆕 Nén video trước khi upload để giảm tải server và tăng tốc độ
        // gửi. Nếu nén lỗi, fallback dùng file gốc để không chặn user.
        File fileToUpload = pending.file;
        try {
          final info = await VideoCompress.compressVideo(
            fileToUpload.path,
            quality: VideoQuality.MediumQuality,
            deleteOrigin: false,
            includeAudio: true,
          );
          if (info?.file != null) fileToUpload = info!.file!;
        } catch (_) {
          // nén thất bại -> vẫn upload file gốc
        }
        mediaUrl = await _uploadVideoToOwnServer(
          fileToUpload,
          onProgress: (p) {
            if (!mounted) return;
            setState(() => pending.progress = p);
          },
        );
      } else {
        final req =
        http.MultipartRequest('POST', Uri.parse(_ApiUrls.imageUpload))
          ..headers.addAll({'Authorization': headers['Authorization']!})
          ..files
              .add(await http.MultipartFile.fromPath('file', pending.file.path));
        final res  = await http.Response.fromStream(await req.send());
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['success'] != true) {
          throw Exception(data['message'] ?? 'Upload ảnh thất bại');
        }
        mediaUrl = data['url'] as String;
      }

      final res = await http.post(
        Uri.parse(_ApiUrls.inviteMediaAdd),
        headers: headers,
        body: jsonEncode(
            {'invite_id': inviteId, 'type': type, 'url': mediaUrl}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] != true) {
        throw Exception(data['message'] ?? 'Không lưu được media');
      }
      await _fetchInviteMedia();
      // 🆕 Báo ngược ra ShopPage (nếu có) để card ngoài list hiện video/ảnh
      // mới này ngay, không cần đợi user quay lại rồi pull-to-refresh.
      widget.onMediaAdded?.call(mediaUrl, type);
      if (mounted) setState(() => _pendingMedia.remove(pending));
      _showSnack(type == 'video' ? '🎥 Video đã đăng' : '📸 Ảnh đã đăng');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        pending.uploading = false;
        pending.error = true;
      });
      // 🆕 Hiện rõ lỗi thật ngay trên thumbnail (icon lỗi + nút xóa) thay vì
      // chỉ báo snack rồi làm item biến mất im lặng.
      _showSnack('❌ $e');
    } finally {
      if (mounted) {
        setState(() => _isUploadingMedia = _pendingMedia.any((p) => p.uploading));
      }
    }
  }

  // ─── UPLOAD VIDEO LÊN SERVER RIÊNG (thay cho Cloudinary) ────────────────────
  // Cùng endpoint/cách xác thực với create_invite_page: multipart tới REST
  // endpoint WordPress tự viết, xác thực bằng Application Password.
  Future<String> _uploadVideoToOwnServer(
      File videoFile, {
        void Function(double progress)? onProgress,
      }) async {
    final uri = Uri.parse(_ApiUrls.videoUpload);
    final credentials = base64Encode(
        utf8.encode('${_ApiUrls.wpUsername}:${_ApiUrls.wpAppPassword}'));

    final multipart = http.MultipartRequest('POST', uri);
    multipart.headers['Authorization'] = 'Basic $credentials';
    multipart.files.add(await http.MultipartFile.fromPath('file', videoFile.path));

    final totalBytes = multipart.contentLength;
    int bytesSent = 0;

    // Bọc byte stream gốc để đếm số byte đã gửi đi, từ đó tính % tiến trình
    final trackedStream = multipart.finalize().transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          bytesSent += chunk.length;
          if (totalBytes > 0) onProgress?.call((bytesSent / totalBytes).clamp(0.0, 1.0));
          sink.add(chunk);
        },
      ),
    );

    // http.MultipartRequest không cho hook progress trực tiếp nên phải dựng
    // lại thành StreamedRequest với cùng headers/contentLength.
    final streamedRequest = http.StreamedRequest('POST', uri);
    streamedRequest.headers.addAll(multipart.headers);
    streamedRequest.contentLength = totalBytes;

    trackedStream.listen(
      streamedRequest.sink.add,
      onDone: () => streamedRequest.sink.close(),
      onError: (e, st) => streamedRequest.sink.addError(e, st),
      cancelOnError: true,
    );

    final response = await http.Client().send(streamedRequest);
    final resBody = await response.stream.bytesToString();

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(resBody);
      final String? videoUrl = data['url'];
      if (videoUrl == null) throw Exception('Không nhận được URL video từ server');
      return videoUrl;
    }
    throw Exception('Upload video failed (${response.statusCode}): $resBody');
  }

  Future<void> _deleteMedia(int mediaId) async {
    try {
      final res = await http.post(
        Uri.parse(_ApiUrls.inviteMediaDelete),
        headers: await _authHeaders(),
        body: jsonEncode({'media_id': mediaId}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true) await _fetchInviteMedia();
    } catch (e) {
      debugPrint('❌ _deleteMedia: $e');
    }
  }

  // ==========================================================================
  // API — SPIN WHEEL
  // ==========================================================================

  Future<Map<String, dynamic>> _callSpinWheelApi() async {
    final res = await http.post(
      Uri.parse(_ApiUrls.spinWheel),
      headers: await _authHeaders(),
      body: jsonEncode({'invite_id': inviteId}),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['success'] != true) throw Exception(data['message'] ?? 'Spin failed');
    if (data['result'] == null) throw Exception('result = null từ server');
    return data;
  }

  // ==========================================================================
  // HELPERS
  // ==========================================================================

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _priceText(String? priceRange) {
    switch (priceRange) {
      case null:
      case '':
      case '0':
        return 'Miễn phí';
      case '50-100':  return '50k – 100k';
      case '100-200': return '100k – 200k';
      case '200-500': return '200k – 500k';
      case '500+':    return '500k+';
      default:        return priceRange!;
    }
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    final product     = widget.product;
    final name        = product['name']?.toString() ?? '';
    final description = product['description']?.toString() ?? '';
    final images      = product['images'] as List<dynamic>? ?? [];
    final metaData    = product['meta_data'] as List<dynamic>? ?? [];

    // Parse video URLs from meta
    List<String> videoUrls = [];
    for (final item in metaData) {
      if (item['key'] == 'videos') {
        final raw = item['value'];
        if (raw != null && raw.toString().isNotEmpty) {
          try {
            final decoded = jsonDecode(raw.toString());
            videoUrls = decoded is String
                ? List<String>.from(jsonDecode(decoded) as List)
                : List<String>.from(decoded as List);
          } catch (_) {}
        }
      }
    }

    final mediaList = [
      ...videoUrls.map((url) => {'type': 'video', 'url': url}),
      ...images.map((e) => {'type': 'image', 'url': (e as Map)['src']}),
    ];

    // 🔧 FIX: so sánh danh sách URL video hiện tại với lần init trước, thay
    // vì dùng cờ `_videoInited` chỉ chạy một lần. Nếu sản phẩm được sửa sau
    // (videoUrls đổi), ta re-init lại carousel; nếu không đổi thì bỏ qua để
    // tránh dispose/tạo lại controller không cần thiết mỗi lần rebuild.
    if (!listEquals(_initedVideoUrls, videoUrls)) {
      _initedVideoUrls = List<String>.from(videoUrls);
      WidgetsBinding.instance.addPostFrameCallback((_) => _initVideos(mediaList));
    }

    String? priceRange;
    for (final item in metaData) {
      if (item['key'] == 'price_range') {
        priceRange = item['value']?.toString();
        break;
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1E3A8A), // thay vì Colors.transparent
      body: _GradientBackground(
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              // ── Collapsible carousel SliverAppBar ───────────────────────
              SliverAppBar(
                pinned: true,
                expandedHeight: 300,
                backgroundColor: Colors.transparent,
                elevation: 0,
                automaticallyImplyLeading: false,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  background: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _buildMediaCarousel(mediaList),
                  ),
                ),
                // Back button always visible when pinned
                leading: _backButton(),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12, top: 8),
                    child: ViewerIndicator(viewerCount: viewerCount),
                  ),
                ],
              ),

              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 14),

                      // ── Title & price BELOW the carousel ────────────────
                      _buildHeaderRow(name, _priceText(priceRange)),
                      const SizedBox(height: 16),

                      _buildParticipantsSection(),
                      const SizedBox(height: 16),
                      _buildMediaSection(),
                      const SizedBox(height: 16),
                      _buildActionRow(),
                      const SizedBox(height: 16),
                      _buildInfoCard(metaData, description),
                      const SizedBox(height: 32),
                      _buildJoinButton(),
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // BACK BUTTON
  // ==========================================================================

  Widget _backButton() => IconButton(
    icon: Container(
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(
        color: Colors.black26,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.arrow_back_ios_new,
          color: Colors.white, size: 18),
    ),
    onPressed: () => Navigator.pop(context),
  );

  // ==========================================================================
  // MEDIA CAROUSEL — swipeable, real video player with controls
  // ==========================================================================

  Widget _buildMediaCarousel(List<Map<String, dynamic>> mediaList) {
    if (mediaList.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 280,
          color: Colors.black26,
          child: const Center(
            child: Icon(Icons.image_not_supported,
                color: Colors.white38, size: 48),
          ),
        ),
      );
    }

    // ── Carousel kiểu "story": auto-play ảnh + progress bar,
    //    double-tap để thả tim ─────────────────────────────────────────────
    return DoubleTapReaction(
      onDoubleTap: () {
        // Chỉ hiệu ứng thị giác. Nếu sau này có endpoint "like invite"
        // thì gọi API ở đây.
      },
      child: StoryProgressCarousel(
        controller: _storyController,
        itemCount: mediaList.length,
        height: 300,
        borderRadius: BorderRadius.circular(20),
        isVideo: (i) => mediaList[i]['type'] == 'video',
        onIndexChanged: _onPageChanged,
        itemBuilder: (_, i) {
          final item = mediaList[i];
          return item['type'] == 'video'
              ? _buildVideoSlide(item['url'] as String, i)
              : _buildImageSlide(item['url'] as String, index: i);
        },
      ),
    );
  }

  Widget _buildImageSlide(String url, {int index = 0}) {
    final img = CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      width: double.infinity,
      placeholder: (_, __) => _shimmerBox(height: 300),
      errorWidget: (_, __, ___) => Container(
        color: Colors.black26,
        child: const Center(
            child: Icon(Icons.broken_image, color: Colors.white38, size: 40)),
      ),
    );

    // Ảnh đầu tiên dùng Hero để bay mượt từ ShopPage sang đây
    // (nhớ dùng CÙNG tag ở widget ảnh trong list của ShopPage).
    if (index == 0) {
      return Hero(
        tag: 'product-image-${widget.product["id"]}',
        child: img,
      );
    }
    return img;
  }

  Widget _buildVideoSlide(String url, int index) {
    final ctrl = _videoMap[index];
    if (ctrl == null || !ctrl.value.isInitialized) {
      return _shimmerBox(height: 300);
    }
    return _VideoSlide(controller: ctrl);
  }

  // ==========================================================================
  // HEADER — title + price + status badge
  // ==========================================================================

  Widget _buildHeaderRow(String name, String price) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: _AppColors.accentOrange.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  price,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _buildInviteStatusBadge(),
      ],
    );
  }

  Widget _buildInviteStatusBadge() {
    // Chưa load xong → không hiện badge
    if (_isLoadingJoin && inviteStatus == null) return const SizedBox.shrink();

    final isOpen   = inviteStatus == 'open';
    final isClosed = inviteStatus != null && !isOpen;

    if (isClosed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
          ],
        ),
        child: const Text('Đã đóng',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      );
    }

    if (isFull) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withOpacity(0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
          ],
        ),
        child: const Text('Đã đủ người',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      );
    }

    // Đang mở → pulse animation
    return ScaleTransition(
      scale: _pulseAnimation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.9),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.green.withOpacity(0.4),
              blurRadius: 8,
              spreadRadius: 1,
              offset: const Offset(0, 2),
            )
          ],
        ),
        child: const Text('Đang mở',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      ),
    );
  }

  // ==========================================================================
  // PARTICIPANTS SECTION
  // ==========================================================================

  Widget _buildParticipantsSection() {
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '👥 Thành viên ($joinedCount/$maxPeople)',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (allowRating)
                _TinyButton(
                  label: 'Đánh giá',
                  icon: Icons.star,
                  color: Colors.blueAccent,
                  onTap: _openRatingSheet,
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_isLoadingJoin)
            _shimmerParticipants()
          else if (_participants.isEmpty)
            const Center(
              child: Text('Chưa có thành viên',
                  style: TextStyle(color: Colors.white54)),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _participants.map((p) {
                  final isMe    = p.userId == _currentUserId;
                  final canKick = isHost && !isMe;
                  return Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: _ParticipantCard(
                      participant: p,
                      isMe: isMe,
                      canKick: canKick,
                      isUpdatingAttendance: isMe && _isUpdatingAttendance,
                      onAttendanceTap: isMe ? _showAttendancePicker : null,
                      onKick: () => _kickUser(p.userId),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  // ==========================================================================
  // MEDIA SECTION (uploaded moments)
  // ==========================================================================

  Widget _buildMediaSection() {
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '📸 Khoảnh khắc bàn nhậu',
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (isHost || isJoined)
                GestureDetector(
                  onTap: _showMediaPicker,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.orangeAccent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.add,
                        color: Colors.orangeAccent, size: 20),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          (_pendingMedia.isEmpty && _inviteMedia.isEmpty)
              ? Container(
            height: 90,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('Chưa có ảnh hoặc video',
                style: TextStyle(color: Colors.white38)),
          )
          // 🆕 _pendingMedia đứng trước _inviteMedia -> media vừa chọn
          // hiện ngay ở đầu (bên trái, trong tầm nhìn đầu tiên) thay vì
          // phải đợi upload xong rồi mới thấy sau khi fetch lại.
              : SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _pendingMedia.length + _inviteMedia.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                if (i < _pendingMedia.length) {
                  return _buildPendingMediaThumb(_pendingMedia[i]);
                }
                return _buildMediaThumbnail(
                    _inviteMedia[i - _pendingMedia.length]);
              },
            ),
          ),
        ],
      ),
    );
  }

  // 🆕 Thumbnail cho media đang chọn / nén / tải lên (chưa có id server).
  Widget _buildPendingMediaThumb(_PendingMedia item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 100,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.type == 'video')
              item.generatingThumb
                  ? shimmer.Shimmer.fromColors(
                baseColor: Colors.white.withOpacity(0.15),
                highlightColor: Colors.white.withOpacity(0.35),
                child: Container(color: Colors.white),
              )
                  : item.thumbnail != null
                  ? Image.memory(item.thumbnail!, fit: BoxFit.cover)
                  : Container(
                color: Colors.white.withOpacity(0.08),
                child: const Icon(Icons.videocam_rounded, color: Colors.white54),
              )
            else
              Image.file(item.file, fit: BoxFit.cover),
            if (item.uploading)
              Container(
                color: Colors.black.withOpacity(0.55),
                child: Center(
                  child: item.type == 'video'
                      ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 26, height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          value: item.progress > 0 ? item.progress : null,
                          color: Colors.orangeAccent,
                          backgroundColor: Colors.white.withOpacity(0.15),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${(item.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                      ),
                    ],
                  )
                      : const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.orangeAccent),
                  ),
                ),
              ),
            if (item.error) ...[
              Container(
                color: Colors.black.withOpacity(0.6),
                child: const Center(
                  child: Icon(Icons.error_rounded, color: Colors.redAccent, size: 28),
                ),
              ),
              Positioned(
                top: 4, right: 4,
                child: GestureDetector(
                  onTap: () => setState(() => _pendingMedia.remove(item)),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 12, color: Colors.white),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMediaThumbnail(MediaItem item) {
    final canDelete =
        isHost || item.userId == _currentUserId;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 100,
        child: Stack(
          fit: StackFit.expand,
          children: [
            item.isVideo
                ? GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      FullScreenVideoPage(videoUrl: item.url),
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 🆕 Ảnh thumbnail thật của video (thay vì chỉ ô đen).
                  // `key` + cache theo item.id để đảm bảo video thêm sau
                  // không hiện nhầm ảnh của video thêm trước.
                  FutureBuilder<Uint8List?>(
                    key: ValueKey('video_thumb_${item.id}'),
                    future: _getConfirmedVideoThumb(item),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return shimmer.Shimmer.fromColors(
                          baseColor: Colors.white.withOpacity(0.08),
                          highlightColor: Colors.white.withOpacity(0.25),
                          child: Container(color: Colors.white),
                        );
                      }
                      final bytes = snapshot.data;
                      if (bytes == null) {
                        return Container(color: Colors.black38);
                      }
                      return Image.memory(bytes, fit: BoxFit.cover);
                    },
                  ),
                  Container(color: Colors.black.withOpacity(0.18)),
                  const Center(
                    child: Icon(Icons.play_circle_fill,
                        size: 44, color: Colors.white),
                  ),
                ],
              ),
            )
                : CachedNetworkImage(
                imageUrl: item.url, fit: BoxFit.cover),
            if (canDelete)
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: () => _deleteMedia(item.id),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.9),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close,
                        size: 12, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // ACTION ROW (host controls + attendance)
  // ==========================================================================

  Widget _buildActionRow() {
    if (!isHost && !isJoined) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isHost) ...[
          _isUpdatingInviteStatus
              ? _shimmerChip()
              : _ChipButton(
            label:
            inviteStatus == 'open' ? 'Đóng bàn' : 'Mở lại bàn',
            icon: inviteStatus == 'open' ? Icons.lock : Icons.lock_open,
            onTap: _toggleInviteStatus,
          ),
        ],
        if (isHost && isJoined) const SizedBox(width: 10),
        if (isJoined) ...[
          _isUpdatingAttendance
              ? _shimmerChip()
              : _ChipButton(
            label: 'Trạng thái',
            icon: Icons.flag,
            onTap: _showAttendancePicker,
          ),
        ],
      ],
    );
  }

  // ==========================================================================
  // INFO CARD
  // ==========================================================================

  Widget _buildInfoCard(List<dynamic> metaData, String description) {
    // ── Map key → (icon, label hiển thị) ──────────────────────────────────
    const fieldDefs = <String, (IconData, String)>{
      'date':         (Icons.calendar_today,  'Ngày'),
      'time':         (Icons.access_time,     'Giờ'),
      'address':      (Icons.location_on,     'Địa điểm'),
      'phone':        (Icons.phone,           'Liên hệ'),
      'contact':      (Icons.contact_phone,   'Liên hệ'),
      'zalo':         (Icons.chat_bubble,     'Zalo'),
      'facebook':     (Icons.people_alt,      'Facebook'),
      'note':         (Icons.notes,           'Ghi chú'),
      'requirements': (Icons.checklist,       'Yêu cầu'),
    };

    // ── Lấy meta hợp lệ theo thứ tự ưu tiên ──────────────────────────────
    final orderedKeys = ['date', 'time', 'address', 'phone', 'contact', 'zalo', 'facebook', 'note', 'requirements'];
    final metaMap = <String, String>{
      for (final m in metaData)
        if (m['key'] != null && m['value'] != null)
          m['key'].toString(): m['value'].toString(),
    };

    final validMeta = orderedKeys
        .where((k) => metaMap.containsKey(k) && metaMap[k]!.isNotEmpty)
        .map((k) => (key: k, value: metaMap[k]!, def: fieldDefs[k]!))
        .toList();

    // ── Số người tham gia ─────────────────────────────────────────────────
    final hasCount = maxPeople > 0;

    // ── Categories ────────────────────────────────────────────────────────
    final cats = widget.product['categories'] as List<dynamic>? ?? [];
    final catNames = cats
        .map((c) => (c as Map<String, dynamic>)['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();

    final isEmpty = validMeta.isEmpty && !hasCount && catNames.isEmpty && description.isEmpty;
    if (isEmpty) return const SizedBox.shrink();

    // ── Tách thành 2 nhóm: ngắn (1 dòng) và dài (multi-line) ─────────────
    const shortKeys = {'date', 'time', 'phone', 'contact', 'zalo'};
    final shortMeta = validMeta.where((m) => shortKeys.contains(m.key)).toList();
    final longMeta  = validMeta.where((m) => !shortKeys.contains(m.key)).toList();

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: _AppColors.accentOrange.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.info_outline,
                    color: _AppColors.accentOrange, size: 16),
              ),
              const SizedBox(width: 10),
              const Text(
                'Thông tin chi tiết',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ── Số người tham gia ──────────────────────────────────────────
          if (hasCount) ...[
            _InfoCountBar(joined: joinedCount, max: maxPeople),
            const SizedBox(height: 14),
          ],

          // ── Categories dạng chips ──────────────────────────────────────
          if (catNames.isNotEmpty) ...[
            _InfoLabel(label: 'Danh mục'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: catNames.map((name) => _CategoryChip(name: name)).toList(),
            ),
            const SizedBox(height: 14),
          ],

          // ── Short fields: grid 2 cột ───────────────────────────────────
          if (shortMeta.isNotEmpty) ...[
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 2.8,
              children: shortMeta.map((m) => _InfoCell(
                icon: m.def.$1,
                label: m.def.$2,
                value: m.value,
              )).toList(),
            ),
            const SizedBox(height: 10),
          ],

          // ── Long fields: full width ────────────────────────────────────
          ...longMeta.map((m) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _InfoRow(icon: m.def.$1, label: m.def.$2, value: m.value),
          )),

          // ── Mô tả HTML ────────────────────────────────────────────────
          if (description.isNotEmpty) ...[
            if (validMeta.isNotEmpty || hasCount || catNames.isNotEmpty)
              Divider(color: Colors.white.withOpacity(0.1), height: 20),
            const SizedBox(height: 4),
            Html(
              data: description,
              style: {
                'body': Style(
                  fontSize: FontSize(14),
                  color: Colors.white.withOpacity(0.88),
                  lineHeight: LineHeight(1.75),
                  margin: Margins.zero,
                  padding: HtmlPaddings.zero,
                ),
              },
            ),
          ],
        ],
      ),
    );
  }

  // ==========================================================================
  // JOIN BUTTON
  // ==========================================================================

  Widget _buildJoinButton() {
    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: anim,
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: _isLoadingJoin
            ? _shimmerButton()
            : isJoined
            ? _buildJoinedActions()
            : (inviteStatus != 'open' || isFull)
            ? _buildClosedButton()
            : _buildOpenJoinButton(),
      ),
    );
  }

  Widget _buildJoinedActions() => Column(
    key: const ValueKey('joined'),
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionButton(
            label: 'Chat ($joinedCount)',
            icon: Icons.chat_bubble_rounded,
            color: const Color(0xFF22C55E),
            onTap: _goToGroupChat,
          ),
          const SizedBox(width: 10),
          _ActionButton(
            label: 'Rời phòng',
            icon: Icons.logout_rounded,
            color: Colors.redAccent,
            onTap: _leaveInvite,
          ),
        ],
      ),
    ],
  );

  Widget _buildClosedButton() => ElevatedButton(
    key: const ValueKey('closed'),
    style: ElevatedButton.styleFrom(
      backgroundColor: Colors.white12,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
      shape:
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
    ),
    onPressed: null,
    child: Text(
      inviteStatus != 'open' ? 'Bàn đã đóng' : 'Đã đủ người',
      style: const TextStyle(color: Colors.white54),
    ),
  );

  Widget _buildOpenJoinButton() => ScaleTransition(
    scale: _pulseAnimation,
    child: _ActionButton(
      key: const ValueKey('join'),
      label: 'Tham gia buổi nhậu 🍺',
      icon: Icons.group_add_rounded,
      color: _AppColors.accentOrange,
      onTap: inviteId == null ? null : _joinInvite,
      large: true,
    ),
  );

  Future<void> _goToGroupChat() async {
    if (_currentUserId == null) {
      _showSnack('Chưa xác định được user');
      return;
    }
    final currentUser = await UserHelper.getCurrentUser();
    final username = (currentUser['username'] as String?) ?? 'Người dùng';
    final me = _participants.firstWhere(
          (p) => p.userId == _currentUserId,
      orElse: () => Participant(
        userId: 0, name: '', status: '', role: '',
        attendanceStatus: AttendanceStatus.undecided,
        trustScore: 50,
      ),
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupChatPage(
          username:    username,
          userId:      _currentUserId!,
          groupAvatar: me.avatar ?? '',
          groupId:     inviteId!,
          groupName:   widget.product['name']?.toString() ?? 'Nhóm',
        ),
      ),
    );
  }

  // ==========================================================================
  // BOTTOM SHEETS
  // ==========================================================================

  void _showMediaPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _GradientBottomSheet(
        title: '📸 Thêm khoảnh khắc',
        children: [
          _MediaPickerTile(
            icon: Icons.photo_library_rounded,
            title: 'Chọn ảnh',
            subtitle: 'Đăng ảnh lên bàn nhậu',
            onTap: () {
              Navigator.pop(context);
              _pickAndUpload('image');
            },
          ),
          const SizedBox(height: 10),
          _MediaPickerTile(
            icon: Icons.videocam_rounded,
            title: 'Chọn video',
            subtitle: 'Chia sẻ video cùng mọi người',
            onTap: () {
              Navigator.pop(context);
              _pickAndUpload('video');
            },
          ),
        ],
      ),
    );
  }

  void _showAttendancePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xEE111827),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 16),
            const Text('Trạng thái tham dự',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
            const SizedBox(height: 8),
            ...AttendanceStatus.values.map((s) => ListTile(
              leading:
              Icon(Icons.circle, color: s.color, size: 12),
              title: Text(s.shortLabel,
                  style: const TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                await _updateAttendance(s);
              },
            )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openRatingSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (_, controller) => _GradientBottomSheet(
          title: '⭐ Đánh giá thành viên',
          scrollController: controller,
          children: [
            // 🔥 Không hiện chính mình trong danh sách được đánh giá
            ..._participants
                .where((p) => p.userId != _currentUserId)
                .map((p) => _RatingTile(
              participant: p,
              onRate: (point) async {
                await _rateUser(p.userId, point);
                if (mounted) Navigator.pop(context);
                _openRatingSheet();
              },
            )),
          ],
        ),
      ),
    );
  }

  void _openSpinDialog() {
    final wheelKey = GlobalKey<SpinWheelState>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: _GradientContainer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '🎡 Vòng quay nhậu',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              SpinWheel(
                key: wheelKey,
                items: const [
                  'Uống 1 ly',
                  'Uống 2 ly',
                  'Chỉ định người khác',
                  'Cả bàn uống',
                ],
                onFinish: (index) {
                  Navigator.pop(context);
                  final result = _spinResult;
                  _showSpinResult(
                    result['user_name']?.toString() ?? '',
                    result['action']?.toString() ?? '',
                  );
                },
              ),
              const SizedBox(height: 16),
              _ActionButton(
                label: '🎲 Quay ngay',
                color: _AppColors.accentOrange,
                onTap: () async {
                  if (wheelKey.currentState?.isSpinning == true) return;
                  wheelKey.currentState?.spinTo(0);
                  try {
                    final data = await _callSpinWheelApi();
                    setState(() => _spinResult =
                    Map<String, dynamic>.from(data['result'] as Map));
                    wheelKey.currentState
                        ?.spinTo(_spinResult['index'] as int);
                  } catch (e) {
                    _showSnack('❌ $e');
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpinResult(String user, String action) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: _GradientContainer(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.emoji_events, color: Colors.amber, size: 52),
              const SizedBox(height: 10),
              const Text('KẾT QUẢ',
                  style: TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      letterSpacing: 1.5)),
              const SizedBox(height: 12),
              Text(user,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(action,
                    style: const TextStyle(
                        fontSize: 16, color: Colors.white)),
              ),
              const SizedBox(height: 20),
              _ActionButton(
                label: 'Đồng ý',
                color: _AppColors.accentOrange,
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // SHIMMER HELPERS
  // ==========================================================================

  Widget _shimmerBox({double height = 120}) =>
      shimmer.Shimmer.fromColors(
        baseColor: Colors.white.withOpacity(0.06),
        highlightColor: Colors.white.withOpacity(0.18),
        child: Container(
            height: height,
            color: Colors.white,
            width: double.infinity),
      );

  Widget _shimmerButton({double w = 180, double h = 48}) =>
      shimmer.Shimmer.fromColors(
        baseColor: Colors.white.withOpacity(0.08),
        highlightColor: Colors.white.withOpacity(0.4),
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(30)),
        ),
      );

  Widget _shimmerChip() => _shimmerButton(w: 110, h: 36);

  Widget _shimmerParticipants() => Row(
    children: List.generate(
      3,
          (_) => Padding(
        padding: const EdgeInsets.only(right: 14),
        child: shimmer.Shimmer.fromColors(
          baseColor: Colors.white.withOpacity(0.08),
          highlightColor: Colors.white.withOpacity(0.25),
          child: Column(
            children: [
              const CircleAvatar(
                  radius: 24, backgroundColor: Colors.white),
              const SizedBox(height: 6),
              Container(
                width: 48,
                height: 10,
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// =============================================================================
// VIDEO SLIDE — real controls (play/pause + seek bar)
// =============================================================================

class _VideoSlide extends StatefulWidget {
  final VideoPlayerController controller;
  const _VideoSlide({required this.controller});

  @override
  State<_VideoSlide> createState() => _VideoSlideState();
}

class _VideoSlideState extends State<_VideoSlide> {
  bool _showControls = true;
  Timer? _hideTimer;

  VideoPlayerController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerUpdate);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _ctrl.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    if (mounted) setState(() {});
  }

  void _togglePlayPause() {
    setState(() {
      if (_ctrl.value.isPlaying) {
        _ctrl.pause();
        _showControls = true;
        _hideTimer?.cancel();
      } else {
        _ctrl.play();
        _scheduleHide();
      }
    });
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _onTap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total    = _ctrl.value.duration;
    final position = _ctrl.value.position;
    final progress = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video frame
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _ctrl.value.size.width,
              height: _ctrl.value.size.height,
              child: VideoPlayer(_ctrl),
            ),
          ),

          // Dark overlay when controls visible
          AnimatedOpacity(
            opacity: _showControls ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_showControls,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Play / Pause button (centre)
                  Expanded(
                    child: Center(
                      child: GestureDetector(
                        onTap: _togglePlayPause,
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.45),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _ctrl.value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Seek bar + time
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.6),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12),
                            activeTrackColor: _AppColors.accentOrange,
                            inactiveTrackColor: Colors.white30,
                            thumbColor: Colors.white,
                            overlayColor: Colors.white24,
                          ),
                          child: Slider(
                            value: progress,
                            onChanged: (v) {
                              final target = Duration(
                                milliseconds:
                                (v * total.inMilliseconds).round(),
                              );
                              _ctrl.seekTo(target);
                              _scheduleHide();
                            },
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _fmt(position),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                            Text(
                              _fmt(total),
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
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
        ],
      ),
    );
  }
}

// =============================================================================
// REUSABLE WIDGETS
// =============================================================================

class _GradientBackground extends StatelessWidget {
  final Widget child;
  const _GradientBackground({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xF21E3A8A), Color(0xD9FF7F50)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: child,
  );
}

class _GradientContainer extends StatelessWidget {
  final Widget child;
  const _GradientContainer({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xF21E3A8A), Color(0xE5FF7F50)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(20),
      boxShadow: const [
        BoxShadow(
            color: Colors.black38, blurRadius: 20, offset: Offset(0, 10))
      ],
    ),
    child: child,
  );
}

class _GradientBottomSheet extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final ScrollController? scrollController;

  const _GradientBottomSheet({
    required this.title,
    required this.children,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xF21E3A8A), Color(0xE5FF7F50)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius:
      BorderRadius.vertical(top: Radius.circular(24)),
    ),
    child: SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 14),
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ...children,
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}

class _SectionCard extends StatelessWidget {
  final Widget child;
  const _SectionCard({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.07),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withOpacity(0.1)),
      boxShadow: const [
        BoxShadow(
            color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))
      ],
    ),
    child: child,
  );
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback? onTap;
  final bool large;

  const _ActionButton({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.onTap,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
    style: ElevatedButton.styleFrom(
      backgroundColor: color,
      padding: EdgeInsets.symmetric(
        horizontal: large ? 36 : 20,
        vertical: large ? 14 : 12,
      ),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30)),
      elevation: 4,
    ),
    onPressed: onTap,
    icon: icon != null
        ? Icon(icon, color: Colors.white, size: large ? 22 : 18)
        : const SizedBox.shrink(),
    label: Text(label,
        style: TextStyle(
            color: Colors.white, fontSize: large ? 16 : 14)),
  );
}

class _ChipButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _ChipButton(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding:
      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFFFF7F50), Color(0xFFFF3D00)]),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
              color: Colors.black26,
              blurRadius: 4,
              offset: Offset(0, 3))
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    ),
  );
}

class _TinyButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _TinyButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}

class _MediaPickerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MediaPickerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child:
              Icon(icon, color: Colors.orangeAccent, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios,
                color: Colors.white38, size: 14),
          ],
        ),
      ),
    ),
  );
}

// =============================================================================
// PARTICIPANT CARD — tap avatar to change attendance
// =============================================================================

class _ParticipantCard extends StatelessWidget {
  final Participant participant;
  final bool isMe;
  final bool canKick;
  final bool isUpdatingAttendance;
  final VoidCallback? onAttendanceTap;
  final VoidCallback onKick;

  const _ParticipantCard({
    required this.participant,
    required this.isMe,
    required this.canKick,
    required this.isUpdatingAttendance,
    required this.onKick,
    this.onAttendanceTap,
  });

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      GestureDetector(
        onTap: onAttendanceTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Avatar
            ClipOval(
              child: CachedNetworkImage(
                imageUrl: participant.avatar ?? _ApiUrls.defaultAvatar,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const Icon(Icons.person,
                    size: 32, color: Colors.white54),
              ),
            ),
            // Me indicator ring
            if (isMe)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: _AppColors.accentOrange, width: 2),
                  ),
                ),
              ),
            // Host crown icon — góc trên trái avatar
            if (participant.role == 'host')
              const Positioned(
                top: -10,
                left: -4,
                child: Text('👑', style: TextStyle(fontSize: 18)),
              ),
            // Kick button
            if (canKick)
              Positioned(
                top: -5,
                right: -5,
                child: GestureDetector(
                  onTap: onKick,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: const Icon(Icons.close,
                        size: 11, color: Colors.white),
                  ),
                ),
              ),
            // Trust score badge
            Positioned(
              bottom: -4,
              right: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green,
                  borderRadius: BorderRadius.circular(8),
                  border:
                  Border.all(color: Colors.white, width: 1),
                ),
                child: Text(
                  '${participant.trustScore}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
      // Tên
      SizedBox(
        width: 64,
        child: Text(
          participant.name,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ),
      isUpdatingAttendance
          ? _AttendanceShimmer()
          : _AttendanceBadge(status: participant.attendanceStatus),
    ],
  );
}

class _AttendanceBadge extends StatelessWidget {
  final AttendanceStatus status;
  const _AttendanceBadge({required this.status});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: status.color.withOpacity(0.85),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      status.shortLabel,
      style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w600),
    ),
  );
}

class _AttendanceShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) => shimmer.Shimmer.fromColors(
    baseColor: Colors.white.withOpacity(0.15),
    highlightColor: Colors.white.withOpacity(0.5),
    child: Container(
      width: 52,
      height: 14,
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8)),
    ),
  );
}

// =============================================================================
// RATING TILE
// =============================================================================

class _RatingTile extends StatelessWidget {
  final Participant participant;
  final void Function(int point) onRate;

  const _RatingTile({required this.participant, required this.onRate});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundImage: NetworkImage(
                participant.avatar ?? _ApiUrls.defaultAvatar),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(participant.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
                Text('Uy tín: ${participant.trustScore}',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
                if (participant.isRated)
                  Text(
                    participant.myRating == 1
                        ? '👍 Đã đánh giá'
                        : '👎 Đã đánh giá',
                    style: const TextStyle(
                        color: Colors.white30, fontSize: 11),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              _VoteButton(
                icon: Icons.thumb_up,
                color: Colors.green,
                disabled: participant.isRated,
                active: participant.isRated &&
                    participant.myRating == 1,
                onTap: () => onRate(1),
              ),
              const SizedBox(width: 6),
              _VoteButton(
                icon: Icons.thumb_down,
                color: Colors.red,
                disabled: participant.isRated,
                active: participant.isRated &&
                    participant.myRating == -1,
                onTap: () => onRate(-1),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _VoteButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool disabled;
  final bool active;
  final VoidCallback onTap;

  const _VoteButton({
    required this.icon,
    required this.color,
    required this.disabled,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: disabled ? null : onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active
            ? color.withOpacity(0.9)
            : color.withOpacity(0.14),
      ),
      child: Icon(icon,
          size: 16,
          color: active
              ? Colors.white
              : (disabled ? Colors.white24 : color)),
    ),
  );
}

// =============================================================================
// VIEWER INDICATOR
// =============================================================================

class ViewerIndicator extends StatefulWidget {
  final int viewerCount;
  const ViewerIndicator({super.key, required this.viewerCount});

  @override
  State<ViewerIndicator> createState() => _ViewerIndicatorState();
}

class _ViewerIndicatorState extends State<ViewerIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.4),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => Icon(
            Icons.circle,
            size: 8,
            color: Colors.red
                .withOpacity(0.4 + _ctrl.value * 0.6),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${widget.viewerCount} đang xem',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500),
        ),
      ],
    ),
  );
}

// =============================================================================
// FULL SCREEN VIDEO PAGE
// =============================================================================

class FullScreenVideoPage extends StatefulWidget {
  final String videoUrl;
  const FullScreenVideoPage({super.key, required this.videoUrl});

  @override
  State<FullScreenVideoPage> createState() => _FullScreenVideoPageState();
}

class _FullScreenVideoPageState extends State<FullScreenVideoPage> {
  late VideoPlayerController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        _ctrl.play();
        _ctrl.setLooping(true);
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: _ctrl.value.isInitialized
        ? _VideoSlide(controller: _ctrl)
        : const Center(
        child: CircularProgressIndicator(color: Colors.white)),
  );
}

// =============================================================================
// INFO CARD HELPER WIDGETS
// =============================================================================

/// Label nhỏ trên section (Danh mục, v.v.)
class _InfoLabel extends StatelessWidget {
  final String label;
  const _InfoLabel({required this.label});

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: TextStyle(
      color: Colors.white.withOpacity(0.55),
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
    ),
  );
}

/// Progress bar số người tham gia
class _InfoCountBar extends StatelessWidget {
  final int joined;
  final int max;
  const _InfoCountBar({required this.joined, required this.max});

  @override
  Widget build(BuildContext context) {
    final ratio = max > 0 ? (joined / max).clamp(0.0, 1.0) : 0.0;
    final isFull = joined >= max;
    final barColor = isFull ? Colors.redAccent : _AppColors.accentOrange;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.group, color: barColor, size: 16),
              const SizedBox(width: 8),
              Text(
                'Số người tham gia',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              Text(
                '$joined / $max',
                style: TextStyle(
                  color: barColor,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 5,
              backgroundColor: Colors.white.withOpacity(0.1),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip cho từng category
class _CategoryChip extends StatelessWidget {
  final String name;
  const _CategoryChip({required this.name});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: _AppColors.accentOrange.withOpacity(0.18),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _AppColors.accentOrange.withOpacity(0.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.label_rounded,
            color: _AppColors.accentOrange, size: 12),
        const SizedBox(width: 5),
        Text(
          name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}

/// Ô thông tin nhỏ 2 cột (date, time, phone, v.v.)
class _InfoCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoCell({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.06),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withOpacity(0.08)),
    ),
    child: Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _AppColors.accentOrange.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: _AppColors.accentOrange, size: 14),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Row thông tin dài (address, note, requirements)
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.06),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withOpacity(0.08)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: _AppColors.accentOrange.withOpacity(0.15),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: _AppColors.accentOrange, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// =============================================================================
// STORY PROGRESS CAROUSEL — carousel auto-play kiểu story (thay dot indicator
// bằng progress bar tự chạy, tap trái/phải để lùi/tiến). Ảnh tự auto-advance,
// video giữ nguyên hành vi cũ (không auto-advance, bạn tự vuốt).
// =============================================================================

class StoryProgressController {
  _StoryProgressCarouselState? _state;

  void _attach(_StoryProgressCarouselState state) => _state = state;

  /// Gọi khi muốn ép carousel nhảy sang slide kế tiếp theo cách thủ công
  /// (ví dụ nếu sau này bạn muốn video tự next khi phát xong).
  void next() => _state?._goToNext();

  void previous() => _state?._goToPrevious();

  void pause() => _state?._pause();

  void resume() => _state?._resume();
}

class StoryProgressCarousel extends StatefulWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final bool Function(int index) isVideo;
  final Duration imageDuration;
  final ValueChanged<int>? onIndexChanged;
  final StoryProgressController? controller;
  final double height;
  final BorderRadius borderRadius;

  const StoryProgressCarousel({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.isVideo,
    this.imageDuration = const Duration(seconds: 5),
    this.onIndexChanged,
    this.controller,
    this.height = 300,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
  });

  @override
  State<StoryProgressCarousel> createState() => _StoryProgressCarouselState();
}

class _StoryProgressCarouselState extends State<StoryProgressCarousel>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController;
  late final AnimationController _progressController;
  int _index = 0;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _progressController = AnimationController(vsync: this);
    widget.controller?._attach(this);
    _startCurrent();
  }

  @override
  void didUpdateWidget(covariant StoryProgressCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    _progressController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _startCurrent() {
    _progressController.stop();
    _progressController.reset();

    final isVideo = widget.itemCount > 0 && widget.isVideo(_index);
    if (isVideo) {
      // Video tự quản lý bằng VideoPlayerController có sẵn của bạn —
      // progress bar đứng yên, không auto-advance.
      return;
    }

    _progressController.duration = widget.imageDuration;
    _progressController.forward();
    _progressController.addStatusListener(_onAnimationStatus);
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _progressController.removeStatusListener(_onAnimationStatus);
      _goToNext();
    }
  }

  void _goToNext() {
    if (_index >= widget.itemCount - 1) return;
    _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  void _goToPrevious() {
    if (_index <= 0) return;
    _pageController.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  void _pause() {
    _paused = true;
    _progressController.stop();
  }

  void _resume() {
    if (!_paused) return;
    _paused = false;
    _progressController.forward();
  }

  void _onPageChangedInternal(int i) {
    setState(() => _index = i);
    widget.onIndexChanged?.call(i);
    _startCurrent();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount == 0) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.itemCount,
              onPageChanged: _onPageChangedInternal,
              itemBuilder: widget.itemBuilder,
            ),

            // ── Tap trái/phải để lùi/tiến (giống story) ─────────────────
            Positioned.fill(
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (_) => _goToPrevious(),
                      onLongPressStart: (_) => _pause(),
                      onLongPressEnd: (_) => _resume(),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapUp: (_) => _goToNext(),
                      onLongPressStart: (_) => _pause(),
                      onLongPressEnd: (_) => _resume(),
                    ),
                  ),
                ],
              ),
            ),

            // ── Thanh progress kiểu story ────────────────────────────────
            if (widget.itemCount > 1)
              Positioned(
                top: 10,
                left: 10,
                right: 10,
                child: Row(
                  children: List.generate(widget.itemCount, (i) {
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: SizedBox(
                            height: 3,
                            child: AnimatedBuilder(
                              animation: _progressController,
                              builder: (_, __) {
                                double value;
                                if (i < _index) {
                                  value = 1.0;
                                } else if (i == _index) {
                                  value = widget.isVideo(_index)
                                      ? 0.0
                                      : _progressController.value;
                                } else {
                                  value = 0.0;
                                }
                                return LinearProgressIndicator(
                                  value: value,
                                  backgroundColor:
                                  Colors.white.withOpacity(0.3),
                                  valueColor: const AlwaysStoppedAnimation(
                                      Colors.white),
                                  minHeight: 3,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),

            // ── Gradient đáy giữ nguyên cảm giác cũ ─────────────────────
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.45),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
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

// =============================================================================
// DOUBLE TAP REACTION — double-tap để thả tim, bay lên rồi biến mất
// =============================================================================

class DoubleTapReaction extends StatefulWidget {
  final Widget child;
  final VoidCallback? onDoubleTap;
  final IconData icon;
  final Color color;

  const DoubleTapReaction({
    super.key,
    required this.child,
    this.onDoubleTap,
    this.icon = Icons.favorite,
    this.color = const Color(0xFFFF4D6D),
  });

  @override
  State<DoubleTapReaction> createState() => _DoubleTapReactionState();
}

class _FloatingHeart {
  final double dx;
  final double startOffset;
  _FloatingHeart({required this.dx, required this.startOffset});
}

class _DoubleTapReactionState extends State<DoubleTapReaction> {
  final List<_FloatingHeart> _hearts = [];
  final _random = Random();

  void _handleDoubleTap(TapDownDetails details, BoxConstraints constraints) {
    final dxRatio =
    (details.localPosition.dx / constraints.maxWidth).clamp(0.15, 0.85);
    final heart = _FloatingHeart(
      dx: dxRatio,
      startOffset: _random.nextDouble() * 20 - 10,
    );
    setState(() => _hearts.add(heart));

    Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hearts.remove(heart));
    });

    widget.onDoubleTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (d) => _handleDoubleTap(d, constraints),
          onDoubleTap: () {}, // bắt buộc để onDoubleTapDown hoạt động
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              widget.child,
              ..._hearts.map((h) => _AnimatedHeart(
                dxRatio: h.dx,
                xJitter: h.startOffset,
                icon: widget.icon,
                color: widget.color,
              )),
            ],
          ),
        );
      },
    );
  }
}

class _AnimatedHeart extends StatefulWidget {
  final double dxRatio;
  final double xJitter;
  final IconData icon;
  final Color color;

  const _AnimatedHeart({
    required this.dxRatio,
    required this.xJitter,
    required this.icon,
    required this.color,
  });

  @override
  State<_AnimatedHeart> createState() => _AnimatedHeartState();
}

class _AnimatedHeartState extends State<_AnimatedHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _rise;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    )..forward();

    _rise = Tween<double>(begin: 0, end: -110)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _fade = Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0.5, 1.0)));
    _scale = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.4, end: 1.3), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 60),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Positioned.fill(
          child: FractionallySizedBox(
            widthFactor: 1,
            heightFactor: 1,
            child: Align(
              alignment: Alignment(widget.dxRatio * 2 - 1, 0.3),
              child: Transform.translate(
                offset: Offset(widget.xJitter, _rise.value),
                child: Opacity(
                  opacity: _fade.value,
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Icon(widget.icon, color: widget.color, size: 64),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// HERO PRODUCT IMAGE — dùng bên ShopPage (file khác) để khớp Hero tag
// với ảnh đầu tiên trong carousel ở trên.
//
// Trong ShopPage, chỗ hiển thị ảnh sản phẩm trong list, thay:
//
//   CachedNetworkImage(imageUrl: product["images"][0]["src"], width: 80, height: 80, ...)
//
// bằng:
//
//   Hero(
//     tag: 'product-image-${product["id"]}',
//     child: ClipRRect(
//       borderRadius: BorderRadius.circular(12),
//       child: CachedNetworkImage(
//         imageUrl: product["images"][0]["src"],
//         width: 80,
//         height: 80,
//         fit: BoxFit.cover,
//       ),
//     ),
//   )
//
// Tag PHẢI giống hệt tag dùng ở _buildImageSlide() phía trên
// ('product-image-${widget.product["id"]}').
// =============================================================================