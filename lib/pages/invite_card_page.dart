import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

import '../config/app_config.dart';

// ─────────────────────────────────────────────────────────────────────────
// 🎟️ THIỆP MỜI KÈO — growth loop chủ động
//
// Mỗi kèo tạo ra đều có thể sinh 1 "thiệp mời" (ảnh đẹp, giống thiệp sự
// kiện) kèm QR code dẫn thẳng tới trang cài app / mở kèo
// (`${AppConfig.webDomain}/quet-ma?keo_id=...`). Người nhận thiệp (kể cả
// chưa cài app) quét QR là thấy ngay nội dung kèo → có lý do thực để tải
// app → vòng lặp tự nuôi: càng nhiều kèo được tạo, càng nhiều thiệp được
// share ra ngoài, càng nhiều user mới vào.
//
// Cần thêm 2 package (chưa có sẵn trong dự án) vào pubspec.yaml:
//   qr_flutter: ^4.1.0        # vẽ QR code, thuần Dart, không cần platform code
//   path_provider: ^2.1.0     # lấy thư mục tạm để ghi ảnh PNG trước khi share
// (cached_network_image, share_plus, intl đã có sẵn trong dự án.)
// ─────────────────────────────────────────────────────────────────────────

class InviteCardPage extends StatefulWidget {
  final Map<String, dynamic> product;
  const InviteCardPage({super.key, required this.product});

  @override
  State<InviteCardPage> createState() => _InviteCardPageState();
}

// 🎨 Sao chép nguyên logic màu theo thể loại từ shop_page.dart (🎤 Karaoke,
// 🍸 Bar/Pub, 🍻 Beer Club, 🍻 Nhậu), để thiệp mời đồng bộ tông màu với
// card/chip thể loại hiển thị ở ShopPage/Newsfeed. category_names có thể là
// chuỗi gộp nhiều thể loại nên match theo "chứa" thay vì so khớp tuyệt đối.
Color _getCategoryColor(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('karaoke')) return const Color(0xFFF57C00); // cam, đồng bộ tone accentOrange của app
  if (lower.contains('beer')) return const Color(0xFFFFC107); // vàng hổ phách
  if (lower.contains('nhậu')) return Colors.lightGreen;
  if (lower.contains('bar') || lower.contains('pub')) return Colors.cyan;
  return const Color(0xFFFF6B35); // fallback: giữ tông cam gốc của thiệp khi không xác định được thể loại
}

// 🆕 Emoji đại diện thể loại, hiển thị trong chip category trên thiệp —
// cùng logic "match theo chứa" như _getCategoryColor() để nhất quán.
String _getCategoryEmoji(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('karaoke')) return '🎤';
  if (lower.contains('beer')) return '🍻';
  if (lower.contains('nhậu')) return '🍻';
  if (lower.contains('bar') || lower.contains('pub')) return '🍸';
  return '🎉';
}

class _InviteCardPageState extends State<InviteCardPage> {
  final GlobalKey _cardKey = GlobalKey();
  bool _isSharing = false;
  bool _isSaving = false;

  late final String _id;
  late final String _title;
  late final String _rawTime;
  late final String _pubName;
  late final String _address;
  late final String _priceText;
  late final int _slots;
  late final String _coverUrl;
  late final String _hostName;
  late final String _hostAvatar;
  late final String _link;
  late final Color _categoryColor;
  late final String _categoryLabel;

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    final meta = (product['meta'] is Map) ? product['meta'] as Map : {};
    final metaData = (product['meta_data'] is List) ? product['meta_data'] as List : [];

    // 🆕 Màu bên trong thiệp giờ "phai" theo màu thể loại của kèo (Nhậu/
    // Karaoke/Bar-Pub/Beer Club) — dùng đúng logic _getCategoryColor() đã
    // có sẵn ở shop_page.dart/newsfeed_page.dart để đồng bộ tông màu xuyên
    // suốt app, thay vì màu vàng-cam cố định như trước (không phân biệt
    // được kèo thể loại gì chỉ nhìn qua thiệp).
    final categoryNames = product['category_names']?.toString() ?? '';
    _categoryColor = _getCategoryColor(categoryNames);
    // 🆕 Nhãn thể loại hiển thị dạng chip trên thiệp (vd "🍻 Nhậu"). Nếu
    // category_names rỗng thì không hiện chip (xử lý ở _InviteCard).
    final trimmedCategoryNames = categoryNames.trim();
    _categoryLabel = trimmedCategoryNames.isEmpty
        ? ''
        : '${_getCategoryEmoji(trimmedCategoryNames)} $trimmedCategoryNames';

