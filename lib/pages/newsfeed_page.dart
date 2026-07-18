import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';

// ─────────────────────────────────────────────────────────────────────────
// NEWSFEED (video) — kéo video từ wp-content/uploads/BeerGoVideo qua API
// GET {webDomain}/wp-json/nhau/v1/newsfeed-videos?page=1&per_page=10
//
// Giao diện dạng Reels/TikTok: mỗi video 1 màn hình, vuốt dọc để xem tiếp,
// tự động phát khi vào khung hình, tự dừng khi cuộn qua — dùng lại đúng
// nguyên tắc "chỉ init khi thực sự hiện & giới hạn số video chạy đồng thời"
// như _CardVideoPreview trong shop_page.dart, để tránh crash MediaCodec.
// ─────────────────────────────────────────────────────────────────────────

const Color _bg = Colors.black;
const Color _accentOrange = Color(0xFFFF7F50);

class NewsfeedVideoItem {
  final String id;
  final String url;
  final String filename;
  final DateTime? uploadedAt;

  NewsfeedVideoItem({
    required this.id,
    required this.url,
    required this.filename,
    this.uploadedAt,
  });

  factory NewsfeedVideoItem.fromJson(Map<String, dynamic> json) {
    DateTime? uploaded;
    try {
      uploaded = DateTime.tryParse(json['uploaded_at']?.toString() ?? '');
    } catch (_) {}
    return NewsfeedVideoItem(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      uploadedAt: uploaded,
    );
  }
}

class NewsfeedPage extends StatefulWidget {
  const NewsfeedPage({super.key});

  @override
  State<NewsfeedPage> createState() => _NewsfeedPageState();
}

class _NewsfeedPageState extends State<NewsfeedPage> {
  final List<NewsfeedVideoItem> _items = [];
  final PageController _pageController = PageController();

  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  bool _initialLoadDone = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);

    try {
      final uri = Uri.parse(
        '${AppConfig.webDomain}/wp-json/nhau/v1/newsfeed-videos?page=$_page&per_page=10',
      );
      final res = await http.get(uri);

      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }

      final data = jsonDecode(res.body);
      final List<dynamic> rawItems = data['items'] ?? [];
      final newItems = rawItems
          .map((e) => NewsfeedVideoItem.fromJson(e as Map<String, dynamic>))
          .toList();

      setState(() {
        _items.addAll(newItems);
        _hasMore = data['has_more'] == true;
        _page += 1;
        _error = null;
      });
    } catch (e) {
      debugPrint('🔴 newsfeed load error: $e');
      if (!_initialLoadDone) {
        setState(() => _error = 'Không tải được video. Kéo để thử lại.');
      }
    } finally {
      _initialLoadDone = true;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _page = 1;
      _hasMore = true;
      _initialLoadDone = false;
      _error = null;
    });
    await _loadMore();
  }

  void _onPageChanged(int index) {
    // Còn 3 video nữa là hết danh sách hiện có → tải thêm trang kế tiếp.
    if (_hasMore && !_loading && index >= _items.length - 3) {
      _loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        top: false,
        bottom: false,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_items.isEmpty && _loading) {
      return const Center(
        child: CircularProgressIndicator(color: _accentOrange),
      );
    }

    if (_items.isEmpty && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, color: Colors.white38, size: 40),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _refresh,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white38),
              ),
              child: const Text('Thử lại'),
            ),
          ],
        ),
      );
    }

    if (_items.isEmpty) {
      return const Center(
        child: Text(
          'Chưa có video nào 🍻',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }

    return RefreshIndicator(
      color: _accentOrange,
      backgroundColor: Colors.black,
      onRefresh: _refresh,
      child: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: _items.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          return _ReelItem(item: _items[index]);
        },
      ),
    );
  }
}

// ─── Giới hạn số video chạy đồng thời (giống shop_page.dart) ───────────────
class _NewsfeedPlaybackLimiter {
  static const int maxConcurrent = 1; // fullscreen: chỉ 1 video active là đủ
  static final List<_ReelItemState> _active = [];

  static bool requestSlot(_ReelItemState s) {
    if (_active.contains(s)) return true;
    if (_active.length >= maxConcurrent) {
      // Nhường chỗ: dừng video cũ nhất đang chạy để video mới (đang thấy
      // rõ trên màn hình) được phát ngay — đúng hành vi Reels/TikTok.
      final old = _active.removeAt(0);
      old._teardown();
    }
    _active.add(s);
    return true;
  }

