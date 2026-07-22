import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import 'package:cached_network_image/cached_network_image.dart';
// 🆕 url_launcher dùng để mở "Xem bản đồ quán" ra Google Maps.
// ⚠️ Nếu project chưa có package này, cần thêm vào pubspec.yaml:
//    url_launcher: ^6.2.0
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';
import '../helpers/storage_helper.dart';
import 'product_detail_page.dart';
import 'chat_page.dart';
import 'user_info_page.dart';

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

// 🆕 Chuyển "price_range" (giống hệt shop_page.dart) sang text hiển thị.
String priceRangeToText(String? priceRange) {
  switch (priceRange) {
    case null:
    case '':
    case '0':
      return "Miễn phí";
    case '50-100':
      return "50k - 100k";
    case '100-200':
      return "100k - 200k/Người";
    case '200-500':
      return "200k - 500k/Người";
    case '500+':
      return "500k+/Người";
    default:
      return priceRange;
  }
}

class NewsfeedVideoItem {
  final String id;
  final String url;
  final String filename;
  final DateTime? uploadedAt;

  // 🆕 Dữ liệu "kèo" (product) mà video này gắn vào — dùng để: bấm Tham
  // gia -> mở ProductDetailPage, hiện avatar/tên host, giờ, giá, khoảng
  // cách, và mở bản đồ quán. `product` giữ nguyên Map gốc (đúng format
  // mà ProductDetailPage đang cần: id, name, meta, meta_data,
  // participants, joined_count...) để tái sử dụng thẳng, không phải
  // build lại logic parse product ở 2 nơi.
  // ⚠️ Nếu API /newsfeed-videos hiện tại CHƯA trả field liên kết kèo,
  // các phần UI liên quan (avatar/tên/giờ/giá/nút Tham gia/Bản đồ) sẽ tự
  // ẩn đi (xem `hasProduct`) — cần bổ sung field này ở backend để hiện
  // đầy đủ.
  final Map<String, dynamic>? product;

  NewsfeedVideoItem({
    required this.id,
    required this.url,
    required this.filename,
    this.uploadedAt,
    this.product,
  });

  factory NewsfeedVideoItem.fromJson(Map<String, dynamic> json) {
    // 🔍 DEBUG TẠM — xoá dòng này sau khi kiểm tra xong.
    debugPrint("🔍 newsfeed item keys: ${json.keys.toList()}");
    DateTime? uploaded;
    try {
      uploaded = DateTime.tryParse(json['uploaded_at']?.toString() ?? '');
    } catch (_) {}

    // Ưu tiên nếu backend đã trả sẵn 1 object 'product' đầy đủ (giống
    // format của WooCommerce product mà shop_page đang parse).
    Map<String, dynamic>? product;
    if (json['product'] is Map) {
      product = Map<String, dynamic>.from(json['product'] as Map);
    } else if (json['keo_id'] != null || json['product_id'] != null) {
      // Hoặc backend trả rời từng field (keo_id, creator_id, time, ...)
      // -> tự ráp lại thành 1 Map product tối giản, đủ cho UI newsfeed.
      // (ProductDetailPage cần đủ field hơn -> khi mở trang chi tiết,
      // ProductDetailPage nên tự fetch lại theo id nếu Map này thiếu.)
      product = {
        'id': json['keo_id'] ?? json['product_id'],
        'name': json['keo_name'] ?? json['product_name'] ?? '',
        'joined_count': json['joined_count'] ?? 0,
        'participants': json['participants'] ?? [],
        'meta': {
          'creator_id': json['creator_id']?.toString() ?? '0',
          'time': json['time']?.toString() ?? '',
          'pub_name': json['pub_name']?.toString() ?? '',
          'address': json['address']?.toString() ?? '',
          'lat': json['lat'],
          'lng': json['lng'],
        },
        'meta_data': [
          {'key': 'price_range', 'value': json['price_range']?.toString() ?? ''},
          {'key': 'slots', 'value': json['slots']?.toString() ?? ''},
        ],
        'creatorName': json['creator_name']?.toString() ?? '',
        'creatorAvatar': json['creator_avatar']?.toString() ?? '',
        'distanceText': json['distance_text']?.toString() ?? '',
        // 🆕 Tên thể loại (product_cat), dùng để tô màu nút/chip đồng bộ
        // với logic _getCategoryColor bên shop_page.dart.
        'categoryNames': json['category_names']?.toString() ?? '',
      };
    }

    return NewsfeedVideoItem(
      id: json['id']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      uploadedAt: uploaded,
      product: product,
    );
  }

