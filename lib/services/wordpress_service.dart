import 'dart:convert';
import 'package:http/http.dart' as http;

/// ================= MODEL POST =================
class Post {
  final int id;
  final String title;
  final String excerpt;
  final String content;
  final String date;
  final String link;
  final String featuredImage;

  Post({
    required this.id,
    required this.title,
    required this.excerpt,
    required this.content,
    required this.date,
    required this.link,
    required this.featuredImage,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    String featured = '';
    try {
      final embedded = json['_embedded']?['wp:featuredmedia'];
      if (embedded != null && embedded is List && embedded.isNotEmpty) {
        featured = embedded[0]['source_url'] ?? '';
      }
    } catch (_) {}

    return Post(
      id: json['id'] ?? 0,
      title: json['title']?['rendered'] ?? '',
      excerpt: json['excerpt']?['rendered'] ?? '',
      content: json['content']?['rendered'] ?? '',
      date: json['date'] ?? '',
      link: json['link'] ?? '',
      featuredImage: featured,
    );
  }
}

/// ================= MODEL USER LOCATION =================
class UserLocation {
  final int userId;
  final double latitude;
  final double longitude;
  final String? name;      // display_name
  final String? username;  // user_login (vd: user10)
  final String? email;

  UserLocation({
    required this.userId,
    required this.latitude,
    required this.longitude,
    this.name,
    this.username,
    this.email,
  });

  factory UserLocation.fromJson(Map<String, dynamic> json) {
    final latVal = json['lat'] ?? json['latitude'];
    final lngVal = json['lng'] ?? json['longitude'];

    return UserLocation(
      userId: int.tryParse(json['id']?.toString() ?? "0") ?? 0,
      latitude: latVal != null ? double.tryParse(latVal.toString()) ?? 0.0 : 0.0,
      longitude: lngVal != null ? double.tryParse(lngVal.toString()) ?? 0.0 : 0.0,
      name: json['name'],         // display_name
      username: json['username'], // user_login
      email: json['email'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "id": userId,
      "lat": latitude.toString(),
      "lng": longitude.toString(),
      "name": name,
      "username": username,
      "email": email,
    };
  }
}

/// ================= SERVICE =================
class WordPressService {
  final String baseUrl;
  WordPressService(this.baseUrl);

  // ----------- POSTS -----------
  Future<Map<String, dynamic>> getPosts({int page = 1, int perPage = 10}) async {
    final url = Uri.parse('$baseUrl/wp-json/wp/v2/posts?page=$page&per_page=$perPage&_embed');
    final response = await http.get(url).timeout(const Duration(seconds: 12));

    if (response.statusCode == 200) {
      final List<dynamic> jsonList = jsonDecode(response.body);
      final posts = jsonList.map((j) => Post.fromJson(j as Map<String, dynamic>)).toList();

      int totalPages = int.tryParse(response.headers['x-wp-totalpages'] ?? '1') ?? 1;

      return {'posts': posts, 'totalPages': totalPages};
    } else {
      throw Exception('Failed to load posts (${response.statusCode})');
    }
  }

  Future<Post> getPostById(int id) async {
    final url = Uri.parse('$baseUrl/wp-json/wp/v2/posts/$id?_embed');
    final response = await http.get(url).timeout(const Duration(seconds: 12));

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return Post.fromJson(json);
    } else {
      throw Exception('Failed to load post (${response.statusCode})');
    }
  }

  // ----------- USER LOCATION -----------
  Future<UserLocation> fetchUserLocation(String token) async {
    final url = Uri.parse('$baseUrl/wp-json/wp/v2/users/me');
    final response = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
    }).timeout(const Duration(seconds: 12));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final location = data['location'] ?? {};
      location['id'] = data['id'];
      location['username'] = data['username'];       // user_login
      location['name'] = data['name'];               // display_name
      location['email'] = data['email'];             // email
      return UserLocation.fromJson(location);
    } else {
      throw Exception('Failed to fetch user location (${response.statusCode})');
    }
  }

  Future<void> updateUserLocation(String token, double latitude, double longitude) async {
    final url = Uri.parse('$baseUrl/wp-json/spiritwebs/v1/update-location');

    final body = jsonEncode({
      "lat": latitude,
      "lng": longitude,
    });

    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $token', // token user login
        'Content-Type': 'application/json',
      },
      body: body,
    ).timeout(const Duration(seconds: 12));

    if (response.statusCode != 200) {
      throw Exception('Failed to update user location (${response.statusCode}): ${response.body}');
    }
  }


  Future<List<UserLocation>> fetchAllUserLocations() async {
    final response = await http.get(
      Uri.parse("$baseUrl/wp-json/spiritwebs/v1/user-locations"),
    );

    if (response.statusCode == 200) {
      final List data = jsonDecode(response.body);
      return data.map((e) => UserLocation.fromJson(e)).toList();
    } else {
      throw Exception("Lỗi fetch user locations");
    }
  }
}
