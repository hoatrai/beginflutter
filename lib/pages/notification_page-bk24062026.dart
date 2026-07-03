import 'package:flutter/material.dart';
import 'notification_store.dart';

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {

  @override
  void initState() {
    super.initState();

    // 👇 vào màn hình là reset badge
    NotificationStore.markAllRead();
  }

  @override
  Widget build(BuildContext context) {
    final items = NotificationStore.items;

    return Scaffold(
      extendBody: true,
      backgroundColor: Colors.transparent,

      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF1E3A8A).withOpacity(0.95),
              const Color(0xFFFF7F50).withOpacity(0.85),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),

        child: Column(
          children: [

            // ================= APPBAR =================
            SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Thông báo",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    IconButton(
                      icon: const Icon(Icons.check_circle_outline,
                          color: Colors.white),
                      onPressed: () {
                        NotificationStore.markAllRead();
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
            ),

            // ================= BODY =================
            Expanded(
              child: items.isEmpty
                  ? const Center(
                child: Text(
                  "Không có thông báo",
                  style: TextStyle(color: Colors.white70),
                ),
              )
                  : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final n = items[i];

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        NotificationStore.markRead(n.id);
                        setState(() {});
                      },

                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),

                          gradient: n.isRead
                              ? LinearGradient(
                            colors: [
                              Colors.white.withOpacity(0.08),
                              Colors.white.withOpacity(0.04),
                            ],
                          )
                              : LinearGradient(
                            colors: [
                              const Color(0xFFFF7F50).withOpacity(0.25),
                              const Color(0xFF1E3A8A).withOpacity(0.25),
                            ],
                          ),

                          border: Border.all(
                            color: Colors.white.withOpacity(0.12),
                          ),

                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            )
                          ],
                        ),

                        child: Row(
                          children: [

                            // ================= ICON =================
                            Container(
                              width: 44,
                              height: 44,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFFFF7F50),
                                    Color(0xFF1E3A8A),
                                  ],
                                ),
                              ),
                              child: Icon(
                                n.isRead
                                    ? Icons.notifications_none
                                    : Icons.notifications_active,
                                color: Colors.white,
                              ),
                            ),

                            const SizedBox(width: 12),

                            // ================= TEXT =================
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    n.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),

                                  const SizedBox(height: 4),

                                  Text(
                                    n.body,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.75),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 10),

                            // ================= TIME =================
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  "${n.time.hour}:${n.time.minute.toString().padLeft(2, '0')}",
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withOpacity(0.6),
                                  ),
                                ),

                                const SizedBox(height: 6),

                                if (!n.isRead)
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}