// =============================================================================
// beer_video_feed_page.dart
// =============================================================================
//
// Trang "xem hết video quán" — KHÔNG gắn với 1 kèo/product cụ thể nào,
// chỉ đơn giản lướt (vuốt dọc, kiểu Reels/TikTok) qua TOÀN BỘ video đang
// có trong thư mục:
//   /var/lib/docker/volumes/spiritwebscom_spiritwebscom_wp_data/_data/
//   wp-content/uploads/BeerGoVideo
//
// ⚠️ LƯU Ý QUAN TRỌNG VỀ NGUỒN DỮ LIỆU:
// App Flutter không thể đọc trực tiếp đường dẫn ổ đĩa server ở trên — phải
// đi qua 1 API. Trang này ĐANG DÙNG LẠI đúng endpoint mà newsfeed_page.dart
// đang dùng:
//     GET {webDomain}/wp-json/nhau/v1/newsfeed-videos?page=1&per_page=10
// vì theo comment trong newsfeed_page.dart, endpoint này vốn đã kéo video
// từ chính thư mục BeerGoVideo (kèo có thể có hoặc KHÔNG có product gắn
// theo, coi phần `hasProduct` bên NewsfeedVideoItem). Nghĩa là endpoint
// này vốn đã trả về "toàn bộ video trong thư mục", không lọc theo kèo —
// nên KHÔNG cần thêm API mới, chỉ cần 1 trang hiển thị khác, bỏ hết phần
// UI liên quan tới product (avatar, giá, giờ, nút Tham gia, bản đồ...).
//
// Nếu sau này phát hiện endpoint trên CÓ lọc bớt (chỉ trả video có gắn
// product), cần thêm 1 endpoint riêng ở backend (WordPress) kiểu:
//   scandir(BeerGoVideo) -> trả về list {id, url, filename, uploaded_at}
// rồi đổi `_apiPath` bên dưới sang endpoint mới đó — phần còn lại của
// trang này không cần đổi gì thêm.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import '../config/app_config.dart';

const Color _bg = Colors.black;

class BeerVideoItem {
  final String id;
  final String url;
  final String filename;

  BeerVideoItem({required this.id, required this.url, required this.filename});

  factory BeerVideoItem.fromJson(Map<String, dynamic> json) {
    return BeerVideoItem(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
    );
  }
}

// Gói 1 VideoPlayerController đang được "mồi" trước cùng Future báo khi
// nào nó init xong (giống hệt cơ chế bên newsfeed_page.dart) — để vuốt
// tới video kế tiếp gần như tức thì, không phải chờ buffer.
class _PreloadEntry {
  final VideoPlayerController controller;
  final Future<void> ready;
  _PreloadEntry(this.controller, this.ready);
}

class BeerVideoFeedPage extends StatefulWidget {
  const BeerVideoFeedPage({super.key});

  @override
  State<BeerVideoFeedPage> createState() => _BeerVideoFeedPageState();
}

class _BeerVideoFeedPageState extends State<BeerVideoFeedPage> {
  static const String _apiPath = '/wp-json/nhau/v1/newsfeed-videos';

  final List<BeerVideoItem> _items = [];
  final PageController _pageController = PageController();
  final Set<String> _seenVideoIds = {};
  final Map<int, _PreloadEntry> _preloadCache = {};

