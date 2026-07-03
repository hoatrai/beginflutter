import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/services.dart';
import 'map_page_select_location.dart';
import 'shop_page.dart';
import '../main.dart';
import '../helpers/storage_helper.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart' as shimmer;
import 'dart:math';
import '../config/app_config.dart';

// ─── DESIGN TOKENS ────────────────────────────────────────────────────────────
class _AppColors {
  // Card "nổi" trên nền gradient (vd: nền SnackBar)
  static const surface = Color(0xFF161B22);

  static const primary = Color(0xFFFF6B35);       // amber-orange accent
  static const primaryDim = Color(0x33FF6B35);

  static const textPrimary = Color(0xFFF0F6FC);

  static const success = Color(0xFF3FB950);
  static const error = Color(0xFFF85149);

  // Gradient nền (đồng bộ với UserInfoPage)
  static const bgGradientStart = Color(0xFF1E3A8A); // primaryBlue
  static const bgGradientEnd = Color(0xFFFF7F50);   // accentOrange

  // Nền đặc cho popup/menu nổi (dropdown, date/time picker) — tông cam đậm, cùng tone accent
  static const popupSurface = Color(0xFFB04A1F);
}

// ─── DATA MODELS ──────────────────────────────────────────────────────────────
class Category {
  final int id;
  final String name;
  final int parent;
  final String slug;
  Category({required this.id, required this.name, required this.parent, required this.slug});
}

class UploadImageItem {
  final File file;
  String? url;
  bool uploading;
  bool error;
  UploadImageItem({required this.file, this.url, this.uploading = true, this.error = false});
}

class UploadVideoItem {
  final File file;
  String? url;
  bool uploading;
  bool error;
  Uint8List? thumbnail;
  bool generatingThumb;
  UploadVideoItem({required this.file, this.url, this.uploading = true, this.error = false, this.thumbnail, this.generatingThumb = true});
}

// ─── MAIN WIDGET ──────────────────────────────────────────────────────────────
class CreateInvitePage extends StatefulWidget {
  const CreateInvitePage({super.key});
  @override
  State<CreateInvitePage> createState() => _CreateInvitePageState();
}

