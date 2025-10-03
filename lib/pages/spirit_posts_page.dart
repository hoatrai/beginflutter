import 'package:flutter/material.dart';
import '../services/wordpress_service.dart';
import 'post_detail_page.dart';

class SpiritPostsPage extends StatefulWidget {
  const SpiritPostsPage({super.key});
  @override
  State<SpiritPostsPage> createState() => _SpiritPostsPageState();
}

class _SpiritPostsPageState extends State<SpiritPostsPage> {
  final service = WordPressService('https://spiritwebs.com');
  final ScrollController _scrollController = ScrollController();

  List<Post> posts = [];
  int page = 1;
  final int perPage = 10;
  int totalPages = 1;
  bool isLoading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadPage(reset: true);
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200 &&
          !isLoading &&
          page < totalPages) {
        _loadPage();
      }
    });
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (isLoading) return;
    setState(() {
      isLoading = true;
      error = null;
      if (reset) {
        page = 1;
        totalPages = 1;
      }
    });

    try {
      final result = await service.getPosts(page: page, perPage: perPage);
      final List<Post> fetched = (result['posts'] as List<Post>);
      final int tp = result['totalPages'] as int;

      setState(() {
        totalPages = tp;
        if (reset) {
          posts = fetched;
        } else {
          posts.addAll(fetched);
        }
        page++;
      });
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _onRefresh() async {
    await _loadPage(reset: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _stripHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SpiritWebs Blog')),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        child: error != null
            ? ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: 120),
            Center(child: Text('Error: $error')),
            const SizedBox(height: 20),
            Center(
              child: ElevatedButton(
                onPressed: () => _loadPage(reset: true),
                child: const Text('Thử lại'),
              ),
            ),
          ],
        )
            : ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: posts.length + 1,
          itemBuilder: (context, index) {
            if (index == posts.length) {
              // footer loader or nothing
              if (isLoading) {
                return const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Center(child: CircularProgressIndicator()),
                );
              } else {
                return const SizedBox(height: 24);
              }
            }
            final post = posts[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: ListTile(
                leading: post.featuredImage.isNotEmpty
                    ? SizedBox(
                  width: 64,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      post.featuredImage,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.image),
                    ),
                  ),
                )
                    : CircleAvatar(child: Text(post.title.isNotEmpty ? post.title[0] : '?')),
                title: Text(post.title),
                subtitle: Text(_stripHtml(post.excerpt), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text(post.date.split('T').first, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => PostDetailPage(post: post)));
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
