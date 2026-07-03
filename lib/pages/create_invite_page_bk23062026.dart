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

class CreateInvitePage extends StatefulWidget {
  const CreateInvitePage({super.key});

  @override
  State<CreateInvitePage> createState() => _CreateInvitePageState();
}
class VideoPreviewShimmer extends StatelessWidget {
  const VideoPreviewShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return shimmer.Shimmer.fromColors(
      baseColor: Colors.grey.shade300,
      highlightColor: Colors.grey.shade100,
      child: Container(
        width: double.infinity,
        height: 200,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

class UploadImageItem {
  final File file;
  String? url;
  bool uploading;
  bool error;

  UploadImageItem({
    required this.file,
    this.url,
    this.uploading = true,
    this.error = false,
  });
}
class UploadVideoItem {
  final File file;
  String? url;
  bool uploading;
  bool error;
  Uint8List? thumbnail; // 👈 thêm
  bool generatingThumb; // 👈 THÊM

  UploadVideoItem({
    required this.file,
    this.url,
    this.uploading = true,
    this.error = false,
    this.thumbnail,
    this.generatingThumb = true,
  });
}


class _CreateInvitePageState extends State<CreateInvitePage> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _slotsController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _timeController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  List<Category> parentCategories = [];
  Map<int, List<Category>> childrenMap = {};

  Category? _selectedType;
  Category? _selectedArea;
  Category? _selectedFeature;

  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _isUploading = false;
  bool _aiGenerating = false;


  double? _selectedLat;
  double? _selectedLng;
  String? _selectedPubName;
  String? _selectedPriceRange;

  String? _userId;
  List<UploadImageItem> _images = [];
  final ImagePicker _picker = ImagePicker();

  List<UploadVideoItem> _videos = [];

  // Theme colors giống ShopPage
  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);
  final Color textWhite = Colors.white;
  late WebSocketChannel _channel;
  // Danh sách sản phẩm để lưu từ WebSocket
  List<Map<String, dynamic>> products = [];


  @override
  void initState() {
    super.initState();
    _initData();

    // Kết nối WebSocket Phoenix
    _channel = WebSocketChannel.connect(
      Uri.parse('wss://socket.spiritwebs.com/socket/websocket'),
    );

    // PHX_JOIN channel "products:lobby"
    _channel.sink.add(jsonEncode({
      "topic": "products:lobby",
      "event": "phx_join",
      "payload": {},
      "ref": "1"
    }));

    // Lắng nghe message từ server
    _channel.stream.listen((message) {
      try {
        final decoded = json.decode(message);

        if (decoded['event'] == 'new_product') {
          final payload = decoded['payload'];
          setState(() {
            if (!products.any((p) => p['id'] == payload['id'])) {
              products.insert(0, payload);
            }
          });
        } else if (decoded['event'] == 'product_updated') {
          final payload = decoded['payload'];
          final index = products.indexWhere((p) => p['id'] == payload['id']);
          if (index != -1) {
            setState(() {
              products[index] = payload;
            });
          }
        }
      } catch (e) {
        print('[WS ERROR] Invalid JSON: $e');
      }
    });
  }
  final List<Map<String, String>> priceRanges = [
    {'label': 'Miễn phí', 'value': '0'},
    {'label': '50k - 100k', 'value': '50-100'},
    {'label': '100k - 200k', 'value': '100-200'},
    {'label': '200k - 500k', 'value': '200-500'},
    {'label': '500k+', 'value': '500+'},
  ];

  Future<void> _pickVideo() async {
    final XFile? video = await _picker.pickVideo(
      source: ImageSource.gallery,
    );

    if (video == null) return;

    final file = File(video.path);

    final item = UploadVideoItem(
      file: file,
      generatingThumb: true,
    );

    setState(() {
      _videos.add(item); // 👈 dùng đúng object này luôn
    });

    final thumb = await VideoThumbnail.thumbnailData(
      video: file.path,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 200,
      quality: 25,
    );

    setState(() {
      item.thumbnail = thumb;
      item.generatingThumb = false;
    });

    try {
      final url = await uploadVideoToCloudinary(file);

      setState(() {
        item.url = url;
        item.uploading = false;
      });
    } catch (e) {
      setState(() {
        item.uploading = false;
        item.error = true;
      });
    }
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

  Future<void> _initData() async {
    await _fetchCategories();
    final userId = await StorageHelper.read("user_id");
    setState(() {
      _userId = userId;
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _slotsController.dispose();
    _addressController.dispose();
    _timeController.dispose();
    _contactController.dispose();
    _noteController.dispose();

    // Đóng WebSocket khi page bị hủy
    _channel.sink.close();

    super.dispose();
  }


  Future<void> _fetchCategories() async {
    const url =
        '${AppConfig.webDomain}/wp-json/wc/v3/products/categories?per_page=100&consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final List<dynamic> data = jsonDecode(res.body);
        List<Category> all = data.map((e) {
          return Category(
            id: e['id'],
            name: e['name'],
            parent: e['parent'],
            slug: e['slug'],
          );
        }).toList();

        parentCategories = all.where((c) => c.parent == 0).toList();

        for (var cat in all) {
          if (cat.parent != 0) {
            childrenMap.putIfAbsent(cat.parent, () => []).add(cat);
          }
        }

        setState(() {
          _isLoading = false;
        });
      } else {
        throw Exception('HTTP ${res.statusCode}');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi tải danh mục: $e')));
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

      setState(() {
        item.url = url;
        item.uploading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        item.uploading = false;
        item.error = true;
      });

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Upload ảnh lỗi: $e')));
    }
  }

  Future<File> _downloadImageToFile(String url) async {
    final response = await http.get(Uri.parse(url));

    if (response.statusCode != 200) {
      throw Exception('Download image failed: ${response.statusCode}');
    }

    final tempDir = await Directory.systemTemp.createTemp('ai_img');
    final file = File(
      '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

    await file.writeAsBytes(response.bodyBytes);
    return file;
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

    if (res.statusCode == 201) {
      return data['source_url'];
    } else {
      throw Exception('Upload image failed: ${res.statusCode}');
    }
  }


  Map<String, dynamic> buildInvitePayload({
    required String name,
    required String price,
    required String description,
    required List<Category?> categories,
    required Map<String, String> meta,
    required List<UploadImageItem> images,
  }) {
    return {
      'name': name,
      'type': 'simple',
      'regular_price': price.isEmpty ? '0' : price.replaceAll(',', ''),
      'description': description,
      'categories': categories
          .where((c) => c != null)
          .map((c) => {'id': c!.id})
          .toList(),
      'meta_data': meta.entries
          .map((e) => {'key': e.key, 'value': e.value})
          .toList(),
      'images': images
          .where((i) => i.url != null)
          .map((i) => {'src': i.url})
          .toList(),
    };
  }


  Future<void> submitInvite(Map<String, dynamic> formData) async {
    const url =
        '${AppConfig.webDomain}/wp-json/wc/v3/products?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8';

    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(formData),
    );

    if (response.statusCode != 201) {
      throw Exception('Tạo product thất bại');
    }

    final createdProduct = jsonDecode(response.body);

    final inviteRes = await http.post(
      Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/invite/create'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${await StorageHelper.read("jwt_token")}',
      },
      body: jsonEncode({
        'product_id': createdProduct['id'],
        'max_people': int.tryParse(formData['meta_data']
            .firstWhere((e) => e['key'] == 'slots')['value']) ??
            0,
        'start_time': formData['meta_data']
            .firstWhere((e) => e['key'] == 'time')['value'],
      }),
    );

    final inviteData = jsonDecode(inviteRes.body);
    if (inviteData['success'] != true) {
      throw Exception('Tạo invite thất bại');
    }

    // 🔔 broadcast realtime
    _channel.sink.add(jsonEncode({
      "topic": "products:lobby",
      "event": "new_product",
      "payload": createdProduct,
      "ref": "ai"
    }));
  }
  int _randomSlots() {
    final random = Random();

    // random số chỗ từ 2 đến 12
    return 2 + random.nextInt(11);
  }
  Future<void> _fetchRandomPub() async {
    final res = await http.get(
      Uri.parse('${AppConfig.webDomain}/wp-json/spiritwebs/v1/random-pub'),
    );

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


  Future<void> _applyAiToForm(Map<String, dynamic> ai) async {
    final phone = await _fetchRandomPhone();

    setState(() {
      _titleController.text = ai['title']?.toString() ?? '';
      _descriptionController.text = ai['description']?.toString() ?? '';
      /*_priceController.text = (ai['price'] ?? '').toString();*/
      _selectedPriceRange = '100-200';
      _priceController.text = _selectedPriceRange!;

      _slotsController.text = _randomSlots().toString();

      // 🔥 RANDOM PHONE TỪ wp_companies
      _contactController.text = phone ?? '';

      _noteController.text = ai['note']?.toString() ?? '';

      _timeController.text = _randomFutureTime();

      final lat = ai['lat'];
      final lng = ai['lng'];

      _selectedLat =
      lat is num ? lat.toDouble() : double.tryParse(lat?.toString() ?? '');
      _selectedLng =
      lng is num ? lng.toDouble() : double.tryParse(lng?.toString() ?? '');

      _selectedPubName = ai['pub_name']?.toString();
    });
  }

  String _randomFutureTime() {
    final now = DateTime.now();
    final random = Random();

    final daysAhead = random.nextInt(30) + 1; // 1–30 ngày tới
    final hour = 18 + random.nextInt(4); // 18–21h
    final minute = random.nextBool() ? 0 : 30;

    final future = now.add(Duration(days: daysAhead)).copyWith(
      hour: hour,
      minute: minute,
    );


    String two(int n) => n.toString().padLeft(2, '0');

    return '${two(future.day)}/${two(future.month)}/${future.year} '
        '${two(future.hour)}:${two(future.minute)}';
  }


  Future<void> _fakeAiGenerate() async {
    if (_aiGenerating) return; // ⛔ chặn spam

    setState(() => _aiGenerating = true);

    try {
      final now = DateTime.now().add(const Duration(hours: 2));

      final aiData = {
        "title": "Nhậu tối nay cho đỡ buồn",
        "description": "Nhậu vui vẻ, không ép uống, có đồ ăn",
        "price": "150000",
        "slots": "6",
        "address": "Quán Ốc 123, Quận 1",
        "time": DateFormat('dd/MM/yyyy HH:mm').format(now),
        "contact": "Hùng - 0937xxxx",
        "note": "Ai tới trễ tự chịu",
        "lat": "10.7769",
        "lng": "106.7009",
        "pub_name": "Ốc 123"
      };

      _applyAiToForm(aiData);
      _randomCategories();
      // xóa hình cũ
      setState(() {
        _images.clear(); // 🔥 xóa ảnh cũ trước khi AI tạo lại
      });

      await _addRandomServerImages();

    } finally {
      if (mounted) {
        setState(() => _aiGenerating = false);
      }
    }
  }

  Future<void> _aiGenerateFromServer() async {
    if (_aiGenerating) return;

    setState(() => _aiGenerating = true);

    try {
      final res = await http.post(
        Uri.parse('${AppConfig.webDomain}/api/invite-ai'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          // có thể truyền context nếu muốn
          // "user_id": _userId,
        }),
      );

      final body = jsonDecode(res.body);

      if (body['success'] == true && body['data'] != null) {
        final aiData = body['data'];

        _applyAiToForm(aiData);
        // 🔥 override address bằng pub thật
        await _fetchRandomPub();
        _randomCategories();

        // reset ảnh cũ
        setState(() {
          _images.clear();
        });

        await _addRandomServerImages();
      } else {
        throw Exception(body['error'] ?? 'AI trả về lỗi');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI lỗi: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _aiGenerating = false);
      }
    }
  }




  void _submitForm() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    if (_userId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Bạn chưa đăng nhập')));
      return;
    }

    setState(() => _isSubmitting = true);
    final videoUrls = _videos
        .where((v) => v.url != null)
        .map((v) => v.url)
        .toList();
    final formData = {
      'name': _titleController.text,
      'type': 'simple',
      'regular_price': _priceController.text.isEmpty
    ? '0'
        : _priceController.text.replaceAll(',', ''),
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

        // 🔥 THÊM DÒNG NÀY
        {'key': 'price_range', 'value': _selectedPriceRange ?? ''},
      ],
      'images': _images
          .where((i) => i.url != null)
          .map((i) => {'src': i.url})
          .toList(),

    };

