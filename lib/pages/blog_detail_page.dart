import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

class BlogDetailPage extends StatelessWidget {
  final Map post;
  const BlogDetailPage({super.key, required this.post});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title:
          Text(post["title"]["rendered"], style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.blue),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Html(data: post["content"]["rendered"]),
      ),
    );
  }
}