  static void release(_ReelItemState s) {
    _active.remove(s);
  }
}

class _ReelItem extends StatefulWidget {
  final NewsfeedVideoItem item;
  const _ReelItem({required this.item});

  @override
  State<_ReelItem> createState() => _ReelItemState();
}

class _ReelItemState extends State<_ReelItem> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _error = false;
  bool _initializing = false;
  bool _visible = false;
  bool _muted = false;
  final Key _visibilityKey = UniqueKey();

  void _onVisibilityChanged(VisibilityInfo info) {
    final isVisible = info.visibleFraction > 0.6;
    if (isVisible == _visible) return;
    _visible = isVisible;

    if (_visible) {
      _tryInit();
    } else {
      _teardown();
    }
  }

  Future<void> _tryInit() async {
    if (_initializing || _controller != null) return;
    _NewsfeedPlaybackLimiter.requestSlot(this);
    _initializing = true;

    try {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.item.url));
      await ctrl.initialize();
      await ctrl.setLooping(true);
      await ctrl.setVolume(_muted ? 0 : 1);

      if (!mounted || !_visible) {
        ctrl.dispose();
        _NewsfeedPlaybackLimiter.release(this);
        _initializing = false;
        return;
      }

      await ctrl.play();
      if (!mounted || !_visible) {
        ctrl.dispose();
        _NewsfeedPlaybackLimiter.release(this);
        _initializing = false;
        return;
      }

      setState(() {
        _controller = ctrl;
        _ready = true;
      });
    } catch (e) {
      debugPrint('🔴 reel init error: $e');
      _NewsfeedPlaybackLimiter.release(this);
      if (mounted) setState(() => _error = true);
    } finally {
      _initializing = false;
    }
  }

  void _teardown() {
    _NewsfeedPlaybackLimiter.release(this);
    final ctrl = _controller;
    _controller = null;
    if (ctrl != null) {
      ctrl.pause();
      ctrl.dispose();
    }
    if (mounted && _ready) {
      setState(() => _ready = false);
    } else {
      _ready = false;
    }
  }

  void _togglePlayPause() {
    final ctrl = _controller;
    if (ctrl == null) return;
    setState(() {
      ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
    });
  }

  void _toggleMute() {
    final ctrl = _controller;
    setState(() {
      _muted = !_muted;
      ctrl?.setVolume(_muted ? 0 : 1);
    });
  }

  void _share() {
    Share.share(widget.item.url);
  }

  @override
  void dispose() {
    _NewsfeedPlaybackLimiter.release(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: _onVisibilityChanged,
      child: GestureDetector(
        onTap: _togglePlayPause,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildVideo(),
            _buildTopGradient(),
            _buildRightControls(),
            if (_ready && _controller != null && !_controller!.value.isPlaying)
              const Center(
                child: Icon(Icons.play_arrow, color: Colors.white70, size: 72),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    if (_error) {
      return Container(
        color: const Color(0xFF15151A),
        child: const Center(
          child: Icon(Icons.videocam_off, size: 48, color: Colors.white38),
        ),
      );
    }
    if (!_ready || _controller == null) {
      return shimmer.Shimmer(
        period: const Duration(milliseconds: 2500),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0A0A12),
            Color(0xFF0A0A12),
            Color(0x552A2A38),
            Color(0xFF0A0A12),
            Color(0xFF0A0A12),
          ],
          stops: [0.0, 0.3, 0.5, 0.7, 1.0],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        child: Container(color: const Color(0xFF0A0A12)),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: _controller!.value.size.width,
        height: _controller!.value.size.height,
        child: VideoPlayer(_controller!),
      ),
    );
  }

  Widget _buildTopGradient() {
    return IgnorePointer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black45, Colors.transparent],
            stops: [0.0, 0.25],
          ),
        ),
      ),
    );
  }

  Widget _buildRightControls() {
    return Positioned(
      right: 12,
      bottom: 90,
      child: Column(
        children: [
          _circleButton(
            icon: _muted ? Icons.volume_off : Icons.volume_up,
            onTap: _toggleMute,
          ),
          const SizedBox(height: 18),
          _circleButton(icon: Icons.share, onTap: _share),
        ],
      ),
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.4),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}