  int _page = 1;
  int? _seed;
  bool _loading = false;
  bool _hasMore = true;
  bool _initialLoadDone = false;
  String? _error;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final e in _preloadCache.values) {
      e.controller.dispose();
    }
    _preloadCache.clear();
    super.dispose();
  }

  // ─── MỒI TRƯỚC VIDEO KẾ TIẾP/TRƯỚC (giống newsfeed_page.dart) ─────────
  void _ensurePreload(int center) {
    for (final idx in [center - 1, center + 1]) {
      if (idx < 0 || idx >= _items.length) continue;
      if (_preloadCache.containsKey(idx)) continue;
      _preloadOne(idx);
    }
    final toRemove =
    _preloadCache.keys.where((idx) => (idx - center).abs() > 1).toList();
    for (final idx in toRemove) {
      _preloadCache.remove(idx)?.controller.dispose();
    }
  }

  void _preloadOne(int idx) {
    if (idx < 0 || idx >= _items.length) return;
    final item = _items[idx];
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(item.url));
    final ready = ctrl.initialize().then((_) async {
      await ctrl.setLooping(true);
      await ctrl.setVolume(1);
    }).catchError((e) {
      debugPrint('🔴 preload lỗi idx=$idx: $e');
      _preloadCache.remove(idx)?.controller.dispose();
      _removeBrokenItem(item);
    });
    _preloadCache[idx] = _PreloadEntry(ctrl, ready);
  }

  _PreloadEntry? _takePreload(int idx) => _preloadCache.remove(idx);

  // Video lỗi (không tải/phát được) -> gỡ luôn khỏi danh sách, không hiện
  // icon "video lỗi" đứng yên (cùng nguyên tắc newsfeed_page.dart).
  void _removeBrokenItem(BeerVideoItem item) {
    if (!mounted) return;
    final idx = _items.indexOf(item);
    if (idx == -1) return;

    setState(() {
      _items.removeAt(idx);
      if (idx < _currentIndex) {
        _currentIndex -= 1;
      } else if (_currentIndex >= _items.length) {
        _currentIndex = _items.length - 1;
      }
      if (_currentIndex < 0) _currentIndex = 0;
    });

    final reKeyed = <int, _PreloadEntry>{};
    _preloadCache.forEach((k, v) {
      if (k == idx) {
        v.controller.dispose();
      } else if (k > idx) {
        reKeyed[k - 1] = v;
      } else {
        reKeyed[k] = v;
      }
    });
    _preloadCache
      ..clear()
      ..addAll(reKeyed);

    if (_items.isNotEmpty &&
        _pageController.hasClients &&
        _pageController.page?.round() != _currentIndex) {
      _pageController.jumpToPage(_currentIndex);
    }

    _ensurePreload(_currentIndex);
    if (_hasMore && !_loading && _items.length - _currentIndex < 4) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);

    try {
      final seedParam = _seed != null ? '&seed=$_seed' : '';
      final uri = Uri.parse(
        '${AppConfig.webDomain}$_apiPath?page=$_page&per_page=10$seedParam',
      );
      final res = await http.get(uri);

      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }

      final data = jsonDecode(res.body);
      final List<dynamic> rawItems = data['items'] ?? [];
      final parsedItems = rawItems
          .map((e) => BeerVideoItem.fromJson(e as Map<String, dynamic>))
          .toList();

      // Lọc trùng lặp theo id (giống newsfeed_page.dart) — pool video
      // random theo seed đôi khi lặp lại trước khi has_more báo false.
      final newItems = <BeerVideoItem>[];
      for (final item in parsedItems) {
        if (item.id.isEmpty || _seenVideoIds.add(item.id)) {
          newItems.add(item);
        }
      }
      final bool exhausted = rawItems.isNotEmpty && newItems.isEmpty;

      setState(() {
        _items.addAll(newItems);
        _hasMore = exhausted ? false : (data['has_more'] == true);
        _page += 1;
        _seed = (data['seed'] as num?)?.toInt() ?? _seed;
        _error = null;
      });
      _ensurePreload(_currentIndex);
    } catch (e) {
      debugPrint('🔴 beer video feed load error: $e');
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
      _seed = null;
      _hasMore = true;
      _initialLoadDone = false;
      _error = null;
      _currentIndex = 0;
    });
    _seenVideoIds.clear();
    for (final e in _preloadCache.values) {
      e.controller.dispose();
    }
    _preloadCache.clear();
    await _loadMore();
  }

  void _onPageChanged(int index) {
    _currentIndex = index;
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
      color: Colors.white,
      backgroundColor: Colors.black,
      onRefresh: _refresh,
      child: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        allowImplicitScrolling: true,
        itemCount: _items.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final item = _items[index];
          return _BeerReelItem(
            key: ValueKey(item.id.isNotEmpty ? item.id : index),
            item: item,
            preloadTake: () => _takePreload(index),
            onBroken: () => _removeBrokenItem(item),
          );
        },
      ),
    );
  }

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
      ],
    );
  }
}

// ─── Giới hạn số video chạy đồng thời — cùng nguyên tắc newsfeed_page.dart
// (2 slot: video đang xem + video đang mồi sẵn) để tránh crash MediaCodec
// khi vuốt nhanh qua nhiều video. Tách riêng khỏi limiter của Newsfeed vì
// đây là 2 trang/2 vòng đời widget khác nhau.
class _BeerPlaybackLimiter {
  static const int maxConcurrent = 2;
  static final List<_BeerReelItemState> _active = [];