    const url =
        '${AppConfig.webDomain}/wp-json/wc/v3/products?consumer_key=ck_3809ad31dd47ca7d10573e35ccdf746494b305a9&consumer_secret=cs_a49b903ddc7972646359f360d79343cd1e33b6f8';

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(formData),
      );

      if (response.statusCode == 201) {

        final createdProduct = jsonDecode(response.body);

        final inviteRes = await http.post(
          Uri.parse('${AppConfig.webDomain}/wp-json/nhau/v1/invite/create'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${await StorageHelper.read("jwt_token")}',
          },
          body: jsonEncode({
            'product_id': createdProduct['id'],
            'max_people': int.tryParse(_slotsController.text) ?? 0,
            'start_time': _timeController.text,
          }),
        );

        final inviteData = jsonDecode(inviteRes.body);

        if (inviteData['success'] != true) {
          print("INVITE RAW: ${inviteRes.body}");
          print("INVITE STATUS: ${inviteRes.statusCode}");
          print("INVITE PARSED: $inviteData");

          throw Exception("Tạo invite thất bại");
        }


        // 🔔 Gửi lên WebSocket để các user khác thấy ngay
        _channel.sink.add(jsonEncode({
          "topic": "products:lobby",
          "event": "new_product",
          "payload": createdProduct,
          "ref": "2"
        }));


        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🍻 Lời mời đã được tạo!')),
        );
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainPage()),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi lưu hệ thống: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi kết nối: $e')));
    } finally {
      setState(() => _isSubmitting = false);
    }
  }


  InputDecoration _inputDecoration(
      String label, {
        String? hint,
        IconData? icon,
        EdgeInsetsGeometry? contentPadding,
      }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(
        color: Colors.white70,
        fontWeight: FontWeight.w600,
      ),
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white54),

      contentPadding: contentPadding ??
          const EdgeInsets.symmetric(vertical: 16, horizontal: 16),

      filled: true,
      fillColor: Colors.white.withOpacity(0.2),

      prefixIcon: icon != null
          ? Icon(icon, color: Colors.white70, size: 22)
          : null,

      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
      ),

      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
      ),

      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.white, width: 2),
      ),

      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.red, width: 2),
      ),

      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.red, width: 2),
      ),
    );
  }


  Widget _buildChoiceChips(
      Category parent, Category? selected, Function(Category) onSelected) {
    final children = childrenMap[parent.id] ?? [];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: children.map((child) {
        final isSelected = selected?.id == child.id;
        return ChoiceChip(
          label: Text(child.name),
          selected: isSelected,
          onSelected: (_) => onSelected(child),
          selectedColor: accentOrange,
          backgroundColor: Colors.grey.shade800, // đậm hơn, dễ nhìn
          labelStyle: TextStyle(
              color: isSelected ? textWhite : Colors.white70,
              fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        );
      }).toList(),
    );
  }

  Future<String?> _fetchRandomPhone() async {
    final res = await http.get(
      Uri.parse('${AppConfig.webDomain}/wp-json/spiritwebs/v1/random-phone'),
    );

    final data = jsonDecode(res.body);

    if (data['success'] == true) {
      return data['phone'];
    }
    return null;
  }

  Future<void> _addRandomServerImages({int limit = 3}) async {
    final res = await http.get(
      Uri.parse(
        '${AppConfig.webDomain}/wp-json/nhau/v1/random-images?from_year=2026&limit=$limit',
      ),
    );

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

  Category? _randomChildOfParent(Category parent) {
    final children = childrenMap[parent.id];
    if (children == null || children.isEmpty) return null;
    children.shuffle();
    return children.first;
  }
  void _randomCategories() {
    Category? typeParent;
    Category? areaParent;
    Category? featureParent;

    for (final parent in parentCategories) {
      final name = parent.name.toLowerCase();

      if (name.contains('đích')) {
        typeParent = parent;
      } else if (name.contains('tính')) {
        areaParent = parent;
      }
      else {
        featureParent = parent;
      }
    }

    setState(() {
      if (typeParent != null) {
        _selectedType = _randomChildOfParent(typeParent);
      }
      if (areaParent != null) {
        _selectedArea = _randomChildOfParent(areaParent);
      }
      if (featureParent != null) {
        _selectedFeature = _randomChildOfParent(featureParent);
      }
    });
  }





  Widget _buildCard(String title, Widget child) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(18),
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5), // nền đậm để chữ trắng nổi bật
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: textWhite)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body:Stack(
          children: [
      Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [primaryBlue.withOpacity(0.9), accentOrange.withOpacity(0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: 16 + MediaQuery.of(context).viewInsets.bottom),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Text(
                        'Tạo lời mời',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: textWhite,
                          shadows: [
                            Shadow(
                              color: Colors.black26,
                              offset: Offset(0, 1),
                              blurRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildCard(
                    'Kèo hôm nay',
                    Column(
                      children: [
                        TextFormField(
                          controller: _titleController,
                          style: const TextStyle(color: Colors.white70),
                          decoration:
                          _inputDecoration('Hôm nay mode gì? ', hint: 'Nhậu mừng sinh nhật...', icon: Icons.title),
                          validator: (v) => v == null || v.isEmpty ? 'Hôm nay mode gì?' : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _descriptionController,
                          style: const TextStyle(color: Colors.white70),
                          maxLines: 3,
                          decoration: _inputDecoration('Vibe của bàn nhậu?', hint: 'Quán bình dân, đồ nhậu ngon...', icon: Icons.description),
                          validator: (v) => v == null || v.isEmpty ? 'Vibe của bàn nhậu?' : null,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                value: _selectedPriceRange,

                                hint: const Text(
                                  'Chọn mức',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),

                                icon: const Icon(
                                  Icons.arrow_drop_down,
                                  color: Colors.white70,
                                ),

                                dropdownColor: const Color(0xFF1E1E1E),
                                menuMaxHeight: 260,

                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),

                                decoration: _inputDecoration(
                                  'Khoảng giá / Người',
                                  icon: Icons.attach_money,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                    horizontal: 16,
                                  ),
                                ),

                                items: priceRanges.map((item) {
                                  return DropdownMenuItem<String>(
                                    value: item['value'],
                                    child: Text(
                                      item['label']!,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                      ),
                                    ),
                                  );
                                }).toList(),

                                onChanged: (value) {
                                  setState(() {
                                    _selectedPriceRange = value;
                                    _priceController.text = value ?? '0';
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _slotsController,
                                style: const TextStyle(color: Colors.white70),
                                keyboardType: TextInputType.number,
                                decoration: _inputDecoration('Số chỗ tối đa', icon: Icons.event_seat),
                                validator: (v) => v == null || v.isEmpty ? 'Nhập số chỗ' : null,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Phần địa điểm, liên hệ, hình ảnh, nút gửi giữ nguyên chức năng, chỉ đổi màu
                  _buildCard(
                    'Địa điểm & Liên hệ',
                    Column(
                      children: [
                        TextFormField(
                          controller: _addressController,
                          style: const TextStyle(color: Colors.white70),
                          readOnly: true,
                          decoration: _inputDecoration('Địa điểm / Quán', hint: 'Chọn vị trí trên bản đồ', icon: Icons.map).copyWith(
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.location_on, color: Colors.white),
                              onPressed: () async {
                                final selectedPub = await Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const MapPageSelectLocation()),
                                );
                                if (selectedPub != null) {
                                  setState(() {
                                    _selectedPubName = selectedPub['name'];
                                    _addressController.text = selectedPub['address'];
                                    _selectedLat = selectedPub['latitude'];
                                    _selectedLng = selectedPub['longitude'];
                                  });
                                }
                              },
                            ),
                          ),
                          validator: (v) => v == null || v.isEmpty ? 'Chọn địa điểm' : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _timeController,
                          style: const TextStyle(color: Colors.white70),
                          readOnly: true,
                          decoration: _inputDecoration('Thời gian', hint: 'Chọn ngày giờ', icon: Icons.schedule),
                          onTap: () async {
                            DateTime? pickedDate = await showDatePicker(
                              context: context,
                              initialDate: DateTime.now(),
                              firstDate: DateTime.now(),
                              lastDate: DateTime(2100),
                            );
                            if (pickedDate != null) {
                              TimeOfDay? pickedTime = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay.now(),
                              );
                              if (pickedTime != null) {
                                final dt = DateTime(pickedDate.year, pickedDate.month,
                                    pickedDate.day, pickedTime.hour, pickedTime.minute);
                                _timeController.text =
                                    DateFormat('dd/MM/yyyy HH:mm').format(dt);
                              }
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _contactController,
                          style: const TextStyle(color: Colors.white70),
                          decoration: _inputDecoration('Người liên hệ', hint: 'Tên / SĐT', icon: Icons.person),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _noteController,
                          style: const TextStyle(color: Colors.white70),
                          decoration: _inputDecoration('Ghi chú', hint: 'Các thông tin khác...', icon: Icons.note),
                        ),
                      ],
                    ),
                  ),
                  _buildCard(
                    'Hình ảnh quán / sự kiện',
                    SizedBox(
                      height: 100,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          ..._images.map((item) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Stack(
                              children: [
                                SizedBox(
                                  width: 100,
                                  height: 100,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.file(
                                          item.file,
                                          fit: BoxFit.cover,
                                        ),

                                        if (item.uploading)
                                          shimmer.Shimmer.fromColors(
                                            baseColor: Colors.white.withOpacity(0.08),
                                            highlightColor: Colors.white.withOpacity(0.25),
                                            child: Container(color: Colors.white),
                                          ),

                                        if (item.error)
                                          Container(
                                            color: Colors.black54,
                                            child: const Icon(Icons.error, color: Colors.red, size: 40),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),

                                // Uploading overlay
                                if (item.uploading)
                                  Positioned.fill(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: shimmer.Shimmer.fromColors(
                                        baseColor: Colors.white.withOpacity(0.08),
                                        highlightColor: Colors.white.withOpacity(0.25),
                                        child: Container(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),


                                // Error overlay
                                if (item.error)
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Icon(Icons.error, color: Colors.red, size: 40),
                                    ),
                                  ),
                                // ❌ Delete button
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _images.remove(item);
                                      });
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: const EdgeInsets.all(4),
                                      child: const Icon(
                                        Icons.close,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                          )),
                          ..._videos.map((item) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: item.generatingThumb
                                      ? const VideoPreviewShimmer()
                                      : item.thumbnail != null
                                      ? Image.memory(
                                    item.thumbnail!,
                                    width: 100,
                                    height: 100,
                                    fit: BoxFit.cover,
                                  )
                                      : Container(
                                    width: 100,
                                    height: 100,
                                    color: Colors.grey,
                                    child: const Icon(Icons.videocam),
                                  ),
                                ),

                                if (item.uploading)
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black45,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    ),
                                  ),

                                if (item.error)
                                  const Positioned.fill(
                                    child: Icon(Icons.error, color: Colors.red),
                                  ),

                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _videos.remove(item);
                                      });
                                    },
                                    child: const Icon(Icons.close, color: Colors.white),
                                  ),
                                ),
                              ],
                            ),
                          )),

                          /// Add button
                          GestureDetector(
                            onTap: _pickImage,
                            child: Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.add_a_photo, color: Colors.white),
                            ),
                          ),
                          /// 🎥 ADD VIDEO (THÊM Ở ĐÂY)
                          GestureDetector(
                            onTap: _pickVideo,
                            child: Container(
                              width: 100,
                              height: 100,
                              margin: const EdgeInsets.only(left: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.videocam, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_isLoading)
                    _buildCard(
                      'Chọn loại kèo',
                      _buildCategorySkeleton(),
                    )
                  else
                    _buildCard(
                      'Chọn loại kèo',
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var parent in parentCategories) ...[
                            Text(
                              parent.name,
                              style: TextStyle(
                                color: textWhite,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _buildChoiceChips(
                                parent,
                                parent.name.toLowerCase().contains('đích')
                                    ? _selectedType
                                    : (parent.name.toLowerCase().contains('gia')
                                    ? _selectedArea
                                    : _selectedFeature), (cat) {
                              setState(() {
                                if (parent.name.toLowerCase().contains('đích')) {
                                  _selectedType = cat;
                                } else if (parent.name.toLowerCase().contains('gia')) {
                                  _selectedArea = cat;
                                } else {
                                  _selectedFeature = cat;
                                }
                              });
                            }),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _aiGenerating ? null : _aiGenerateFromServer,

                      icon: _aiGenerating
                          ? const SizedBox.shrink() // 🔥 QUAN TRỌNG
                          : const Icon(Icons.smart_toy, color: Colors.white),

                      label: _aiGenerating
                          ? _shimmerAiThinking()
                          : const Text(
                        'AI tạo nhanh',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),

                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white70),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  SizedBox(
                    height: 56,
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: (_isSubmitting ||
                          _images.any((i) => i.uploading) ||
                          _videos.any((v) => v.uploading || v.generatingThumb))
                          ? null
                          : _submitForm,

                      icon: _isSubmitting
                          ? const SizedBox(width: 0) // ẩn icon khi loading
                          : const Icon(Icons.send, color: Colors.white),

                      label: _isSubmitting
                          ? _shimmerTextButton('Đang gửi...')
                          : const Text(
                        'Tạo lời mời',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),

                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentOrange,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
            if (_aiGenerating)
              Positioned.fill(
                child: AbsorbPointer(
                  child: Container(
                    color: Colors.black.withOpacity(0.35),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          shimmer.Shimmer.fromColors(
                            baseColor: Colors.white.withOpacity(0.3),
                            highlightColor: Colors.white,
                            child: const Icon(
                              Icons.smart_toy,
                              size: 64,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 16),
                          shimmer.Shimmer.fromColors(
                            baseColor: Colors.white.withOpacity(0.4),
                            highlightColor: Colors.white,
                            child: const Text(
                              'AI đang tạo mới...',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],

      ),
    );
  }
}

class Category {
  final int id;
  final String name;
  final int parent;
  final String slug;

  Category({required this.id, required this.name, required this.parent, required this.slug});
}


Widget _buildCategorySkeleton() {
  return shimmer.Shimmer.fromColors(
    baseColor: Colors.white.withOpacity(0.06),
    highlightColor: Colors.white.withOpacity(0.18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _skeletonLine(width: 140),
        const SizedBox(height: 10),

        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(
            6,
                (_) => Container(
              width: 90,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _skeletonLine({double width = 100, double height = 14}) {
  return Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(6),
    ),
  );
}
Widget _shimmerAiThinking() {
  return shimmer.Shimmer.fromColors(
    baseColor: Colors.white.withOpacity(0.4),
    highlightColor: Colors.white,
    child: const Text(
      'AI đang tạo...',
      style: TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

Widget _shimmerTextButton(String text) {
  return shimmer.Shimmer.fromColors(
    baseColor: Colors.white.withOpacity(0.4),
    highlightColor: Colors.white,
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
  );
}




class _ThreeDotsLoading extends StatefulWidget {
  final TextStyle? style;
  const _ThreeDotsLoading({this.style, super.key});

  @override
  State<_ThreeDotsLoading> createState() => _ThreeDotsLoadingState();
}

class _ThreeDotsLoadingState extends State<_ThreeDotsLoading> {
  int dotCount = 0;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      setState(() {
        dotCount = (dotCount + 1) % 4; // 0..3 chấm
      });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '.' * dotCount,
      style: widget.style ?? const TextStyle(color: Colors.white, fontSize: 18),
    );
  }
}

class CurrencyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;

    // Loại bỏ dấu phẩy cũ
    String digits = newValue.text.replaceAll(',', '');

    // Không cho nhập chữ
    if (int.tryParse(digits) == null) return oldValue;

    final number = NumberFormat('#,###').format(int.parse(digits));

    return TextEditingValue(
      text: number,
      selection: TextSelection.collapsed(offset: number.length),
    );
  }
}