    _id = product['id']?.toString() ?? '';
    _title = (product['name'] ?? 'Kèo nhậu').toString();
    _rawTime = meta['time']?.toString() ?? '';
    _pubName = meta['pub_name']?.toString() ?? '';
    _address = meta['address']?.toString() ?? '';
    _slots = int.tryParse(meta['slots']?.toString() ?? '0') ?? 0;

    final priceRange = metaData.firstWhere(
          (e) => e is Map && e['key'] == 'price_range',
      orElse: () => null,
    )?['value'];
    _priceText = _formatPrice(priceRange);

    final rawImages = product['images'];
    final imagesList = rawImages is List ? rawImages : [];
    final firstImage = imagesList.isNotEmpty && imagesList.first is Map
        ? (imagesList.first['src']?.toString() ?? '')
        : '';
    _coverUrl = firstImage.isNotEmpty
        ? firstImage
        : (product['party_media_image_url']?.toString() ?? '');

    // 🔧 shop_page.dart đã tự gọi API profile/v1/users (fetchUsersBulk) và
    // gắn sẵn 'creatorName'/'creatorAvatar' vào product trước khi truyền
    // xuống đây — không tra UserCache vì class đó chưa từng được ghi dữ
    // liệu ở đâu trong app (luôn rỗng).
    final rawCreatorName = product['creatorName']?.toString() ?? '';
    _hostName = (rawCreatorName.isEmpty || rawCreatorName == '...')
        ? 'Người dùng'
        : rawCreatorName;
    _hostAvatar = product['creatorAvatar']?.toString() ?? '';

