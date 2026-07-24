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

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    final meta = (product['meta'] is Map) ? product['meta'] as Map : {};
    final metaData = (product['meta_data'] is List) ? product['meta_data'] as List : [];

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
      backgroundColor: const Color(0xFF0D0B10),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Thiệp mời kèo', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
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
                        backgroundColor: const Color(0xFFFF6B35),
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
  });

  static const _gold = Color(0xFFFFC94D);
  static const _orange = Color(0xFFFF6B35);
  static const _cardBg1 = Color(0xFF1B1220);
  static const _cardBg2 = Color(0xFF3A1B12);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
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
          gradient: const LinearGradient(
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
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF3A1B12), Color(0xFF6B2E12), _orange],
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
          errorBuilder: (_, __, ___) => const Icon(Icons.sports_bar_rounded, size: 18, color: _orange),
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
      child: Text(
        text,
        style: const TextStyle(
          color: _gold,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
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
                  errorBuilder: (_, __, ___) => const Icon(Icons.sports_bar_rounded, size: 16, color: _gold),
                ),
              ),
              const SizedBox(width: 6),
              const Text(
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