  bool get hasProduct => product != null;
  String get productId => product?['id']?.toString() ?? '';
  Map<String, dynamic> get _meta =>
      (product?['meta'] as Map?)?.cast<String, dynamic>() ?? {};
  String get creatorId => _meta['creator_id']?.toString() ?? '0';
  String get creatorName =>
      (product?['creatorName'] as String?)?.trim().isNotEmpty == true
          ? product!['creatorName']
          : 'Người dùng';
  String get creatorAvatar => (product?['creatorAvatar'] as String?) ?? '';
  String get timeText => _meta['time']?.toString() ?? '';
  String get address => _meta['address']?.toString() ?? '';
  String get pubName => _meta['pub_name']?.toString() ?? '';
  double? get lat => double.tryParse(_meta['lat']?.toString() ?? '');
  double? get lng => double.tryParse(_meta['lng']?.toString() ?? '');
  String get distanceText => (product?['distanceText'] as String?) ?? '';
  String get categoryNames => (product?['categoryNames'] as String?) ?? '';
  // Thể loại "chính" để tô màu nút/chip — cùng thứ tự ưu tiên
  // (_categoryTagPriority) như shop_page.dart: Nhậu > Karaoke > Bar/Pub > Beer.
  String get primaryCategory {
    final list = categoryNames
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (list.isEmpty) return '';
    list.sort((a, b) => _categoryTagPriority(a).compareTo(_categoryTagPriority(b)));
    return list.first;
  }
  String get priceText {
    final metaData = (product?['meta_data'] as List?) ?? [];
    Map? range;
    for (final e in metaData) {
      if (e is Map && e['key'] == 'price_range') {
        range = e;
        break;
      }
    }
    return priceRangeToText(range?['value']?.toString());
  }
}

// 🎨 Sao chép nguyên logic màu theo thể loại từ shop_page.dart, để nút
// Chat/Tham gia và chip thể loại trong newsfeed đồng bộ màu với shop_page
// (🎤 Karaoke, 🍸 Bar/Pub, 🍻 Beer Club, 🍻 Nhậu).
int _categoryTagPriority(String rawName) {
  final text = rawName.trim().toLowerCase();
  if (text.contains('nhậu') || text.contains('nhau')) return 0;
  if (text.contains('karaoke')) return 1;
  if (text.contains('bar') || text.contains('pub')) return 2;
  if (text.contains('beer')) return 3;
  return 99;
}

Color _getCategoryColor(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('karaoke')) return const Color(0xFFFF7F50); // cam, đồng bộ tone accentOrange của app
  if (lower.contains('beer')) return const Color(0xFFFFC107); // vàng hổ phách
  if (lower.contains('nhậu')) return Colors.lightGreen;
  if (lower.contains('bar') || lower.contains('pub')) return Colors.cyan;
  return Colors.white70;
}

List<Color> _getCategoryGradient(String text) {
  final base = _getCategoryColor(text);
  final hsl = HSLColor.fromColor(base);
  final darker = hsl.withLightness((hsl.lightness - 0.18).clamp(0.0, 1.0)).toColor();
  return [base, darker];
}

// 🆕 Sao chép nguyên logic parseProduct() bên shop_page.dart — chuẩn hoá
// JSON product thô từ WooCommerce REST (meta_data dạng list -> Map 'meta'
// phẳng, tách participants/joined_count, category_names, images...) thành
// đúng format mà ProductDetailPage đang cần. Dùng khi mở chi tiết từ
// newsfeed để có ĐẦY ĐỦ dữ liệu giống hệt lúc mở từ shop_page, thay vì
// Map tối giản tự ráp từ /newsfeed-videos (thiếu images, description...).
Map<String, dynamic> _parseWooProduct(dynamic p) {
  final Map<String, dynamic> productMap = Map<String, dynamic>.from(p as Map);

  Map<String, dynamic> meta = {};
  List participants = [];

  if (productMap['meta_data'] != null && productMap['meta_data'] is List) {
    for (var m in productMap['meta_data']) {
      if (m is Map && m.containsKey('key') && m.containsKey('value')) {
        final key = m['key'];
        final value = m['value'];
        meta[key] = value;
        if (key == 'participants') {
          if (value is List) {
            participants = List.from(value);
          } else if (value is String && value.isNotEmpty) {
            try {
              participants = jsonDecode(value);
            } catch (_) {
              participants = [];
            }
          }
        }
      }
    }
  }

  productMap['meta'] = meta;
  productMap['participants'] = participants;
  productMap['joined_count'] = participants.length;

  productMap['party_media_image_url'] =
      productMap['party_media_image_url']?.toString() ?? '';
  productMap['party_media_video_url'] =
      productMap['party_media_video_url']?.toString() ?? '';

  if (productMap['categories'] != null && productMap['categories'] is List) {
    productMap['category_names'] =
        (productMap['categories'] as List).map((c) => c['name']).join(', ');
  } else {
    productMap['category_names'] = '';
  }

  if (productMap['images'] != null && productMap['images'] is List) {
    final imgs = <Map<String, String>>[];
    for (var img in productMap['images']) {
      if (img is String) {
        imgs.add({'src': img});
      } else if (img is Map && img.containsKey('src')) {
        imgs.add({'src': img['src'].toString()});
      }
    }
    productMap['images'] = imgs;
  } else {
    productMap['images'] = [];
  }

  return productMap;
}

