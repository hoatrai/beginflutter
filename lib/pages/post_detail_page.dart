import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/wordpress_service.dart';

class PostDetailPage extends StatelessWidget {
  final Post post;
  const PostDetailPage({super.key, required this.post});

  Future<void> _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      // can't open
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(post.title),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            if (post.featuredImage.isNotEmpty)
              CachedNetworkImage(
                imageUrl: post.featuredImage,
                height: 220,
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: (_, __) => const SizedBox(height: 220, child: Center(child: CircularProgressIndicator())),
                errorWidget: (_, __, ___) => const SizedBox(height: 220, child: Center(child: Icon(Icons.broken_image))),
              ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(post.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(post.date.split('T').first, style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  Html(
                    data: post.content,
                    onLinkTap: (url, context, attributes, element) {
                      if (url != null) _launchURL(url);
                    },
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
