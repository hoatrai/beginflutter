import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/wordpress_service.dart';

class BlogPage extends StatefulWidget {
  final String baseUrl;
  const BlogPage({super.key, required this.baseUrl});

  @override
  State<BlogPage> createState() => _BlogPageState();
}

class _BlogPageState extends State<BlogPage> {
  late final WordPressService service;
  late Future<List<Post>> postsFuture;

  @override
  void initState() {
    super.initState();
    service = WordPressService(widget.baseUrl); // ✅ dùng widget.baseUrl
    postsFuture = service.getPosts().then((data) => data['posts'] as List<Post>);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("SpiritWebs Blog")),
      body: FutureBuilder<List<Post>>(
        future: postsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          }

          final posts = snapshot.data ?? [];

          return ListView.builder(
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final post = posts[index];
              return Card(
                margin: const EdgeInsets.all(10),
                child: ListTile(
                  title: Text(
                    post.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Html(
                    data: post.excerpt,
                    style: {
                      "body": Style(
                        fontSize: FontSize(14),
                        color: Colors.black54,
                      )
                    },
                  ),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BlogDetailPage(post: post),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class BlogDetailPage extends StatelessWidget {
  final Post post;
  const BlogDetailPage({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(post.title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Html(
          data: post.content,
          style: {
            "body": Style(
              fontSize: FontSize(16),
              color: Colors.black87,
            )
          },
        ),
      ),
    );
  }
}