  static bool requestSlot(_BeerReelItemState s) {
    if (_active.contains(s)) return true;
    if (_active.length >= maxConcurrent) {
      final old = _active.removeAt(0);
      old._teardown();
    }
    _active.add(s);
    return true;
  }

  static void release(_BeerReelItemState s) {
    _active.remove(s);
  }
}

class _BeerReelItem extends StatefulWidget {
  final BeerVideoItem item;
  final _PreloadEntry? Function()? preloadTake;
  final VoidCallback? onBroken;

  const _BeerReelItem({
    super.key,
    required this.item,
    this.preloadTake,
    this.onBroken,
  });

  @override
  State<_BeerReelItem> createState() => _BeerReelItemState();
}

class _BeerReelItemState extends State<_BeerReelItem> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _error = false;
  bool _initializing = false;
  bool _visible = false;
  bool _muted = false;
  final Key _visibilityKey = UniqueKey();

  // Icon play/pause/mute hiện thoáng qua giữa màn hình rồi tự ẩn — phản
  // hồi cho người dùng biết vừa bấm gì, KHÔNG phải nút cố định trên màn.
  IconData? _flashIcon;

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
    _BeerPlaybackLimiter.requestSlot(this);
    _initializing = true;

    try {
      VideoPlayerController ctrl;
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
        _BeerPlaybackLimiter.release(this);
        _initializing = false;
        return;
      }

      if (autoplay) {
        await ctrl.play();
      }

      setState(() {
        _controller = ctrl;
        _ready = true;
      });
    } catch (e) {
      debugPrint('🔴 beer reel init error: $e');
      _BeerPlaybackLimiter.release(this);
      if (mounted) setState(() => _error = true);
      widget.onBroken?.call();
    } finally {
      _initializing = false;
    }
  }

  void _teardown() {
    _BeerPlaybackLimiter.release(this);
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

  // Chạm giữa màn hình 1 lần: play/pause.
  void _togglePlayPause() {
    final ctrl = _controller;
    if (ctrl == null) return;
    setState(() {
      if (ctrl.value.isPlaying) {
        ctrl.pause();
        _flashIcon = Icons.play_arrow_rounded;
      } else {
        ctrl.play();
        _flashIcon = Icons.pause_rounded;
      }
    });
    _autoHideFlashIcon();
  }

  // Chạm 2 ngón / icon loa nhỏ ở góc để bật-tắt tiếng — dùng 1 lần chạm ở
  // rìa phải màn hình để không đụng gesture play/pause ở giữa.
  void _toggleMute() {
    final ctrl = _controller;
    setState(() {
      _muted = !_muted;
      ctrl?.setVolume(_muted ? 0 : 1);
      _flashIcon = _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded;
    });
    _autoHideFlashIcon();
  }

  void _autoHideFlashIcon() {
    Future.delayed(const Duration(milliseconds: 550), () {
      if (mounted) setState(() => _flashIcon = null);
    });
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: _onVisibilityChanged,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black),
          if (_ready && _controller != null)
            GestureDetector(
              onTap: _togglePlayPause,
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _controller!.value.size.width,
                  height: _controller!.value.size.height,
                  child: VideoPlayer(_controller!),
                ),
              ),
            )
          else if (_error)
            const SizedBox.shrink() // video lỗi -> đã tự gỡ khỏi feed
          else
            shimmer.Shimmer(
              period: const Duration(milliseconds: 1400),
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.white.withOpacity(0.08),
                  Colors.transparent,
                ],
                stops: const [0.35, 0.5, 0.65],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              child: Container(color: Colors.black),
            ),

          // Icon phản hồi thoáng qua (play/pause/mute) — tự ẩn sau ~0.5s.
          if (_flashIcon != null)
            Center(
              child: AnimatedOpacity(
                opacity: _flashIcon != null ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_flashIcon, color: Colors.white, size: 44),
                ),
              ),
            ),

          // Dải chạm mỏng ở rìa phải để bật/tắt tiếng, không đè lên vùng
          // chạm play/pause ở giữa màn hình.
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 56,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _toggleMute,
            ),
          ),
        ],
      ),
    );
  }
}