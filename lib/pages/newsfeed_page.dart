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

// Bảng màu tạo "quầng sáng" riêng cho từng video (hash theo tên file →
// luôn ra đúng 1 màu, không nháy loạn). Dùng RadialGradient (đậm ở giữa,
// luôn về ĐEN ở mọi rìa) thay vì gradient chéo — để rìa trên/dưới của
// MỌI video đều đen giống nhau, 2 trang cạnh nhau trong PageView giáp
// nhau luôn đen khớp đen, không lộ đường kẻ ngăn cách lúc vuốt.
const List<Color> _glowColors = [
  Color(0xFF2E4057),
  Color(0xFF2C5364),
  Color(0xFF4A4063),
  Color(0xFF3A6073),
  Color(0xFF52394A),
  Color(0xFF3E5C50),
  Color(0xFF4A4A6A),
  Color(0xFF5A4A3A),
];

Color _glowFor(String seed) {
  final hash = seed.codeUnits.fold<int>(0, (a, b) => a + b);
  return _glowColors[hash % _glowColors.length];
}

// Gói 1 VideoPlayerController đang được "mồi" trước cùng Future báo khi
// nào nó init xong — để nơi lấy ra dùng có thể `await entry.ready` an
// toàn kể cả khi lỡ lấy ra lúc còn đang tải dở (vuốt rất nhanh).
class _PreloadEntry {
  final VideoPlayerController controller;
  final Future<void> ready;
  _PreloadEntry(this.controller, this.ready);
}

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
  int? _seed; // giữ nguyên trong cả phiên để random nhưng không lặp/thiếu giữa các trang
  bool _loading = false;
  bool _hasMore = true;
  bool _initialLoadDone = false;
  String? _error;
  int _currentIndex = 0;

  // ─── MỒI TRƯỚC VIDEO KẾ TIẾP/TRƯỚC ───────────────────────────────────
  // Khi bạn đang xem video hiện tại, video liền kề (trước & sau) đã âm
  // thầm được tải & init sẵn ở đây. Lúc vuốt tới, _ReelItem chỉ việc lấy
  // controller đã sẵn sàng này ra dùng — KHÔNG phải chờ mạng nữa → chuyển
  // gần như tức thì thay vì phải đợi buffer mỗi lần vuốt.
  final Map<int, _PreloadEntry> _preloadCache = {};

  void _ensurePreload(int center) {
    for (final idx in [center - 1, center + 1]) {
      if (idx < 0 || idx >= _items.length) continue;
      if (_preloadCache.containsKey(idx)) continue;
      _preloadOne(idx);
    }
    // Dọn bớt bản mồi quá xa vị trí hiện tại để đỡ tốn RAM/băng thông.
    final toRemove = _preloadCache.keys.where((idx) => (idx - center).abs() > 1).toList();
    for (final idx in toRemove) {
      _preloadCache.remove(idx)?.controller.dispose();
    }
  }

  void _preloadOne(int idx) {
    if (idx < 0 || idx >= _items.length) return;
    final url = _items[idx].url;
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
    final ready = ctrl.initialize().then((_) async {
      await ctrl.setLooping(true);
      await ctrl.setVolume(0);
    }).catchError((e) {
      debugPrint('🔴 preload lỗi idx=$idx: $e');
    });
    _preloadCache[idx] = _PreloadEntry(ctrl, ready);
  }

  _PreloadEntry? _takePreload(int idx) => _preloadCache.remove(idx);

  @override
  void dispose() {
    _pageController.dispose();
    for (final e in _preloadCache.values) {
      e.controller.dispose();
    }
    _preloadCache.clear();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);

    try {
      final seedParam = _seed != null ? '&seed=$_seed' : '';
      final uri = Uri.parse(
        '${AppConfig.webDomain}/wp-json/nhau/v1/newsfeed-videos?page=$_page&per_page=10$seedParam',
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
        // Server tự sinh seed ở request đầu tiên (chưa có _seed) → lưu lại
        // để các trang sau tiếp tục đúng thứ tự random đó, không bị xáo lại.
        _seed = (data['seed'] as num?)?.toInt() ?? _seed;
        _error = null;
      });
      // Có video mới trong danh sách → mồi trước video liền kề vị trí
      // đang xem (hữu ích nhất ở lần tải đầu: mồi luôn video số 1 trong
      // lúc bạn còn đang xem video số 0).
      _ensurePreload(_currentIndex);
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
      _seed = null; // bỏ seed cũ → server random lại thứ tự mới hoàn toàn
      _hasMore = true;
      _initialLoadDone = false;
      _error = null;
      _currentIndex = 0;
    });
    for (final e in _preloadCache.values) {
      e.controller.dispose();
    }
    _preloadCache.clear();
    await _loadMore();
  }

  void _onPageChanged(int index) {
    _currentIndex = index;
    // Còn 3 video nữa là hết danh sách hiện có → tải thêm trang kế tiếp.
    if (_hasMore && !_loading && index >= _items.length - 3) {
      _loadMore();
    }
    _ensurePreload(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          SafeArea(
            top: false,
            bottom: false,
            child: _buildBody(),
          ),
          _buildBackButton(context),
        ],
      ),
    );
  }

  Widget _buildBackButton(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Positioned(
      top: topPadding + 8,
      left: 12,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_items.isEmpty && _loading) {
      return _buildInitialShimmer();
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
        // Giữ sẵn trang liền kề trong cây widget thay vì dựng lại từ đầu
        // mỗi lần vuốt tới — giảm hẳn cảm giác khựng khi chuyển video.
        allowImplicitScrolling: true,
        itemCount: _items.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          return _ReelItem(
            key: ValueKey(_items[index].id.isNotEmpty ? _items[index].id : index),
            item: _items[index],
            preloadTake: () => _takePreload(index),
          );
        },
      ),
    );
  }

  // Skeleton toàn màn hình lúc mới mở feed — thay cho vòng xoay tròn để
  // đỡ trống trải, đồng bộ luôn với style shimmer của từng video bên dưới.
  Widget _buildInitialShimmer() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        shimmer.Shimmer(
          period: const Duration(milliseconds: 1400),
          gradient: LinearGradient(
            colors: [
              Colors.transparent,
              Colors.white.withOpacity(0.10),
              Colors.transparent,
            ],
            stops: const [0.35, 0.5, 0.65],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          child: Container(color: Colors.transparent),
        ),
        Positioned(
          right: 12,
          bottom: 90,
          child: Column(
            children: [
              _skeletonCircle(),
              const SizedBox(height: 18),
              _skeletonCircle(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _skeletonCircle() {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        shape: BoxShape.circle,
      ),
    );
  }
}

// ─── Giới hạn số video chạy đồng thời (giống shop_page.dart) ───────────────
class _NewsfeedPlaybackLimiter {
  // 2 slot: 1 cho video đang xem + 1 cho video kế tiếp/trước đang được
  // "mồi" (preload, chưa play) sẵn để lúc vuốt tới không bị khựng/giật.
  static const int maxConcurrent = 2;
  static final List<_ReelItemState> _active = [];

  static bool requestSlot(_ReelItemState s) {
    if (_active.contains(s)) return true;
    if (_active.length >= maxConcurrent) {
      // Nhường chỗ: dừng video cũ nhất (không phải video đang được xem)
      // để giải phóng slot cho video sắp tới gần màn hình.
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
  final _PreloadEntry? Function()? preloadTake;
  const _ReelItem({super.key, required this.item, this.preloadTake});

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

  // Hai ngưỡng riêng biệt để vuốt mượt hơn:
  // - >2%   hiện ra (đang vuốt tới) → MỒI sẵn video (init, chưa play)
  // - >60%  gần như chiếm trọn màn hình → mới thật sự PHÁT
  // - =0%   ra khỏi màn hoàn toàn → giải phóng để khỏi tốn RAM/decoder
  static const double _kInitThreshold = 0.02;
  static const double _kPlayThreshold = 0.6;

  void _onVisibilityChanged(VisibilityInfo info) {
    final fraction = info.visibleFraction;
    final shouldPlay = fraction > _kPlayThreshold;

    if (fraction <= 0) {
      _visible = false;
      _teardown();
      return;
    }

    if (fraction > _kInitThreshold && _controller == null) {
      _tryInit(autoplay: shouldPlay);
    }

    if (shouldPlay != _visible) {
      _visible = shouldPlay;
      final ctrl = _controller;
      if (ctrl != null && ctrl.value.isInitialized) {
        if (shouldPlay) {
          ctrl.play();
        } else {
          ctrl.pause();
        }
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _tryInit({required bool autoplay}) async {
    if (_initializing || _controller != null) return;
    _NewsfeedPlaybackLimiter.requestSlot(this);
    _initializing = true;

    try {
      VideoPlayerController ctrl;

      // Nếu video này đã được "mồi" sẵn từ trước (lúc bạn đang xem video
      // trước đó) → dùng luôn, KHÔNG tạo request mạng mới → vào ngay lập
      // tức. Chỉ khi chưa kịp mồi (vuốt quá nhanh) mới phải tải mới.
      final preload = widget.preloadTake?.call();
      if (preload != null) {
        await preload.ready;
        ctrl = preload.controller;
      } else {
        ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.item.url));
        await ctrl.initialize();
        await ctrl.setLooping(true);
      }
      await ctrl.setVolume(_muted ? 0 : 1);

      if (!mounted) {
        ctrl.dispose();
        _NewsfeedPlaybackLimiter.release(this);
        _initializing = false;
        return;
      }

      // Chỉ play nếu lúc này video đã (gần như) chiếm trọn màn hình.
      // Nếu chỉ mới "mồi" trước (autoplay=false) thì giữ pause, chờ
      // onVisibilityChanged gọi play() khi vuốt tới thật sự.
      if (autoplay) {
        await ctrl.play();
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
            _buildBottomGradient(),
            _buildRightControls(),
            if (_ready && _controller != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: true,
                  padding: EdgeInsets.zero,
                  colors: VideoProgressColors(
                    playedColor: _accentOrange,
                    bufferedColor: Colors.white.withOpacity(0.35),
                    backgroundColor: Colors.white.withOpacity(0.15),
                  ),
                ),
              ),
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
    final glow = _glowFor(widget.item.filename.isNotEmpty ? widget.item.filename : widget.item.id);

    if (_error) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _seamSafeBackground(glow),
          const Center(
            child: Icon(Icons.videocam_off, size: 48, color: Colors.white70),
          ),
        ],
      );
    }
    if (!_ready || _controller == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _seamSafeBackground(glow),
          shimmer.Shimmer(
            period: const Duration(milliseconds: 1400),
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                Colors.white.withOpacity(0.14),
                Colors.transparent,
              ],
              stops: const [0.35, 0.5, 0.65],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            child: Container(color: Colors.transparent),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        _seamSafeBackground(glow),
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),
      ],
    );
  }

  // Nền "quầng sáng": đậm ở giữa, luôn nhạt về ĐEN tuyệt đối ở mọi rìa.
  // Nhờ vậy rìa của bất kỳ video nào cũng đen giống hệt nhau → 2 trang
  // liền kề trong PageView giáp nhau luôn đen khớp đen, hết lằn ranh.
  Widget _seamSafeBackground(Color glow) {
    return Container(
      color: Colors.black,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.0,
            colors: [glow.withOpacity(0.18), Colors.black],
            stops: const [0.0, 0.85],
          ),
        ),
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

  Widget _buildBottomGradient() {
    return IgnorePointer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black54, Colors.transparent],
            stops: [0.0, 0.22],
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