class _CreateInvitePageState extends State<CreateInvitePage> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _slotsController = TextEditingController();
  final _addressController = TextEditingController();
  final _timeController = TextEditingController();
  final _contactController = TextEditingController();
  final _noteController = TextEditingController();

  List<Category> parentCategories = [];
  Map<int, List<Category>> childrenMap = {};
  Category? _selectedType, _selectedArea, _selectedFeature;

  bool _isLoading = true, _isSubmitting = false, _aiGenerating = false;
  double? _selectedLat, _selectedLng;
  String? _selectedPubName, _selectedPriceRange, _userId;

  List<UploadImageItem> _images = [];
  List<UploadVideoItem> _videos = [];
  final _picker = ImagePicker();
  late WebSocketChannel _channel;
  List<Map<String, dynamic>> products = [];

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  final priceRanges = [
    {'label': 'Miễn phí', 'value': '0'},
    {'label': '50k – 100k', 'value': '50-100'},
    {'label': '100k – 200k', 'value': '100-200'},
    {'label': '200k – 500k', 'value': '200-500'},
    {'label': '500k+', 'value': '500+'},
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnimation = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initData();
    _setupWebSocket();
  }

  void _setupWebSocket() {
    _channel = WebSocketChannel.connect(Uri.parse(AppConfig.websocketUrl));
    _channel.sink.add(jsonEncode({"topic": "products:lobby", "event": "phx_join", "payload": {}, "ref": "1"}));
    _channel.stream.listen((message) {
      try {
        final decoded = json.decode(message);
        if (decoded['event'] == 'new_product') {
          final payload = decoded['payload'];
          setState(() { if (!products.any((p) => p['id'] == payload['id'])) products.insert(0, payload); });
        } else if (decoded['event'] == 'product_updated') {
          final payload = decoded['payload'];
          final index = products.indexWhere((p) => p['id'] == payload['id']);
          if (index != -1) setState(() => products[index] = payload);
        }
      } catch (_) {}
    });
  }

  Future<void> _initData() async {
    await _fetchCategories();
    final userId = await StorageHelper.read("user_id");
    setState(() => _userId = userId);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scrollController.dispose();
    _titleController.dispose(); _descriptionController.dispose();
    _priceController.dispose(); _slotsController.dispose();
    _addressController.dispose(); _timeController.dispose();
    _contactController.dispose(); _noteController.dispose();
    _channel.sink.close();
    super.dispose();
  }

  // ─── API METHODS (unchanged logic) ──────────────────────────────────────────
  Future<void> _fetchCategories() async {
    const url = '${AppConfig.webDomain}/wp-json/wc/v3/products/categories?per_page=100&consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final List<dynamic> data = jsonDecode(res.body);
        List<Category> all = data.map((e) => Category(id: e['id'], name: e['name'], parent: e['parent'], slug: e['slug'])).toList();
        parentCategories = all.where((c) => c.parent == 0).toList();
        for (var cat in all) {
          if (cat.parent != 0) childrenMap.putIfAbsent(cat.parent, () => []).add(cat);
        }
        setState(() => _isLoading = false);
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickImage() async {
    final List<XFile> images = await _picker.pickMultiImage(imageQuality: 80);
    if (images.isEmpty) return;
    for (final img in images) {
      final item = UploadImageItem(file: File(img.path));
      setState(() => _images.add(item));
      _uploadSingleImage(item);
    }
  }

  Future<void> _uploadSingleImage(UploadImageItem item) async {
    try {
      final url = await _uploadImage(item.file);
      if (!mounted) return;
      setState(() { item.url = url; item.uploading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { item.uploading = false; item.error = true; });
    }
  }

  Future<String> _uploadImage(File file) async {
    const username = 'admin';
    const appPassword = 'hWfZ33bkTXZGsuK18zFilY1D';
    final credentials = base64Encode(utf8.encode('$username:$appPassword'));
    final uri = Uri.parse('${AppConfig.webDomain}/wp-json/wp/v2/media');
    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Basic $credentials';
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final res = await request.send();
    final body = await res.stream.bytesToString();
    final data = jsonDecode(body);
    if (res.statusCode == 201) return data['source_url'];
    throw Exception('Upload failed: ${res.statusCode}');
  }

  Future<void> _pickVideo() async {
    final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
    if (video == null) return;
    final file = File(video.path);
    final item = UploadVideoItem(file: file, generatingThumb: true);
    setState(() => _videos.add(item));
    final thumb = await VideoThumbnail.thumbnailData(video: file.path, imageFormat: ImageFormat.JPEG, maxWidth: 200, quality: 25);
    setState(() { item.thumbnail = thumb; item.generatingThumb = false; });
    try {
      final url = await uploadVideoToCloudinary(file);
      setState(() { item.url = url; item.uploading = false; });
    } catch (e) {
      setState(() { item.uploading = false; item.error = true; });
    }
  }

  Future<String> uploadVideoToCloudinary(File videoFile) async {
    const cloudName = "datm1erra";
    const uploadPreset = "flutter_upload";
    final uri = Uri.parse("https://api.cloudinary.com/v1_1/$cloudName/video/upload");
    final request = http.MultipartRequest("POST", uri);
    request.fields['upload_preset'] = uploadPreset;
    request.files.add(await http.MultipartFile.fromPath('file', videoFile.path));
    final response = await request.send();
    final resBody = await response.stream.bytesToString();
    final data = jsonDecode(resBody);
    if (response.statusCode == 200 || response.statusCode == 201) return data['secure_url'];
    throw Exception("Upload video failed: $resBody");
  }

  Future<File> _downloadImageToFile(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) throw Exception('Download failed');
    final tempDir = await Directory.systemTemp.createTemp('ai_img');
    final file = File('${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }

  Future<void> _addRandomServerImages({int limit = 3}) async {
    final res = await http.get(Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/random-images?from_year=2026&limit=$limit'));
    final data = jsonDecode(res.body);
    if (data['success'] == true) {
      for (final url in data['images']) {
        final file = await _downloadImageToFile(url);
        final item = UploadImageItem(file: file);
        setState(() => _images.add(item));
        _uploadSingleImage(item);
      }
    }
  }

  Future<void> _fetchRandomPub() async {
    final res = await http.get(Uri.parse('${AppConfig.webDomain}/wp-json/spiritwebs/v1/random-pub'));
    final body = jsonDecode(res.body);
    if (body['success'] == true) {
      final pub = body['data'];
      setState(() {
        _addressController.text = pub['address'] ?? '';
        _selectedPubName = pub['pub_name'];
        _selectedLat = pub['lat'];
        _selectedLng = pub['lng'];
      });
    }
  }

  Future<String?> _fetchRandomPhone() async {
    final res = await http.get(Uri.parse('${AppConfig.webDomain}/wp-json/spiritwebs/v1/random-phone'));
    final data = jsonDecode(res.body);
    if (data['success'] == true) return data['phone'];
    return null;
  }

  String _randomFutureTime() {
    final now = DateTime.now();
    final random = Random();
    final daysAhead = random.nextInt(30) + 1;
    final hour = 18 + random.nextInt(4);
    final minute = random.nextBool() ? 0 : 30;
    final future = now.add(Duration(days: daysAhead)).copyWith(hour: hour, minute: minute);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(future.day)}/${two(future.month)}/${future.year} ${two(future.hour)}:${two(future.minute)}';
  }

  int _randomSlots() => 2 + Random().nextInt(11);

  Future<void> _applyAiToForm(Map<String, dynamic> ai) async {
    final phone = await _fetchRandomPhone();
    setState(() {
      _titleController.text = ai['title']?.toString() ?? '';
      _descriptionController.text = ai['description']?.toString() ?? '';
      _selectedPriceRange = '100-200';
      _priceController.text = _selectedPriceRange!;
      _slotsController.text = _randomSlots().toString();
      _contactController.text = phone ?? '';
      _noteController.text = ai['note']?.toString() ?? '';
      _timeController.text = _randomFutureTime();
      final lat = ai['lat'];
      final lng = ai['lng'];
      _selectedLat = lat is num ? lat.toDouble() : double.tryParse(lat?.toString() ?? '');
      _selectedLng = lng is num ? lng.toDouble() : double.tryParse(lng?.toString() ?? '');
      _selectedPubName = ai['pub_name']?.toString();
    });
  }

  void _randomCategories() {
    Category? typeParent, areaParent, featureParent;
    for (final parent in parentCategories) {
      final name = parent.name.toLowerCase();
      if (name.contains('đích')) typeParent = parent;
      else if (name.contains('tính')) areaParent = parent;
      else featureParent = parent;
    }
    setState(() {
      if (typeParent != null) _selectedType = _randomChildOfParent(typeParent!);
      if (areaParent != null) _selectedArea = _randomChildOfParent(areaParent!);
      if (featureParent != null) _selectedFeature = _randomChildOfParent(featureParent!);
    });
  }

  Category? _randomChildOfParent(Category parent) {
    final children = childrenMap[parent.id];
    if (children == null || children.isEmpty) return null;
    children.shuffle();
    return children.first;
  }

  Future<void> _aiGenerateFromServer() async {
    if (_aiGenerating) return;
    setState(() => _aiGenerating = true);
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.webDomain}/api/invite-ai'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({}),
      );
      final body = jsonDecode(res.body);
      if (body['success'] == true && body['data'] != null) {
        await _applyAiToForm(body['data']);
        await _fetchRandomPub();
        _randomCategories();
        setState(() => _images.clear());
        await _addRandomServerImages();
      } else {
        throw Exception(body['error'] ?? 'AI lỗi');
      }
    } catch (e) {
      if (mounted) {
        _showSnack('AI gặp lỗi: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _aiGenerating = false);
    }
  }

  void _submitForm() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    if (_userId == null) { _showSnack('Bạn chưa đăng nhập', isError: true); return; }

    setState(() => _isSubmitting = true);
    final videoUrls = _videos.where((v) => v.url != null).map((v) => v.url).toList();
    final formData = {
      'name': _titleController.text,
      'type': 'simple',
      'regular_price': _priceController.text.isEmpty ? '0' : _priceController.text.replaceAll(',', ''),
      'description': _descriptionController.text,
      'categories': [
        if (_selectedType != null) {'id': _selectedType!.id},
        if (_selectedArea != null) {'id': _selectedArea!.id},
        if (_selectedFeature != null) {'id': _selectedFeature!.id},
      ],
      'meta_data': [
        {'key': 'slots', 'value': _slotsController.text},
        {'key': 'address', 'value': _addressController.text},
        {'key': 'pub_name', 'value': _selectedPubName ?? ''},
        {'key': 'lat', 'value': _selectedLat?.toString() ?? ''},
        {'key': 'lng', 'value': _selectedLng?.toString() ?? ''},
        {'key': 'time', 'value': _timeController.text},
        {'key': 'contact', 'value': _contactController.text},
        {'key': 'note', 'value': _noteController.text},
        {'key': 'creator_id', 'value': _userId},
        {'key': 'videos', 'value': jsonEncode(videoUrls)},
        {'key': 'price_range', 'value': _selectedPriceRange ?? ''},
      ],
      'images': _images.where((i) => i.url != null).map((i) => {'src': i.url}).toList(),
    };

    const url = '${AppConfig.webDomain}/wp-json/wc/v3/products?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8';

    try {
      final response = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode(formData));
      if (response.statusCode == 201) {
        final createdProduct = jsonDecode(response.body);
        final inviteRes = await http.post(
          Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/invite/create'),
          headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${await StorageHelper.read("jwt_token")}'},
          body: jsonEncode({'product_id': createdProduct['id'], 'max_people': int.tryParse(_slotsController.text) ?? 0, 'start_time': _timeController.text}),
        );
        final inviteData = jsonDecode(inviteRes.body);
        if (inviteData['success'] != true) throw Exception("Tạo invite thất bại");

        _channel.sink.add(jsonEncode({"topic": "products:lobby", "event": "new_product", "payload": createdProduct, "ref": "2"}));
        _showSnack('🍻 Lời mời đã được tạo!');
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainPage()));
      } else {
        _showSnack('Lỗi lưu hệ thống: ${response.statusCode}', isError: true);
      }
    } catch (e) {
      _showSnack('Lỗi kết nối: $e', isError: true);
    } finally {
      setState(() => _isSubmitting = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: _AppColors.textPrimary, fontWeight: FontWeight.w500)),
      backgroundColor: isError ? _AppColors.error.withOpacity(0.9) : _AppColors.surface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  // ─── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_AppColors.bgGradientStart, _AppColors.bgGradientEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            CustomScrollView(
              controller: _scrollController,
              slivers: [
                _buildAppBar(),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 100),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            _buildSection(
                              icon: Icons.local_bar_rounded,
                              title: 'Kèo hôm nay',
                              child: _buildBasicInfo(),
                            ),
                            const SizedBox(height: 16),
                            _buildSection(
                              icon: Icons.place_rounded,
                              title: 'Địa điểm & Chi tiết',
                              child: _buildLocationInfo(),
                            ),
                            const SizedBox(height: 16),
                            _buildSection(
                              icon: Icons.photo_library_rounded,
                              title: 'Ảnh & Video',
                              child: _buildMediaPicker(),
                            ),
                            const SizedBox(height: 16),
                            _buildSection(
                              icon: Icons.category_rounded,
                              title: 'Loại kèo',
                              child: _isLoading ? _buildCategorySkeleton() : _buildCategoryChips(),
                            ),
                            const SizedBox(height: 28),
                            _buildActionButtons(),
                            const SizedBox(height: 32),
                          ],
                        ),
                      ),
                    ]),
                  ),
                ),
              ],
            ),
            if (_aiGenerating) _buildAiOverlay(),
          ],
        ),
      ),
    );
  }

  // ─── APP BAR ────────────────────────────────────────────────────────────────
  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 120,
      pinned: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        color: Colors.white,
        onPressed: () => Navigator.maybePop(context),
      ),
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(56, 0, 20, 16),
        title: const Text(
          'Tạo lời mời',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        background: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 44),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.2), width: 0.5),
                    ),
                    child: const Icon(Icons.local_bar_rounded, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Rủ bạn bè, cùng nhau vui',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: Colors.white.withOpacity(0.15)),
      ),
    );
  }

  // ─── SECTION CARD ───────────────────────────────────────────────────────────
  Widget _buildSection({required IconData icon, required String title, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.15), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(color: _AppColors.primaryDim, borderRadius: BorderRadius.circular(8)),
                  child: Icon(icon, color: _AppColors.primary, size: 18),
                ),
                const SizedBox(width: 10),
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: Colors.white.withOpacity(0.15)),
          Padding(padding: const EdgeInsets.all(16), child: child),
        ],
      ),
    );
  }

  // ─── BASIC INFO ─────────────────────────────────────────────────────────────
  Widget _buildBasicInfo() {
    return Column(
      children: [
        _buildTextField(
          controller: _titleController,
          label: 'Hôm nay mode gì?',
          hint: 'VD: Nhậu mừng sinh nhật anh Hùng',
          icon: Icons.celebration_rounded,
          validator: (v) => v == null || v.isEmpty ? 'Vui lòng nhập tiêu đề' : null,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          controller: _descriptionController,
          label: 'Vibe của bàn nhậu',
          hint: 'Quán bình dân, đồ nhậu ngon, không ép uống...',
          icon: Icons.notes_rounded,
          maxLines: 3,
          validator: (v) => v == null || v.isEmpty ? 'Vui lòng mô tả' : null,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildPriceDropdown()),
            const SizedBox(width: 12),
            Expanded(
              child: _buildTextField(
                controller: _slotsController,
                label: 'Số chỗ',
                hint: '6',
                icon: Icons.people_alt_rounded,
                keyboardType: TextInputType.number,
                validator: (v) => v == null || v.isEmpty ? 'Nhập số chỗ' : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPriceDropdown() {
    return DropdownButtonFormField<String>(
      isExpanded: true,
      value: _selectedPriceRange,
      dropdownColor: _AppColors.popupSurface,
      style: const TextStyle(color: _AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
      icon: Icon(Icons.expand_more_rounded, color: Colors.white.withOpacity(0.65), size: 20),
      hint: Text('Mức giá', style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13)),
      decoration: _fieldDecoration('Khoảng giá', Icons.payments_rounded),
      items: priceRanges.map((item) => DropdownMenuItem<String>(
        value: item['value'],
        child: Text(item['label']!, style: const TextStyle(color: _AppColors.textPrimary, fontSize: 14)),
      )).toList(),
      onChanged: (value) => setState(() {
        _selectedPriceRange = value;
        _priceController.text = value ?? '0';
      }),
    );
  }

  // ─── LOCATION INFO ──────────────────────────────────────────────────────────
  Widget _buildLocationInfo() {
    return Column(
      children: [
        _buildTextField(
          controller: _addressController,
          label: 'Địa điểm / Quán',
          hint: 'Chọn vị trí trên bản đồ',
          icon: Icons.storefront_rounded,
          readOnly: true,
          suffix: _mapButton(),
          validator: (v) => v == null || v.isEmpty ? 'Chọn địa điểm' : null,
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: _pickDateTime,
          child: AbsorbPointer(
            child: _buildTextField(
              controller: _timeController,
              label: 'Thời gian',
              hint: 'Chọn ngày & giờ',
              icon: Icons.schedule_rounded,
              readOnly: true,
              suffix: Icon(Icons.calendar_today_rounded, size: 18, color: Colors.white.withOpacity(0.65)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildTextField(
          controller: _contactController,
          label: 'Liên hệ',
          hint: 'Tên hoặc SĐT',
          icon: Icons.person_rounded,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          controller: _noteController,
          label: 'Ghi chú',
          hint: 'Ai tới trễ tự chịu...',
          icon: Icons.sticky_note_2_rounded,
        ),
      ],
    );
  }

  Widget _mapButton() {
    return GestureDetector(
      onTap: () async {
        final selectedPub = await Navigator.push(context, MaterialPageRoute(builder: (_) => const MapPageSelectLocation()));
        if (selectedPub != null) {
          setState(() {
            _selectedPubName = selectedPub['name'];
            _addressController.text = selectedPub['address'];
            _selectedLat = selectedPub['latitude'];
            _selectedLng = selectedPub['longitude'];
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _AppColors.primary.withOpacity(0.25),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _AppColors.primary.withOpacity(0.4), width: 0.5),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.map_rounded, color: Colors.white, size: 14),
          SizedBox(width: 4),
          Text('Bản đồ', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Future<void> _pickDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: _AppColors.primary, onPrimary: Colors.white, surface: _AppColors.popupSurface),
        ),
        child: child!,
      ),
    );
    if (pickedDate == null) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: _AppColors.primary, onPrimary: Colors.white, surface: _AppColors.popupSurface),
        ),
        child: child!,
      ),
    );
    if (pickedTime == null) return;
    final dt = DateTime(pickedDate.year, pickedDate.month, pickedDate.day, pickedTime.hour, pickedTime.minute);
    _timeController.text = DateFormat('dd/MM/yyyy HH:mm').format(dt);
  }

  // ─── MEDIA PICKER ───────────────────────────────────────────────────────────
  Widget _buildMediaPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 96,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              ..._images.map((item) => _buildImageThumb(item)),
              ..._videos.map((item) => _buildVideoThumb(item)),
              _buildAddMediaButton(Icons.add_photo_alternate_rounded, 'Ảnh', _pickImage),
              const SizedBox(width: 8),
              _buildAddMediaButton(Icons.videocam_rounded, 'Video', _pickVideo),
            ],
          ),
        ),
        if (_images.any((i) => i.uploading) || _videos.any((v) => v.uploading))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: _AppColors.primary)),
              const SizedBox(width: 8),
              Text('Đang tải lên...', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
            ]),
          ),
      ],
    );
  }

  Widget _buildImageThumb(UploadImageItem item) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 96, height: 96,
              child: Stack(fit: StackFit.expand, children: [
                Image.file(item.file, fit: BoxFit.cover),
                if (item.uploading)
                  shimmer.Shimmer.fromColors(
                    baseColor: Colors.white.withOpacity(0.15),
                    highlightColor: Colors.white.withOpacity(0.35),
                    child: Container(color: Colors.white.withOpacity(0.3)),
                  ),
                if (item.error) Container(color: Colors.black.withOpacity(0.55), child: const Icon(Icons.error_rounded, color: _AppColors.error)),
              ]),
            ),
          ),
          Positioned(
            top: 4, right: 4,
            child: GestureDetector(
              onTap: () => setState(() => _images.remove(item)),
              child: Container(
                width: 22, height: 22,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
              ),
            ),
          ),
          if (!item.uploading && !item.error)
            Positioned(
              bottom: 4, left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: _AppColors.success.withOpacity(0.9), borderRadius: BorderRadius.circular(4)),
                child: const Icon(Icons.check_rounded, size: 10, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideoThumb(UploadVideoItem item) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 96, height: 96,
              child: item.generatingThumb
                  ? shimmer.Shimmer.fromColors(
                baseColor: Colors.white.withOpacity(0.15),
                highlightColor: Colors.white.withOpacity(0.35),
                child: Container(color: Colors.white),
              )
                  : item.thumbnail != null
                  ? Image.memory(item.thumbnail!, fit: BoxFit.cover)
                  : Container(color: Colors.white.withOpacity(0.08), child: Icon(Icons.videocam_rounded, color: Colors.white.withOpacity(0.65))),
            ),
          ),
          if (item.uploading)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), borderRadius: BorderRadius.circular(10)),
                child: const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: _AppColors.primary))),
              ),
            ),
          // Video play icon badge
          if (!item.uploading && !item.error)
            Positioned(
              bottom: 4, left: 4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), borderRadius: BorderRadius.circular(6)),
                child: const Icon(Icons.play_arrow_rounded, size: 12, color: Colors.white),
              ),
            ),
          Positioned(
            top: 4, right: 4,
            child: GestureDetector(
              onTap: () => setState(() => _videos.remove(item)),
              child: Container(
                width: 22, height: 22,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddMediaButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 80, height: 96,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withOpacity(0.18), width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white.withOpacity(0.75), size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 11)),
          ],
        ),
      ),
    );
  }

  // ─── CATEGORY CHIPS ─────────────────────────────────────────────────────────
  Widget _buildCategoryChips() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parentCategories.expand((parent) {
        final children = childrenMap[parent.id] ?? [];
        Category? selected = parent.name.toLowerCase().contains('đích')
            ? _selectedType
            : parent.name.toLowerCase().contains('gia') ? _selectedArea : _selectedFeature;

        return [
          Text(parent.name, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6, runSpacing: 6,
            children: children.map((child) {
              final isSelected = selected?.id == child.id;
              return GestureDetector(
                onTap: () => setState(() {
                  if (parent.name.toLowerCase().contains('đích')) _selectedType = child;
                  else if (parent.name.toLowerCase().contains('gia')) _selectedArea = child;
                  else _selectedFeature = child;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: isSelected ? _AppColors.primary : Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected ? _AppColors.primary : Colors.white.withOpacity(0.18),
                      width: isSelected ? 1.5 : 0.5,
                    ),
                  ),
                  child: Text(
                    child.name,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white.withOpacity(0.7),
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
        ];
      }).toList(),
    );
  }

  Widget _buildCategorySkeleton() {
    return shimmer.Shimmer.fromColors(
      baseColor: Colors.white.withOpacity(0.15),
      highlightColor: Colors.white.withOpacity(0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 80, height: 11, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: List.generate(6, (_) => Container(
            width: 70 + (Random().nextInt(40)).toDouble(), height: 32,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
          ))),
        ],
      ),
    );
  }

  // ─── ACTION BUTTONS ─────────────────────────────────────────────────────────
  Widget _buildActionButtons() {
    final canSubmit = !_isSubmitting && !_images.any((i) => i.uploading) && !_videos.any((v) => v.uploading || v.generatingThumb);

    return Column(
      children: [
        // AI Generate button
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton(
            onPressed: _aiGenerating ? null : _aiGenerateFromServer,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: _aiGenerating ? Colors.white.withOpacity(0.15) : _AppColors.primary.withOpacity(0.6), width: 1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              backgroundColor: _aiGenerating ? Colors.transparent : _AppColors.primaryDim,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.auto_awesome_rounded, color: _aiGenerating ? Colors.white.withOpacity(0.4) : Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  _aiGenerating ? 'AI đang tạo...' : 'Tạo nhanh với AI',
                  style: TextStyle(
                    color: _aiGenerating ? Colors.white.withOpacity(0.4) : Colors.white,
                    fontSize: 14, fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Submit button
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: canSubmit ? _submitForm : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _AppColors.primary,
              disabledBackgroundColor: Colors.white.withOpacity(0.12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: _isSubmitting
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.send_rounded, color: canSubmit ? Colors.white : Colors.white.withOpacity(0.45), size: 20),
                const SizedBox(width: 8),
                Text(
                  'Tạo lời mời',
                  style: TextStyle(
                    color: canSubmit ? Colors.white : Colors.white.withOpacity(0.45),
                    fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── AI OVERLAY ─────────────────────────────────────────────────────────────
  Widget _buildAiOverlay() {
    return Positioned.fill(
      child: AbsorbPointer(
        child: Container(
          color: Colors.black.withOpacity(0.65),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (_, __) => Opacity(
                    opacity: _pulseAnimation.value,
                    child: Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(color: _AppColors.primaryDim, shape: BoxShape.circle),
                      child: const Icon(Icons.auto_awesome_rounded, color: _AppColors.primary, size: 36),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('AI đang tạo nội dung', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('Chỉ vài giây nữa thôi...', style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── FORM FIELD HELPERS ─────────────────────────────────────────────────────
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    required IconData icon,
    int maxLines = 1,
    bool readOnly = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      readOnly: readOnly,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(color: _AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500),
      cursorColor: _AppColors.primary,
      decoration: _fieldDecoration(label, icon).copyWith(
        hintText: hint,
        suffixIcon: suffix != null ? Padding(padding: const EdgeInsets.only(right: 12), child: suffix) : null,
        suffixIconConstraints: const BoxConstraints(),
      ),
    );
  }

  InputDecoration _fieldDecoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 13, fontWeight: FontWeight.w500),
      prefixIcon: Icon(icon, color: Colors.white.withOpacity(0.65), size: 18),
      filled: true,
      fillColor: Colors.white.withOpacity(0.08),
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withOpacity(0.18), width: 0.5)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withOpacity(0.18), width: 0.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _AppColors.primary, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _AppColors.error, width: 1)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _AppColors.error, width: 1.5)),
      errorStyle: const TextStyle(color: _AppColors.error, fontSize: 11),
    );
  }
}

// ─── UTILITY FORMATTERS ───────────────────────────────────────────────────────
class CurrencyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;
    String digits = newValue.text.replaceAll(',', '');
    if (int.tryParse(digits) == null) return oldValue;
    final number = NumberFormat('#,###').format(int.parse(digits));
    return TextEditingValue(text: number, selection: TextSelection.collapsed(offset: number.length));
  }
}