class NewsfeedPage extends StatefulWidget {
  // 🆕 Khi mở Newsfeed từ 1 card cụ thể (nút "Xem Newsfeed" trong
  // shop_page.dart), truyền vào id của kèo/product đó -> trang sẽ tự
  // tải thêm trang cho tới khi tìm thấy đúng video gắn với kèo này rồi
  // nhảy thẳng tới (jumpToPage), thay vì luôn mở ở video đầu feed.
  // Để null nếu chỉ muốn mở feed bình thường (không nhảy tới đâu cả).
  final int? initialProductId;

  const NewsfeedPage({super.key, this.initialProductId});

  @override
  State<NewsfeedPage> createState() => _NewsfeedPageState();
}

class _NewsfeedPageState extends State<NewsfeedPage> {
  final List<NewsfeedVideoItem> _items = [];
  // 🔧 FIX "nhảy qua 1 id khác rồi mới nhảy đúng id": trước đây
  // PageController được tạo sẵn (mặc định trang 0) và PageView được build
  // ngay khi _items không rỗng, trong lúc _findAndJumpToTarget còn đang
  // tải thêm trang để tìm đúng video -> người dùng thấy video đầu tiên
  // hiện ra 1 nhịp rồi mới bị "giật" sang đúng video (jumpToPage ở frame
  // sau). Giờ controller chỉ được tạo (với đúng initialPage) SAU KHI đã
  // xác định được index cần tới -> feed hiện ra là đúng ngay, không còn
  // cảnh nhảy 2 lần.
  PageController? _pageController;

  // 🆕 Ghi nhớ video 'id' đã từng thấy (KHÔNG phải productId) để phát
  // hiện khi server trả về TOÀN video trùng lặp ở 1 lần tải — dấu hiệu
  // pool video thật sự đã hết nhưng backend vẫn báo has_more=true (xem
  // giải thích chi tiết ở _loadMore). Dùng để: (1) không hiện video
  // trùng khi cuộn feed bình thường, (2) tự dừng vòng lặp tìm target
  // sớm thay vì tin suông vào has_more của server.
  final Set<String> _seenVideoIds = {};

  // 🆕 Ghi lại response gần nhất của _loadMore() (dạng đã decode JSON) để
  // _findAndJumpToTarget có thể đọc field 'target_found' ngay sau khi
  // await xong, mà không phải đổi kiểu trả về Future<void> của
  // _loadMore ở khắp nơi khác đang gọi nó (onPageChanged, initState...).
  Map<String, dynamic>? _lastLoadResponse;

  int _page = 1;
  int? _seed; // giữ nguyên trong cả phiên để random nhưng không lặp/thiếu giữa các trang
  bool _loading = false;
  bool _hasMore = true;
  bool _initialLoadDone = false;
  String? _error;
  int _currentIndex = 0;