    _link = "${AppConfig.webDomain}/quet-ma?keo_id=$_id";
  }

  String _formatPrice(dynamic priceRange) {
    switch (priceRange) {
      case null:
      case '0':
        return 'Miễn phí';
      case '50-100':
        return '50k - 100k / người';
      case '100-200':
        return '100k - 200k / người';
      case '200-500':
        return '200k - 500k / người';
      case '500+':
        return '500k+ / người';
      default:
        return '$priceRange';
    }
  }

  String _formatTime() {
    if (_rawTime.isEmpty) return 'Đang cập nhật';
    try {
      final dt = DateTime.parse(_rawTime).toLocal();
      const weekdays = ['Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7', 'Chủ nhật'];
      final weekday = weekdays[dt.weekday - 1];
      return '$weekday, ${DateFormat('dd/MM').format(dt)} · ${DateFormat('HH:mm').format(dt)}';
    } catch (_) {
      return _rawTime;
    }
  }

  Future<Uint8List?> _renderCardToPng() async {
    try {
      final boundary = _cardKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return null;
      // Đợi 1 khoảng ngắn để đảm bảo ảnh mạng (cover, avatar) đã kịp vẽ
      // xong trước khi chụp — tránh thiệp bị thiếu ảnh khi mạng chậm.
      await Future.delayed(const Duration(milliseconds: 120));
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('❌ [InviteCard] _renderCardToPng: $e');
      return null;
    }
  }

  Future<File?> _writeTempPng(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/thiep_moi_keo_$_id.png');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> _shareCard() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final bytes = await _renderCardToPng();
      if (bytes == null) throw Exception('render thiệp thất bại (null bytes)');
      final file = await _writeTempPng(bytes);
      if (file == null) throw Exception('không ghi được file tạm');

      final caption = StringBuffer()
        ..writeln('🍻 $_title')
        ..writeln('Tham gia kèo cùng mình nè 👇')
        ..write(_link);

      await Share.shareXFiles(
        [XFile(file.path)],
        text: caption.toString(),
        subject: _title,
      );
    } catch (e) {
      debugPrint('❌ [InviteCard] _shareCard: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không tạo được thiệp, thử lại sau.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  Future<void> _saveCard() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final bytes = await _renderCardToPng();
      if (bytes == null) throw Exception('render thiệp thất bại (null bytes)');
      final file = await _writeTempPng(bytes);
      if (file == null) throw Exception('không ghi được file tạm');
      // App hiện chưa có plugin ghi thẳng vào thư viện ảnh
      // (vd image_gallery_saver) nên dùng share sheet hệ điều hành, nơi
      // luôn có sẵn nút "Lưu vào ảnh" trên cả iOS lẫn Android.
      await Share.shareXFiles([XFile(file.path)], text: 'Thiệp mời kèo "$_title"');
    } catch (e) {
      debugPrint('❌ [InviteCard] _saveCard: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không lưu được thiệp, thử lại sau.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Thiệp mời kèo', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        // 🆕 FIX (khoảng trắng trên cùng trang chia sẻ thiệp): AppBar để
        // backgroundColor: transparent nhưng KHÔNG có gì tô màu đằng sau nó —
        // phần gradient chỉ nằm trong `body`, bắt đầu NGAY DƯỚI AppBar, nên
        // cả dải status bar + toolbar phía trên chỉ lộ ra màu nền trắng mặc
        // định của Scaffold. Thêm flexibleSpace với đúng gradient của body để
        // lấp kín, không còn khoảng trắng nữa.
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF0D47A1), Color(0xFFF57C00)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0D47A1), Color(0xFFF57C00)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                    child: RepaintBoundary(
                      key: _cardKey,
                      child: _InviteCard(
                        title: _title,
                        timeText: _formatTime(),
                        pubName: _pubName,
                        address: _address,
                        priceText: _priceText,
                        slots: _slots,
                        coverUrl: _coverUrl,
                        hostName: _hostName,
                        hostAvatar: _hostAvatar,
                        qrData: _link,
                        categoryColor: _categoryColor,
                        categoryLabel: _categoryLabel,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSaving ? null : _saveCard,
                        icon: _isSaving
                            ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                        )
                            : const Icon(Icons.download_rounded, color: Colors.white70),
                        label: const Text('Lưu ảnh', style: TextStyle(color: Colors.white70)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _isSharing ? null : _shareCard,
                        icon: _isSharing
                            ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                            : const Icon(Icons.ios_share_rounded),
                        label: Text(_isSharing ? 'Đang tạo thiệp...' : 'Chia sẻ thiệp'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF57C00),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Widget thị giác của tấm thiệp — tách riêng để dễ tinh chỉnh / preview.
// ─────────────────────────────────────────────────────────────────────────
class _InviteCard extends StatelessWidget {
  final String title;
  final String timeText;
  final String pubName;
  final String address;
  final String priceText;
  final int slots;
  final String coverUrl;
  final String hostName;
  final String hostAvatar;
  final String qrData;
  // 🆕 Màu thể loại của kèo (Nhậu/Karaoke/Bar-Pub/Beer) — dùng để "nhuộm"
  // màu bên trong thiệp thay vì luôn cố định vàng-cam như trước, giúp nhìn
  // thiệp là biết ngay kèo thuộc thể loại gì.
  final Color categoryColor;
  // 🆕 Nhãn thể loại hiển thị dạng chip (vd "🍻 Nhậu"), rỗng thì ẩn chip.
  final String categoryLabel;

  const _InviteCard({
    required this.title,
    required this.timeText,
    required this.pubName,
    required this.address,
    required this.priceText,
    required this.slots,
    required this.coverUrl,
    required this.hostName,
    required this.hostAvatar,
    required this.qrData,
    required this.categoryColor,
    required this.categoryLabel,
  });

  // 🆕 Trước đây 4 màu này cố định (static const) — giờ tính theo
  // categoryColor nên phải chuyển thành getter theo từng instance. VÌ VẬY,
  // MỌI nơi sử dụng các getter này bên dưới đều KHÔNG được đánh dấu `const`
  // (kể cả các widget cha bao ngoài chúng), nếu không sẽ lỗi biên dịch
  // "Not a constant expression":
  //  - _gold: màu chữ/viền nhấn sáng — làm sáng categoryColor lên 1 chút để
  //    vẫn nổi rõ trên nền tối, thay vì luôn vàng.
  //  - _orange: màu nhấn đậm (badge, bóng đổ, viền khung) — chính là
  //    categoryColor gốc.
  //  - _cardBg1/_cardBg2: nền tối bên trong thiệp — giữ đúng hue của
  //    categoryColor nhưng hạ độ sáng thật thấp để chữ trắng vẫn đọc rõ
  //    (đây chính là chỗ "màu bên trong thiệp phai theo màu category").
  Color get _gold {
    final hsl = HSLColor.fromColor(categoryColor);
    return hsl.withLightness((hsl.lightness + 0.20).clamp(0.0, 1.0)).toColor();
  }

  Color get _orange => categoryColor;

  Color get _cardBg1 {
    final hue = HSLColor.fromColor(categoryColor).hue;
    return HSLColor.fromAHSL(1.0, hue, 0.45, 0.14).toColor();
  }

  Color get _cardBg2 {
    final hue = HSLColor.fromColor(categoryColor).hue;
    return HSLColor.fromAHSL(1.0, hue, 0.55, 0.07).toColor();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        // 🔧 Không được const vì _gold/_orange là getter theo instance.
        gradient: LinearGradient(
          colors: [_gold, _orange],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: _orange.withOpacity(0.35), blurRadius: 24, offset: const Offset(0, 12)),
        ],
      ),
      // Viền vàng-cam 2px bao quanh, bên trong là nền tối thật của thiệp.
      padding: const EdgeInsets.all(2),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          // 🔧 Không được const vì _cardBg1/_cardBg2 là getter theo instance.
          gradient: LinearGradient(
            colors: [_cardBg1, _cardBg2],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCover(),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  if (categoryLabel.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildCategoryChip(),
                  ],
                  const SizedBox(height: 12),
                  _buildHostRow(),
                  const SizedBox(height: 18),
                  _DashedDivider(color: Colors.white.withOpacity(0.18)),
                  const SizedBox(height: 16),
                  _InfoRow(icon: Icons.access_time_rounded, text: timeText),
                  if (pubName.isNotEmpty || address.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _InfoRow(
                      icon: Icons.location_on_rounded,
                      text: [pubName, address].where((s) => s.isNotEmpty).join(' - '),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: _InfoRow(icon: Icons.payments_rounded, text: priceText)),
                      if (slots > 0)
                        Expanded(child: _InfoRow(icon: Icons.groups_rounded, text: 'Còn $slots chỗ')),
                    ],
                  ),
                  const SizedBox(height: 22),
                  _buildQrSection(),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                      '🍻 Quét mã để xem & tham gia kèo',
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover() {
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (coverUrl.isNotEmpty)
            CachedNetworkImage(
              imageUrl: coverUrl,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _coverFallback(),
              placeholder: (_, __) => _coverFallback(),
            )
          else
            _coverFallback(),
          // Overlay gradient để chữ/badge phía trên luôn đọc rõ.
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.black.withOpacity(0.15),
                  _cardBg1.withOpacity(0.95),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.35, 1.0],
              ),
            ),
          ),
          Positioned(
            top: 14,
            left: 16,
            child: _buildBadge('🍻 BẠN ĐƯỢC MỜI'),
          ),
          Positioned(
            top: 14,
            right: 16,
            child: _buildLogoBadge(),
          ),
        ],
      ),
    );
  }

  Widget _coverFallback() {
    return Container(
      // 🔧 Không được const vì _orange là getter theo instance.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [const Color(0xFF3A1B12), const Color(0xFF6B2E12), _orange],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: 0.18,
            child: Icon(Icons.sports_bar_rounded, size: 140, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoBadge() {
    return Container(
      width: 36,
      height: 36,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: _gold.withOpacity(0.8), width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/images/logo.png',
          fit: BoxFit.contain,
          // 🔧 Không được const vì _orange là getter theo instance.
          errorBuilder: (_, __, ___) => Icon(Icons.sports_bar_rounded, size: 18, color: _orange),
        ),
      ),
    );
  }

  Widget _buildBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withOpacity(0.6)),
      ),
      // 🔧 Không được const vì _gold là getter theo instance.
      child: Text(
        text,
        style: TextStyle(
          color: _gold,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  // 🆕 Chip thể loại (vd "🍻 Nhậu") — nền phai theo categoryColor, đặt ngay
  // dưới tiêu đề để người nhận thiệp biết ngay kèo thuộc thể loại gì mà
  // không cần bấm vào QR. Không được const vì _orange/_gold là getter.
  Widget _buildCategoryChip() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _orange.withOpacity(0.18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _orange.withOpacity(0.5)),
        ),
        child: Text(
          categoryLabel,
          style: TextStyle(
            color: _gold,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }

  Widget _buildHostRow() {
    return Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: Colors.white24,
          backgroundImage: hostAvatar.isNotEmpty ? CachedNetworkImageProvider(hostAvatar) : null,
          child: hostAvatar.isEmpty
              ? const Icon(Icons.person, size: 16, color: Colors.white70)
              : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Chủ kèo: $hostName',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildQrSection() {
    return Center(
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Image.asset(
                  'assets/images/logo.png',
                  fit: BoxFit.contain,
                  // 🔧 Không được const vì _gold là getter theo instance.
                  errorBuilder: (_, __, ___) => Icon(Icons.sports_bar_rounded, size: 16, color: _gold),
                ),
              ),
              const SizedBox(width: 6),
              // 🔧 Không được const vì _gold là getter theo instance.
              Text(
                'KEOGO',
                style: TextStyle(
                  color: _gold,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(color: _orange.withOpacity(0.25), blurRadius: 16, offset: const Offset(0, 6))],
            ),
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 140,
              gapless: false,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF1B1220)),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF1B1220),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xFFFFC94D)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
          ),
        ),
      ],
    );
  }
}

class _DashedDivider extends StatelessWidget {
  final Color color;
  const _DashedDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const dashWidth = 6.0;
          const dashSpace = 5.0;
          final count = (constraints.maxWidth / (dashWidth + dashSpace)).floor();
          return Row(
            children: List.generate(
              count,
                  (_) => Padding(
                padding: const EdgeInsets.only(right: dashSpace),
                child: Container(width: dashWidth, height: 1, color: color),
              ),
            ),
          );
        },
      ),
    );
  }
}