  // 🆕 Trạng thái tìm & nhảy tới đúng kèo (xem widget.initialProductId).
  bool _jumpedToTarget = false;
  // Tải tối đa chừng này trang để tìm kèo mục tiêu trước khi bỏ cuộc,
  // tránh vòng lặp gọi API vô tận nếu kèo đó không có video trong feed.
  // 🔧 Giảm từ 30 -> 12: với cơ chế phát hiện "toàn trùng lặp" trong
  // _loadMore ở dưới, đây giờ chỉ còn là lưới an toàn cuối cùng (phòng
  // trường hợp server trộn lẫn ít video mới với nhiều video cũ mỗi lần,
  // nên chưa bị chặn bởi cơ chế trùng lặp) — không cần cao như trước vì
  // đằng nào cũng đã có chặn sớm hơn ở phần lớn các trường hợp.
  static const int _maxSearchPages = 12;

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
    final item = _items[idx];
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(item.url));
    final ready = ctrl.initialize().then((_) async {
      await ctrl.setLooping(true);
      await ctrl.setVolume(0);
    }).catchError((e) {
      debugPrint('🔴 preload lỗi idx=$idx: $e');
      // Video lỗi ngay từ lúc mồi trước -> bỏ hẳn kèo này khỏi feed,
      // không cần đợi người dùng vuốt tới mới phát hiện video hỏng.
      _preloadCache.remove(idx)?.controller.dispose();
      _removeBrokenItem(item);
    });
    _preloadCache[idx] = _PreloadEntry(ctrl, ready);
  }

  _PreloadEntry? _takePreload(int idx) => _preloadCache.remove(idx);

  // 🆕 "Ko lấy những kèo có video lỗi" — khi 1 video không tải/play được
  // (lỗi lúc mồi trước hoặc lỗi lúc thật sự phát), gỡ luôn kèo đó khỏi
  // danh sách newsfeed thay vì hiện icon "video lỗi" đứng yên cho người
  // dùng thấy.
  //
  // ⚠️ 2 điều PHẢI cẩn thận để không gây giật/khựng khi vuốt:
  // 1) Nếu kèo bị gỡ nằm TRƯỚC video đang xem (trường hợp video được
  //    mồi trước bị lỗi), index của video đang xem sẽ bị lệch xuống 1
  //    -> phải lùi `_currentIndex` + `jumpToPage` theo, nếu không
  //    PageView sẽ tự "nhảy" sang video kế tiếp dù người dùng chưa vuốt.
  // 2) KHÔNG huỷ sạch toàn bộ cache mồi rồi mồi lại từ đầu — chỉ dịch
  //    lại key của các controller ĐÃ mồi sẵn theo vị trí mới (giữ
  //    nguyên, không tải/khởi tạo lại), tránh hàng loạt ExoPlayer
  //    Init/Release dồn dập cùng lúc (nguyên nhân gây giật/khựng).
  void _removeBrokenItem(NewsfeedVideoItem item) {
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

    // Dịch lại key trong cache mồi theo vị trí mới, KHÔNG dispose các
    // controller còn tốt — chỉ huỷ đúng entry của kèo vừa bị gỡ (nếu có).
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

    // Giữ đúng video đang xem, không để PageView tự lệch trang do index
    // trong danh sách đã dịch lại.
    if (_items.isNotEmpty &&
        _pageController != null &&
        _pageController!.hasClients &&
        _pageController!.page?.round() != _currentIndex) {
      _pageController!.jumpToPage(_currentIndex);
    }

    _ensurePreload(_currentIndex);
    // Vừa mất bớt item -> nếu sắp cạn danh sách thì tải thêm luôn.
    if (_hasMore && !_loading && _items.length - _currentIndex < 4) {
      _loadMore();
    }
  }

  @override
  void dispose() {
    _pageController?.dispose();
    for (final e in _preloadCache.values) {
      e.controller.dispose();
    }
    _preloadCache.clear();
    super.dispose();
  }

  // 🆕 Chuẩn hoá id trước khi so sánh: tránh lệch do khoảng trắng thừa
  // hoặc do 1 bên là "12" và bên kia là "12.0"/"12 " (num.tryParse rồi
  // ép về int nếu là số nguyên hợp lệ).
  String _normalizeId(String raw) {
    final trimmed = raw.trim();
    final n = num.tryParse(trimmed);
    if (n != null) return n.toInt().toString();
    return trimmed;
  }

  // 🆕 THAY CHO _jumpWhenReady: thay vì tạo PageController từ trang 0 rồi
  // gọi jumpToPage sau (khiến người dùng thấy video sai hiện ra 1 nhịp
  // trước khi bị "giật" sang đúng video), giờ ta CHỈ tạo PageController
  // (với initialPage = đúng index cần tới) ngay lúc này -> PageView khi
  // build lần đầu đã mở đúng ngay video mục tiêu, không còn cảnh nhảy 2
  // lần / lộ video khác trước đó.
  void _revealFeed(int initialIndex) {
    if (!mounted) return;
    setState(() {
      _pageController = PageController(initialPage: initialIndex);
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialProductId != null) {
      _findAndJumpToTarget(widget.initialProductId!);
    } else {
      _pageController = PageController();
      _loadMore();
    }
  }

  // 🆕 TỐI ƯU TỐC ĐỘ "NHẢY": trước đây phải dò tuần tự nhiều trang (mỗi
  // trang = 1 round-trip mạng riêng, chờ nối tiếp nhau) cho tới khi gặp
  // đúng video -> nếu video nằm ở trang 8-9 thì cực chậm. GIỜ: gọi
  // backend đúng 1 LẦN kèm `initial_product_id` (xem
  // functions.php::nhau_get_newsfeed_videos) — server tự tìm trong
  // TOÀN BỘ pool video (chỉ tốn 1 vòng lặp PHP nội bộ, không thêm round
  // trip nào) rồi đẩy video đó lên đầu trang 1 trước khi trả về. Vậy
  // nên dù pool có hàng ngàn video, ta cũng chỉ cần đúng 1 lượt gọi API
  // để biết ngay có tìm thấy hay không.
  Future<void> _findAndJumpToTarget(int targetProductId) async {
    final targetIdStr = _normalizeId(targetProductId.toString());

    await _loadMore(initialProductId: targetProductId);
    if (!mounted) return;

    final response = _lastLoadResponse;
    // `target_found` chỉ xuất hiện khi backend đã được cập nhật để hiểu
    // param `initial_product_id`. Dùng containsKey (không phải chỉ check
    // giá trị) để phân biệt "backend cũ, chưa có field này" (cần fallback
    // dò tuần tự) với "backend mới, tìm nhưng không thấy" (found=false,
    // không cần dò thêm vì server đã quét hết pool rồi).
    final bool backendSupportsTarget =
        response != null && response.containsKey('target_found');

    if (backendSupportsTarget) {
      final bool found = response!['target_found'] == true;
      _jumpedToTarget = true;
      if (found) {
        final idx = _items.indexWhere(
              (it) => it.hasProduct && _normalizeId(it.productId) == targetIdStr,
        );
        if (idx != -1) {
          _currentIndex = idx;
          _ensurePreload(idx);
          _revealFeed(idx);
          return;
        }
      }
      _showTargetNotFoundAndReveal();
      return;
    }

    // 🔧 TƯƠNG THÍCH NGƯỢC: backend chưa deploy bản mới (không hiểu param
    // `initial_product_id`, không trả `target_found`) -> quay về cách dò
    // tuần tự từng trang như cũ, để tính năng không bị vỡ trong lúc 2
    // phía (Flutter/backend) chưa kịp lên đồng thời.
    int safety = 0;
    while (mounted && !_jumpedToTarget && safety < _maxSearchPages) {
      final idx = _items.indexWhere(
            (it) => it.hasProduct && _normalizeId(it.productId) == targetIdStr,
      );
      if (idx != -1) {
        _jumpedToTarget = true;
        _currentIndex = idx;
        _ensurePreload(idx);
        _revealFeed(idx);
        return;
      }
      if (!_hasMore) break;
      await _loadMore();
      safety++;
    }

    _jumpedToTarget = true;
    if (!mounted) return;
    _showTargetNotFoundAndReveal();
  }

  // Hiện feed từ đầu (trang 0) kèm thông báo không tìm thấy video mục
  // tiêu — dùng chung cho cả 2 nhánh (fast path lẫn fallback) ở trên.
  void _showTargetNotFoundAndReveal() {
    _revealFeed(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Không tìm thấy video của kèo này trong newsfeed"),
        ),
      );
    });
  }


  Future<void> _loadMore({int? initialProductId}) async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);

    try {
      final seedParam = _seed != null ? '&seed=$_seed' : '';
      // 🆕 Chỉ gửi param này ở lượt gọi "tìm mục tiêu" đầu tiên (page=1) —
      // xem giải thích chi tiết ở _findAndJumpToTarget và ở backend
      // (functions.php::nhau_get_newsfeed_videos).
      final targetParam = initialProductId != null
          ? '&initial_product_id=$initialProductId'
          : '';
      final uri = Uri.parse(
        '${AppConfig.webDomain}/wp-json/nhau/v1/newsfeed-videos?page=$_page&per_page=10$seedParam$targetParam',
      );
      final res = await http.get(uri);

      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }

      final data = jsonDecode(res.body);
      _lastLoadResponse = data is Map<String, dynamic> ? data : null;
      final List<dynamic> rawItems = data['items'] ?? [];
      final parsedItems = rawItems
          .map((e) => NewsfeedVideoItem.fromJson(e as Map<String, dynamic>))
          .toList();

      // 🆕 Lọc trùng lặp theo video 'id': trong thực tế đã gặp trường hợp
      // server (random theo seed) trả lại đúng những video đã có ở
      // trang trước — có thể do pool video thật sự đã gần cạn dù
      // `has_more` server vẫn báo true (xem log: cùng 1 productId lặp
      // lại chỉ sau ~10-20 video đã tải). Chỉ thêm vào `_items` những
      // video có id CHƯA từng thấy, để:
      // 1) Cuộn feed bình thường không bị hiện lại video trùng.
      // 2) `_findAndJumpToTarget` không phí công quét lại y hệt dữ liệu
      //    cũ nhiều lần khi tìm 1 productId không tồn tại trong feed.
      final newItems = <NewsfeedVideoItem>[];
      for (final item in parsedItems) {
        // id rỗng -> không track được, cứ thêm để giữ hành vi cũ (an
        // toàn hơn là lỡ loại bỏ nhầm video hợp lệ).
        if (item.id.isEmpty || _seenVideoIds.add(item.id)) {
          newItems.add(item);
        }
      }

      // Trang này CÓ dữ liệu trả về nhưng sau khi lọc trùng thì không
      // còn video nào mới -> coi như pool video đã cạn thật sự, tự dừng
      // thay vì tin suông vào `has_more` của server (tránh vòng lặp
      // tải/preload vô ích).
      final bool exhausted = rawItems.isNotEmpty && newItems.isEmpty;

      setState(() {
        _items.addAll(newItems);
        _hasMore = exhausted ? false : (data['has_more'] == true);
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
    // 🆕 Reset luôn danh sách id đã thấy — feed được random lại từ đầu
    // (seed mới) nên các video "cũ" giờ lại hợp lệ để hiện ra lần nữa.
    _seenVideoIds.clear();
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
    // 🔧 Quan trọng: nếu _pageController CHƯA được tạo (đang tìm trang
    // chứa đúng video mục tiêu — xem _findAndJumpToTarget), TUYỆT ĐỐI
    // không build PageView dù _items đã có sẵn vài video từ các trang đã
    // tải, nếu không người dùng sẽ thấy video ở trang 0 hiện ra 1 nhịp
    // trước khi bị nhảy sang đúng video (đây là lỗi "nhảy qua 1 id khác
    // rồi mới nhảy đúng id" đã báo).
    if (_pageController == null) {
      return _buildInitialShimmer();
    }

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
        controller: _pageController!,
        scrollDirection: Axis.vertical,
        // Giữ sẵn trang liền kề trong cây widget thay vì dựng lại từ đầu
        // mỗi lần vuốt tới — giảm hẳn cảm giác khựng khi chuyển video.
        allowImplicitScrolling: true,
        itemCount: _items.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final item = _items[index];
          return _ReelItem(
            key: ValueKey(item.id.isNotEmpty ? item.id : index),
            item: item,
            preloadTake: () => _takePreload(index),
            onBroken: () => _removeBrokenItem(item),
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
  // 🆕 Gọi lên feed cha khi video của kèo này lỗi (không tải/play được)
  // để feed cha gỡ hẳn kèo này khỏi danh sách — "ko lấy những kèo có
  // video lỗi".
  final VoidCallback? onBroken;
  const _ReelItem({super.key, required this.item, this.preloadTake, this.onBroken});

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

  // 🆕 Trạng thái cho các nút hành động (giống shop_page.dart)
  bool _isNavigating = false;
  bool _saved = false;
  bool _savingKeo = false;

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
      // Video lỗi -> báo cha gỡ hẳn kèo này khỏi feed thay vì đứng yên
      // với icon "video lỗi".
      widget.onBroken?.call();
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
    final item = widget.item;
    // 🆕 Nếu video có gắn kèo -> chia sẻ kèm thông tin kèo (giống
    // _shareKeo bên shop_page.dart) thay vì chỉ chia sẻ link video trơn.
    if (item.hasProduct) {
      final name = (item.product?['name'] ?? 'Kèo nhậu').toString();
      final link = "${AppConfig.webDomain}/quet-ma?keo_id=${item.productId}";
      final buffer = StringBuffer()
        ..writeln("🍻 $name")
        ..writeln();
      if (item.pubName.isNotEmpty) {
        buffer.writeln(
            "📍 ${item.pubName}${item.address.isNotEmpty ? ' - ${item.address}' : ''}");
      }
      if (item.timeText.isNotEmpty) buffer.writeln("🕒 ${item.timeText}");
      buffer.writeln("💰 ${item.priceText}");
      buffer.writeln();
      buffer.writeln("Tham gia kèo cùng mình nè 👇");
      buffer.writeln(link);
      Share.share(buffer.toString(), subject: name);
    } else {
      Share.share(item.url);
    }
  }

  // 🆕 Bấm "Tham gia" -> dẫn vào trang chi tiết kèo, y hệt hành vi bấm
  // vào card ngoài shop_page.dart.
  Future<void> _openDetail() async {
    final item = widget.item;
    if (!item.hasProduct) return;
    if (_isNavigating) return;
    _isNavigating = true;
    try {
      // 🆕 FIX: Map `item.product!` tự ráp từ /newsfeed-videos chỉ có
      // giá/giờ/địa chỉ/creator (tối giản) -> ProductDetailPage thiếu
      // images/description/đủ meta_data so với lúc mở từ shop_page (nơi
      // đã fetch đầy đủ qua WooCommerce REST + parseProduct()).
      // Ở đây fetch lại đúng 1 sản phẩm theo id, cùng endpoint + cách
      // parse như shop_page, rồi merge thêm creatorName/avatar/khoảng
      // cách đã có sẵn từ newsfeed (API Woo không trả các field này).
      Map<String, dynamic> fullProduct = item.product!;
      try {
        final res = await http.get(Uri.parse(
          "${AppConfig.webDomain}/wp-json/wc/v3/products/${item.productId}"
              "?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9"
              "&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8",
        ));
        if (res.statusCode == 200) {
          final parsed = _parseWooProduct(jsonDecode(res.body));
          parsed['creatorName'] = item.creatorName;
          parsed['creatorAvatar'] = item.creatorAvatar;
          parsed['distanceText'] = item.distanceText;
          // Cập nhật luôn vào cache của item (cùng reference) để lần
          // bấm tiếp theo không phải fetch lại, và các getter khác của
          // NewsfeedVideoItem (priceText, timeText...) vẫn đọc đúng.
          item.product!.addAll(parsed);
          fullProduct = item.product!;
        } else {
          debugPrint("⚠️ Fetch đầy đủ product lỗi HTTP ${res.statusCode}, dùng tạm dữ liệu tối giản.");
        }
      } catch (e) {
        debugPrint("❌ Lỗi fetch đầy đủ product trước khi mở detail: $e");
        // Fetch lỗi (mất mạng...) -> vẫn mở với Map tối giản đã có,
        // còn hơn không mở được trang chi tiết.
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ProductDetailPage(
            product: fullProduct,
            onJoin: (updatedProduct) {
              setState(() {
                item.product!['joined_count'] = updatedProduct['joined_count'];
                item.product!['participants'] = updatedProduct['participants'];
              });
            },
            onMediaAdded: (url, type) {
              setState(() {
                if (type == 'video') {
                  item.product!['party_media_video_url'] = url;
                } else {
                  item.product!['party_media_image_url'] = url;
                }
              });
            },
          ),
        ),
      );
    } finally {
      _isNavigating = false;
    }
  }

  // 🆕 Mở chat với người tạo kèo — tái sử dụng đúng luồng của
  // _openChat bên shop_page.dart (tự fetch avatar nếu thiếu).
  Future<void> _openChatWithCreator() async {
    final item = widget.item;
    if (!item.hasProduct) return;
    if (_isNavigating) return;
    _isNavigating = true;
    try {
      final myName = await StorageHelper.read("username") ?? "Ẩn danh";
      final myId = await StorageHelper.read("user_id") ?? "0";
      String avatarUrl = item.creatorAvatar;
      if (avatarUrl.isEmpty) {
        try {
          final res = await http.get(Uri.parse(
              "${AppConfig.webDomain}/wp-json/profile/v1/user/${item.creatorId}"));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            avatarUrl = data['avatar_url']?.toString() ?? '';
          }
        } catch (e) {
          debugPrint("❌ Lỗi fetch avatar trước khi chat: $e");
        }
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatPage(
            username: myName,
            userId: int.tryParse(myId) ?? 0,
            targetUser: item.creatorName,
            targetId: int.tryParse(item.creatorId) ?? 0,
            targetAvatar: avatarUrl,
            serverUrl: AppConfig.websocketUrl,
          ),
        ),
      );
    } finally {
      _isNavigating = false;
    }
  }

  // 🆕 Xem bản đồ quán: ưu tiên toạ độ lat/lng, nếu không có thì fallback
  // qua tìm kiếm theo địa chỉ/tên quán trên Google Maps.
  Future<void> _openMap() async {
    final item = widget.item;
    if (!item.hasProduct) return;

    Uri mapUri;
    if (item.lat != null && item.lng != null) {
      mapUri = Uri.parse(
          "https://www.google.com/maps/search/?api=1&query=${item.lat},${item.lng}");
    } else {
      final query = Uri.encodeComponent(
          item.address.isNotEmpty ? item.address : item.pubName);
      if (query.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Kèo này chưa có thông tin địa điểm.")),
        );
        return;
      }
      mapUri =
          Uri.parse("https://www.google.com/maps/search/?api=1&query=$query");
    }

    try {
      final ok = await launchUrl(mapUri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Không mở được bản đồ.")),
        );
      }
    } catch (e) {
      debugPrint("❌ _openMap error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Không mở được bản đồ.")),
        );
      }
    }
  }

  // 🆕 Bấm avatar/tên người tạo -> mở trang thông tin của họ (giống
  // GestureDetector bọc avatar+tên trong card của shop_page.dart).
  Future<void> _openCreatorProfile() async {
    final item = widget.item;
    if (!item.hasProduct) return;
    final myId = await StorageHelper.read("user_id") ?? "0";
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserInfoPage(
          userId: int.tryParse(myId) ?? 0,
          username: item.creatorName,
          targetUserId: int.tryParse(item.creatorId) ?? 0,
          avatarUrl: item.creatorAvatar,
        ),
      ),
    );
  }

  // 🆕 Lưu / bỏ lưu kèo. Đổi UI ngay (optimistic) cho mượt, âm thầm gọi
  // API lưu phía sau.
  // ⚠️ Endpoint '/wp-json/nhau/v1/save-keo' là TÊN GIẢ ĐỊNH — cần chỉnh
  // lại đúng route thật của backend (nếu backend đã có API "lưu kèo").
  Future<void> _toggleSaveKeo() async {
    final item = widget.item;
    if (!item.hasProduct || _savingKeo) return;

    final newSaved = !_saved;
    setState(() {
      _saved = newSaved;
      _savingKeo = true;
    });

    try {
      final token = await StorageHelper.read("jwt_token") ?? "";
      final res = await http.post(
        Uri.parse("${AppConfig.webDomain}/wp-json/nhau/v1/save-keo"),
        headers: {
          "Authorization": "Bearer $token",
          "Content-Type": "application/json",
        },
        body: jsonEncode({
          "product_id": item.productId,
          "action": newSaved ? "save" : "unsave",
        }),
      );
      if (res.statusCode != 200) {
        throw Exception("HTTP ${res.statusCode}");
      }
    } catch (e) {
      debugPrint("❌ _toggleSaveKeo error: $e");
      // Lưu thất bại -> rollback lại UI + báo nhẹ, không chặn trải
      // nghiệm xem video.
      if (mounted) {
        setState(() => _saved = !newSaved);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Chưa lưu được kèo, thử lại sau.")),
        );
      }
    } finally {
      if (mounted) setState(() => _savingKeo = false);
    }
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
            _buildCreatorInfo(), // 🆕 avatar/tên/giờ/giá góc trái dưới
            _buildCategoryBadge(), // 🆕 chip thể loại (Nhậu/Karaoke...) góc phải trên
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

  // 🆕 Cột nút hành động góc phải: Tham gia / Chat / Bản đồ / Chia sẻ /
  // Lưu kèo — giống bố cục cột nút bên phải của card trong shop_page.dart,
  // cộng thêm nút tắt/mở tiếng vốn có của reel.
  Widget _buildRightControls() {
    final item = widget.item;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final categoryGradient = _getCategoryGradient(item.primaryCategory);
    return Positioned(
      right: 12,
      bottom: 90 + safeBottom,
      child: Column(
        children: [
          _circleButton(
            icon: _muted ? Icons.volume_off : Icons.volume_up,
            onTap: _toggleMute,
          ),
          if (item.hasProduct) ...[
            const SizedBox(height: 14),
            _circleButton(
              icon: Icons.how_to_reg,
              onTap: _openDetail,
              tooltip: "Tham gia",
              gradient: categoryGradient,
            ),
            const SizedBox(height: 14),
            _circleButton(
              icon: Icons.chat_bubble,
              onTap: _openChatWithCreator,
              tooltip: "Chat với chủ kèo",
              // 🆕 Đổi màu theo thể loại của kèo (Nhậu=xanh lá,
              // Karaoke=cam, Bar/Pub=cyan, Beer=vàng) — cùng logic
              // _getCategoryGradient() bên shop_page.dart, thay vì màu
              // xanh lá cố định như trước.
              gradient: categoryGradient,
            ),
            const SizedBox(height: 14),
            _circleButton(
              icon: Icons.map,
              onTap: _openMap,
              tooltip: "Xem bản đồ quán",
            ),
            const SizedBox(height: 14),
            _circleButton(
              icon: _saved ? Icons.bookmark : Icons.bookmark_border,
              onTap: _toggleSaveKeo,
              tooltip: _saved ? "Bỏ lưu kèo" : "Lưu kèo",
              iconColor: _saved ? _accentOrange : Colors.white,
            ),
          ],
          const SizedBox(height: 14),
          _circleButton(icon: Icons.share, onTap: _share, tooltip: "Chia sẻ"),
        ],
      ),
    );
  }

  // 🆕 Chip thể loại (🍻 Nhậu, 🎤 Karaoke, Bar/Pub, Beer...) đặt ở GÓC
  // PHẢI PHÍA TRÊN màn hình (dưới nút back của trang, không đụng cột
  // nút hành động ở góc phải phía dưới). Trước đây chip này nằm ở góc
  // trái dưới cùng khối creator info — nay tách riêng lên trên để dễ
  // nhận diện thể loại ngay từ đầu, không phải kéo mắt xuống dưới.
  Widget _buildCategoryBadge() {
    final item = widget.item;
    if (!item.hasProduct || item.primaryCategory.isEmpty) {
      return const SizedBox.shrink();
    }
    final safeTop = MediaQuery.of(context).padding.top;
    return Positioned(
      top: safeTop + 8,
      right: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: _getCategoryColor(item.primaryCategory),
          borderRadius: BorderRadius.circular(100),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          item.primaryCategory,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: Colors.white,
            shadows: [Shadow(color: Colors.black45, blurRadius: 2, offset: Offset(0, 0.5))],
          ),
        ),
      ),
    );
  }

  // 🆕 Block avatar + tên host + khoảng cách/giờ + chi phí, đặt ở góc
  // trái phía dưới, phong cách đồng bộ với card trong shop_page.dart.
  Widget _buildCreatorInfo() {
    final item = widget.item;
    if (!item.hasProduct) return const SizedBox.shrink();
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return Positioned(
      left: 16,
      right: 84,
      bottom: 26 + safeBottom,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 🆕 Chip thể loại (Nhậu/Karaoke/Bar-Pub/Beer) đã chuyển lên
          // góc phải trên màn hình — xem _buildCategoryBadge().
          GestureDetector(
            onTap: _openCreatorProfile,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.white,
                  child: CircleAvatar(
                    radius: 13,
                    backgroundImage: item.creatorAvatar.isNotEmpty
                        ? CachedNetworkImageProvider(
                      item.creatorAvatar,
                      maxWidth: 52,
                      maxHeight: 52,
                    )
                        : null,
                    child: item.creatorAvatar.isEmpty
                        ? const Icon(Icons.person, size: 13)
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    item.creatorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                    ),
                  ),
                ),
                if (item.distanceText.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(100),
                      border: Border.all(color: Colors.white.withOpacity(0.25)),
                    ),
                    child: Text(
                      item.distanceText,
                      style: const TextStyle(
                          fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (item.timeText.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.access_time, size: 12, color: _accentOrange),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    item.timeText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: Colors.white70, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 3),
          Text(
            item.priceText,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    List<Color>? gradient,
    Color iconColor = Colors.white,
  }) {
    final button = GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: gradient == null ? Colors.black.withOpacity(0.35) : null,
          gradient: gradient != null
              ? LinearGradient(
            colors: gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
              : null,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: iconColor, size: 18),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: button) : button;
  }
}