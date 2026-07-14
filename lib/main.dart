import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'helpers/lifecycle_tracker.dart';
import 'helpers/user_helper.dart';
import 'config/app_config.dart';
import 'services/global_call_service.dart';
import 'services/callkit_service.dart';
import 'services/presence_service.dart';
import 'app_globals.dart';
import 'helpers/storage_helper.dart';
import 'pages/profile_page.dart';
import 'pages/shop_page.dart';
import 'pages/flutter_map.dart';
import 'pages/group_page.dart';
import 'pages/create_invite_page.dart';
import 'pages/splash_page.dart';
import 'pages/product_detail_page.dart';
import 'pages/chat_page.dart';
import 'pages/group_chat_page.dart';
import 'pages/notification_store.dart';
import 'pages/video_call_page.dart';

// ---------------- GLOBAL STATE ----------------

final ValueNotifier<int> unreadNotiVN = ValueNotifier<int>(0);

// 🚀 Báo cho các trang giữ trong IndexedStack (ShopPage, MapPage...) biết
// tab nào đang thực sự hiển thị, để chúng tạm dừng timer/animation chạy
// nền (vd auto-scroll 60fps) khi người dùng đang ở tab khác — tránh tốn
// CPU/pin vô ích vì IndexedStack giữ nguyên state của các tab ẩn.
final ValueNotifier<int> activeTabIndexVN = ValueNotifier<int>(0);

String? pendingKeoId;
Map<String, dynamic>? _pendingGroupChatData; // lưu FCM group-chat khi app bị terminated
Map<String, dynamic>? _pendingCallData; // lưu FCM call khi app bị terminated
OverlayEntry? _appNotificationOverlay;
Timer? _notificationDismissTimer;

class WooCommerceConfig {
  static const consumerKey = 'ck_3809ad31dd47ca7d10573e35ccdf746494b305a9';
  static const consumerSecret = 'cs_a49b903ddc7972646359f360d79343cd1e33b6f8';
  static const productsUrl = '${AppConfig.webDomain}/wp-json/wc/v3/products';
}

// ---------------- FIREBASE BACKGROUND HANDLER ----------------

// 🆕 FIX (lỗi "chỉ hiện notification, không biết có ai gọi"): trước đây
// handler này không làm gì ngoài init Firebase, nên khi app ở nền/bị kill,
// cuộc gọi đến chỉ hiện được 1 dòng notification thụ động do OS tự vẽ từ
// field "notification" trong payload FCM — không chuông, không rung, không
// full-screen, rất dễ bị bỏ lỡ.
//
// Giờ khi nhận FCM type "video_call" ở đây, chủ động gọi
// CallkitService.showIncomingCall() để hiện MÀN HÌNH CUỘC GỌI ĐẾN THẬT SỰ
// của hệ điều hành (Android: full-screen Activity + chuông đổ + rung, kể cả
// khi máy khoá; iOS: CallKit) — giống trải nghiệm cuộc gọi điện thoại thường
// thay vì chỉ 1 thông báo im lìm.
//
// ⚠️ Cần thêm cấu hình native (AndroidManifest / Info.plist / pubspec) —
// xem file docs/callkit_setup.md đi kèm để biết chính xác cần thêm gì.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('Background message: ${message.messageId}');

  final data = message.data;
  final type = data['type'];

  if (type == 'video_call') {
    await CallkitService.instance.showIncomingCall(data);
    return;
  }

  if (type == 'call_cancel') {
    // Người gọi đã huỷ trước khi bên nghe kịp bắt máy -> dẹp luôn màn hình
    // cuộc gọi native đang đổ chuông (nếu không, nó sẽ tự treo tới hết
    // `duration` 30s mới tự tắt, gây khó chịu / hiện nhầm "cuộc gọi nhỡ").
    final topic = data['topic'] as String?;
    if (topic != null) {
      await CallkitService.instance.endCall(topic);
    }
    return;
  }

  // Các loại push khác: Android tự hiện notification nếu server gửi kèm
  // "notification" field trong FCM payload, không cần xử lý gì thêm ở đây.
}

// ---------------- CALL PAYLOAD HANDLER ----------------

/// Xử lý data call — dùng chung cho tap notification & getInitialMessage
void _handleCallPayload(Map<String, dynamic> data) {
  if (data['type'] != 'video_call') return;

  final overlay = navigatorKey.currentState?.overlay;
  if (overlay == null) {
    // Navigator chưa sẵn sàng → lưu lại xử lý sau trong MainPage.initState
    _pendingCallData = data;
    return;
  }
  GlobalCallService.instance.handleFcmCall(data);
}

// ---------------- OPEN CHAT / INVITE ----------------

class _ResolvedUser {
  final int id;
  final String username;
  const _ResolvedUser(this.id, this.username);
}

/// Xác định "mình là ai" để mở trang chat/nhóm khi bấm 1 thông báo.
/// Ưu tiên đọc từ cache local (đã lưu sẵn lúc app khởi động — xem
/// MainPage._bootstrap) để KHÔNG phụ thuộc mạng ngay lúc bấm, tránh
/// bị timeout như fetchMe() hay gặp. Chỉ gọi API /me khi cache trống.
Future<_ResolvedUser?> _resolveCurrentUser() async {
  try {
    final cached = await UserHelper.getCurrentUser();
    final cachedId = int.tryParse(cached['id']?.toString() ?? '') ?? 0;
    if (cachedId > 0) {
      final name = (cached['username'] ?? cached['display_name'] ?? '').toString();
      return _ResolvedUser(cachedId, name);
    }
  } catch (e) {
    debugPrint("⚠️ _resolveCurrentUser: đọc cache local lỗi $e");
  }

  // Fallback: cache trống (chưa từng bootstrap) -> thử gọi mạng,
  // nhưng giới hạn thời gian ngắn hơn để tránh treo UI quá lâu.
  try {
    final me = await fetchMe().timeout(const Duration(seconds: 8));
    if (me != null) {
      final id = int.tryParse(me['id'].toString()) ?? 0;
      if (id > 0) {
        final name = (me['username'] ?? me['display_name'] ?? '').toString();
        return _ResolvedUser(id, name);
      }
    }
  } catch (e) {
    debugPrint("⚠️ _resolveCurrentUser: fetchMe() lỗi/timeout $e");
  }

  return null;
}

/// Trả về true nếu điều hướng thành công, false nếu có lỗi (mất mạng,
/// chưa đăng nhập, thiếu dữ liệu...) — để UI (vd NotificationPage) có thể
/// báo cho người dùng biết thay vì im lặng không làm gì.
Future<bool> _openChatFromData(Map<String, dynamic> data) async {
  try {
    final senderIdRaw = data['sender_id']?.toString();
    final senderId = int.tryParse(senderIdRaw ?? '') ?? 0;
    if (senderId == 0) {
      debugPrint("⚠️ openChat: thiếu/không hợp lệ sender_id trong data=$data");
      return false;
    }
    final senderName = data['sender_username']?.toString() ?? 'Người dùng';

    final me = await _resolveCurrentUser();
    if (me == null) {
      debugPrint("⚠️ openChat: không xác định được user hiện tại (cache trống + fetchMe lỗi/timeout)");
      return false;
    }

    final myId = me.id;
    final myUsername = me.username;

    final nav = navigatorKey.currentState;
    if (nav == null) {
      debugPrint("⚠️ openChat: navigatorKey.currentState null");
      return false;
    }

    nav.push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          userId: myId,
          username: myUsername,
          targetId: senderId,
          targetUser: senderName,
        ),
      ),
    );
    return true;
  } catch (e) {
    debugPrint("❌ Open chat error: $e");
    return false;
  }
}

Future<void> openChatFromNotification(RemoteMessage message) =>
    _openChatFromData(message.data);

Future<bool> openChatFromData(Map<String, dynamic> data) =>
    _openChatFromData(data);

// ---------------- OPEN GROUP CHAT ----------------

/// Mở đúng phòng chat nhóm khi bấm vào thông báo "group_chat_message"
/// (xem lib/phoenix_socket/notifications.ex -> send_new_group_chat_notification,
/// data gửi kèm: group_id, sender_id, sender_name, message).
Future<bool> _openGroupChatFromData(Map<String, dynamic> data) async {
  try {
    final groupId = int.tryParse(data['group_id']?.toString() ?? '') ?? 0;
    if (groupId == 0) {
      debugPrint("⚠️ openGroupChat: thiếu/không hợp lệ group_id trong data=$data");
      return false;
    }

    final me = await _resolveCurrentUser();
    if (me == null) {
      debugPrint("⚠️ openGroupChat: không xác định được user hiện tại (cache trống + fetchMe lỗi/timeout)");
      return false;
    }

    final myId = me.id;
    final myUsername = me.username;

    // Tên nhóm không được gửi kèm trong payload FCM, dùng tên người gửi
    // làm tiêu đề tạm — GroupChatPage sẽ tự đồng bộ lại tên/avatar nhóm
    // thật khi tải dữ liệu.
    final fallbackGroupName =
        data['group_name']?.toString() ?? data['sender_name']?.toString() ?? 'Nhóm chat';

    final nav = navigatorKey.currentState;
    if (nav == null) {
      debugPrint("⚠️ openGroupChat: navigatorKey.currentState null");
      return false;
    }

    nav.push(
      MaterialPageRoute(
        builder: (_) => GroupChatPage(
          userId: myId,
          username: myUsername,
          groupId: groupId,
          groupName: fallbackGroupName,
        ),
      ),
    );
    return true;
  } catch (e) {
    debugPrint("❌ Open group chat error: $e");
    return false;
  }
}

Future<void> openGroupChatFromNotification(RemoteMessage message) =>
    _openGroupChatFromData(message.data);

Future<bool> openGroupChatFromData(Map<String, dynamic> data) =>
    _openGroupChatFromData(data);

// ---------------- ENTRY POINT ----------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ THÊM: bắt buộc gọi 1 lần trước runApp() để mở kênh giao tiếp giữa
  // isolate chính và isolate của CallForegroundService (services/call_foreground_service.dart).
  // Xem giải thích đầy đủ trong file đó — đây là phần còn thiếu khiến
  // flutter_foreground_task có trong pubspec.yaml nhưng chưa từng chạy.
  FlutterForegroundTask.initCommunicationPort();

  // 🆕 Nối CallkitService (màn hình cuộc gọi đến NATIVE) với GlobalCallService
  // (nơi thật sự xử lý accept/reject: kết nối lại channel, mở VideoCallPage).
  // PHẢI gán callback TRƯỚC khi gọi CallkitService.instance.init(), vì
  // init() có thể tự trigger accept ngay (trường hợp app mở lên từ việc
  // bấm "Nghe" trên cuộc gọi native lúc app đang bị kill — xem
  // checkPendingAcceptedCall() trong callkit_service.dart).
  CallkitService.instance.onAccept = GlobalCallService.instance.acceptCallFromNative;
  CallkitService.instance.onReject = GlobalCallService.instance.rejectCallFromNative;

  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await setupFirebaseMessaging();
  } catch (e) {
    debugPrint('⚠️ Firebase init failed: $e');
  }

  try {
    await CallkitService.instance.init();
  } catch (e) {
    debugPrint('⚠️ CallkitService init failed: $e');
  }

  runApp(const CryptoApp(initialPage: SplashPage()));
}

// ---------------- API HELPERS ----------------

Future<Map<String, dynamic>?> _fetchProductById(String productId) async {
  try {
    final uri = Uri.parse(
      "${WooCommerceConfig.productsUrl}/$productId"
          "?consumer_key=${WooCommerceConfig.consumerKey}"
          "&consumer_secret=${WooCommerceConfig.consumerSecret}",
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) return null;
    return jsonDecode(res.body) as Map<String, dynamic>;
  } catch (e) {
    debugPrint("Fetch product error: $e");
    return null;
  }
}

Future<bool> _navigateToInvite(String keoId) async {
  if (keoId.trim().isEmpty) {
    debugPrint("⚠️ openInvite: keoId rỗng");
    return false;
  }

  final product = await _fetchProductById(keoId);
  if (product == null) {
    debugPrint("⚠️ openInvite: không fetch được sản phẩm keoId=$keoId "
        "(có thể đã bị xoá / mất mạng / sai id)");
    return false;
  }

  final nav = navigatorKey.currentState;
  if (nav == null) {
    debugPrint("⚠️ openInvite: navigatorKey.currentState null");
    return false;
  }

  nav.push(
    MaterialPageRoute(builder: (_) => ProductDetailPage(product: product)),
  );
  return true;
}

Future<void> openInviteFromNotification(RemoteMessage message) async {
  final keoId = message.data['keo_id'] ?? message.data['product_id'];
  if (keoId == null) return;
  await _navigateToInvite(keoId);
}

Future<bool> openInviteById(String keoId) => _navigateToInvite(keoId);

// ---------------- IN-APP NOTIFICATION BANNER ----------------

void showAppNotification({required String title, required String body}) {
  final overlay = navigatorKey.currentState?.overlay;
  if (overlay == null) return;

  _notificationDismissTimer?.cancel();
  _appNotificationOverlay?.remove();

  _appNotificationOverlay = OverlayEntry(
    builder: (context) {
      return Positioned(
        top: 60,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1E3A8A).withOpacity(0.95),
                  const Color(0xFFFF7F50).withOpacity(0.85),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active,
                          color: Colors.white, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              body,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(_appNotificationOverlay!);

  _notificationDismissTimer = Timer(const Duration(seconds: 3), () {
    _appNotificationOverlay?.remove();
    _appNotificationOverlay = null;
  });
}

// ---------------- FIREBASE MESSAGING SETUP ----------------

Future<void> setupFirebaseMessaging() async {
  final messaging = FirebaseMessaging.instance;

  final settings = await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  debugPrint('Permission: ${settings.authorizationStatus}');

  final token = await messaging.getToken();
  debugPrint("FCM Token: $token");

  await messaging.subscribeToTopic("all_devices");

  // Foreground: app đang mở
  FirebaseMessaging.onMessage.listen((message) {
    final type = message.data['type'];

    if (type == 'video_call') {
      GlobalCallService.instance.handleFcmCall(message.data);
      return;
    }
    if (type == 'call_cancel') {
      GlobalCallService.instance.cancelPendingCall(message.data['topic']);
      return;
    }

    // 🔥 Chặn triệt để "thông báo rỗng": bất kỳ push nào KHÔNG có payload
    // "notification" (data-only / silent push) đều không được tạo item
    // trong NotificationStore, bất kể type là gì. Trước đây chỉ lọc theo
    // whitelist cứng 2 type (video_call, call_cancel) — nếu sau này có
    // thêm 1 loại push câm mới mà quên thêm vào whitelist, hoặc gặp race
    // condition khiến type bị đọc sai, nó sẽ lọt qua và tạo ra 1 thông
    // báo title="Thông báo" + body rỗng. Check thẳng vào sự tồn tại của
    // `notification` payload thay vì đoán theo type là cách chặn đúng gốc.
    if (message.notification == null) {
      debugPrint('⚠️ Bỏ qua push data-only (không có notification payload): type=$type');
      return;
    }

    final title = message.notification?.title ?? "Thông báo";
    final body = message.notification?.body ?? "";

    // 🔥 Phòng thêm trường hợp server gửi notification nhưng title/body
    // rỗng (chuỗi rỗng "", không phải null) — vẫn không cho vào store.
    if (title.trim().isEmpty && body.trim().isEmpty) {
      debugPrint('⚠️ Bỏ qua push có title/body rỗng: type=$type');
      return;
    }

    NotificationStore.add(
      title: title,
      body: body,
      type: type,
      data: message.data,
    );

    unreadNotiVN.value++;

    // Không hiện banner nếu đang mở đúng cuộc chat với người gửi tin
    final senderId = int.tryParse(message.data['sender_id'] ?? '') ?? -1;
    final isChattingWithSender =
        isChatPageOpen && currentChatTargetId != null && currentChatTargetId == senderId;

    // ✅ Không hiện banner nếu đang mở đúng nhóm chat nhận tin
    final groupId = int.tryParse(message.data['group_id'] ?? '') ?? -1; // đổi key nếu backend đặt tên khác
    final isViewingSameGroup =
        isGroupChatPageOpen && currentGroupChatId != null && currentGroupChatId == groupId;

    // ✅ Không hiện banner nếu đang mở đúng trang chi tiết kèo (invite) —
    // trang đó đã tự hiện SnackBar realtime qua socket rồi (xem
    // product_detail_page.dart -> _showInviteNotification).
    final inviteIdFromData = int.tryParse(message.data['invite_id'] ?? '') ?? -1;
    const inviteEventTypes = {'user_joined', 'user_left', 'user_kicked'};
    final isViewingSameInvite = inviteEventTypes.contains(type) &&
        isInviteDetailOpen &&
        currentInviteId != null &&
        currentInviteId == inviteIdFromData;

    if (!isChattingWithSender && !isViewingSameGroup && !isViewingSameInvite) {
      showAppNotification(title: title, body: body);
    }
  });

  // Background: app chưa tắt, user tap notification
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    debugPrint('onMessageOpenedApp: ${message.data}');
    final type = message.data['type'];
    if (type == 'video_call') {
      _handleCallPayload(message.data);
    } else if (type == 'invite_keo' || type == 'new_product') {
      openInviteFromNotification(message);
    } else if (type == 'chat_message') {
      openChatFromNotification(message);
    } else if (type == 'group_chat_message') {
      openGroupChatFromNotification(message);
    } else if (type == 'user_joined' || type == 'user_left' || type == 'user_kicked') {
      openInviteFromNotification(message); // dùng chung keo_id -> mở đúng trang chi tiết
    }
  });

  // Terminated: app bị tắt hoàn toàn, user tap notification mở app
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    final type = initialMessage.data['type'];
    if (type == 'video_call') {
      // Lưu lại, xử lý sau khi navigator sẵn sàng (MainPage._openPendingCall)
      _pendingCallData = initialMessage.data;
    } else if (type == 'invite_keo' || type == 'new_product') {
      pendingKeoId = initialMessage.data['keo_id'] ?? initialMessage.data['product_id'];
    } else if (type == 'user_joined' || type == 'user_left' || type == 'user_kicked') {
      pendingKeoId = initialMessage.data['keo_id'];
    } else if (type == 'chat_message') {
      Future.delayed(
        const Duration(seconds: 1),
            () => openChatFromNotification(initialMessage),
      );
    } else if (type == 'group_chat_message') {
      // Lưu lại, xử lý sau khi navigator sẵn sàng (MainPage._openPendingGroupChat)
      _pendingGroupChatData = initialMessage.data;
    }
  }
}

// ---------------- CUSTOM SLIDE TRANSITION (né lỗi CupertinoPageTransitionsBuilder) ----------------
// Transition trượt ngang đơn thuần, KHÔNG fade/scale -> tránh hẳn 1 frame
// bị "chớp trắng" do compositing opacity giữa 2 route lúc chuyển trang.
class _NoFlashPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoFlashPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
      ) {
    final slideIn = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));

    final slideOut = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-0.3, 0.0),
    ).animate(CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic));

    return SlideTransition(
      position: slideOut,
      child: SlideTransition(
        position: slideIn,
        child: child,
      ),
    );
  }
}

class CryptoApp extends StatelessWidget {
  final Widget initialPage;
  const CryptoApp({super.key, required this.initialPage});

  @override
  Widget build(BuildContext context) {
    return AppLifecycleTracker(
      onStateChanged: (state) {
        debugPrint("🔥 APP STATE => $state");
        // Không disconnect socket khi vào background — chỉ đổi trạng thái
        // để user khác thấy "away" thay vì mất hẳn khỏi bản đồ.
        if (state == "FOREGROUND") {
          PresenceService.instance.setAppStatus("online");
        } else if (state == "BACKGROUND") {
          PresenceService.instance.setAppStatus("background");
        }
      },
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Crypto App',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.deepPurple,
          scaffoldBackgroundColor: const Color(0xFFF4F6FB),
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: _NoFlashPageTransitionsBuilder(),
              TargetPlatform.iOS: _NoFlashPageTransitionsBuilder(),
            },
          ),
        ),
        home: initialPage,
      ),
    );
  }
}

// ---------------- MAIN PAGE ----------------

class MainPage extends StatefulWidget {
  const MainPage({super.key});
  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  Map<String, dynamic> _userData = {"slug": "Khách", "email": ""};
  int _userId = 0;
  bool _loading = true;

  final List<Widget?> _pageCache = List<Widget?>.filled(4, null);
  late final AnimationController _fabController;
  late final Animation<double> _fabAnimation;

  final Color primaryBlue = const Color(0xFF1E3A8A);
  final Color accentOrange = const Color(0xFFFF7F50);

  @override
  void initState() {
    super.initState();

    _fabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fabAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.easeInOut),
    );

    _bootstrap();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openPendingInvite();
      _openPendingGroupChat();
      _openPendingCall();
      _openPendingNativeCall();
    });
  }

  @override
  void dispose() {
    _fabController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    Map<String, dynamic> userData = {"slug": "Khách", "email": ""};
    int userId = 0;

    try {
      final jsonString = await StorageHelper.read("user_data");
      final userIdString = await StorageHelper.read("user_id");

      if (jsonString != null && jsonString.isNotEmpty) {
        try {
          final decoded = jsonDecode(jsonString);
          if (decoded is Map<String, dynamic>) userData = decoded;
        } catch (e) {
          debugPrint("Lỗi parse user_data: $e");
        }
      }

      userId = int.tryParse(userIdString ?? '') ?? 0;
    } catch (e) {
      debugPrint("Lỗi đọc storage: $e");
    }

    if (!mounted) return;
    setState(() {
      _userData = userData;
      _userId = userId;
      _loading = false;
      _pageCache[_selectedIndex] = _pageFor(_selectedIndex);
    });

    // 🌍 Bật presence toàn app ngay khi biết userId — sống suốt phiên app,
    // không phụ thuộc user có đang mở tab "Bản đồ" hay không.
    if (userId != 0) {
      PresenceService.instance.start(
        userId: userId,
        username: userData['display_name'] ?? userData['slug'] ?? 'Khách',
      );
    }
  }

  Widget _pageFor(int index) {
    switch (index) {
      case 0:
        return const ShopPage();
      case 1:
        return MapPage(
          userId: _userId,
          username: _userData['display_name'] ?? _userData['slug'] ?? 'Khách',
          email: _userData['email'] ?? '',
        );
      case 2:
        return const GroupPage();
      case 3:
        return const ProfilePage();
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _openPendingInvite() async {
    if (pendingKeoId == null) return;
    final id = pendingKeoId!;
    pendingKeoId = null;
    await Future.delayed(const Duration(milliseconds: 500));
    openInviteById(id);
  }

  /// Xử lý tap vào thông báo chat nhóm khi app vừa mở từ terminated state.
  Future<void> _openPendingGroupChat() async {
    if (_pendingGroupChatData == null) return;
    final data = _pendingGroupChatData!;
    _pendingGroupChatData = null;
    await Future.delayed(const Duration(milliseconds: 500));
    openGroupChatFromData(data);
  }

  /// Xử lý cuộc gọi đến khi app vừa mở từ terminated state.
  Future<void> _openPendingCall() async {
    if (_pendingCallData == null) return;
    final data = _pendingCallData!;
    _pendingCallData = null;
    await Future.delayed(const Duration(seconds: 1));
    GlobalCallService.instance.handleFcmCall(data);
  }

  /// 🆕 Xử lý cuộc gọi đã được NGHE ngay trên màn hình CallKit native lúc
  /// app đang bị kill hẳn (xem `PendingNativeCall` trong
  /// services/app_globals.dart để hiểu vì sao cần bước này thay vì
  /// GlobalCallService tự push thẳng vào navigator).
  Future<void> _openPendingNativeCall() async {
    if (pendingNativeCall == null) return;
    final call = pendingNativeCall!;
    pendingNativeCall = null;
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoCallPage(
          socket: call.socket,
          topic: call.topic,
          isCaller: false,
          callType: call.callType,
          targetName: call.targetName,
          targetAvatar: call.targetAvatar,
        ),
      ),
    );
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
      _pageCache[index] ??= _pageFor(index);
    });
    activeTabIndexVN.value = index; // 🚀 báo cho các tab biết ai đang active
  }

  Widget _navItem(IconData icon, String label, int index) {
    final isSelected = _selectedIndex == index;
    // 👇 SỬA: Colors.grey[700] quá tối, gần như "chìm" vào nền navy đậm
    // (scaffoldBackgroundColor: 0xFF0D1B2A) khi KHÔNG được chọn.
    // Đổi sang màu sáng (trắng ngả xám) để đủ tương phản trên nền tối.
    final unselectedColor = Colors.white.withOpacity(0.55);

    return GestureDetector(
      onTap: () => _onItemTapped(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isSelected ? accentOrange : unselectedColor),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? accentOrange : unselectedColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              primaryBlue.withOpacity(0.1),
              accentOrange.withOpacity(0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: _loading
            ? const Center(
          child: CircularProgressIndicator(color: Color(0xFFFF7F50)),
        )
            : IndexedStack(
          index: _selectedIndex,
          children: List<Widget>.generate(
            _pageCache.length,
                (i) => _pageCache[i] ?? const SizedBox.shrink(),
          ),
        ),
      ),
      floatingActionButton: MouseRegion(
        onEnter: (_) => _fabController.forward(),
        onExit: (_) => _fabController.reverse(),
        child: AnimatedBuilder(
          animation: _fabAnimation,
          builder: (context, child) => Transform.scale(
            scale: _fabAnimation.value,
            child: FloatingActionButton(
              backgroundColor: accentOrange,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateInvitePage()),
                );
              },
              child: const Icon(Icons.add, size: 36, color: Colors.white),
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        color: Colors.transparent,
        elevation: 0,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                primaryBlue.withOpacity(0.2),
                accentOrange.withOpacity(0.1),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(Icons.group, "Lời mời", 0),
              _navItem(Icons.map_outlined, "Bản đồ", 1),
              const SizedBox(width: 40),
              _navItem(Icons.article_outlined, "Quán", 2),
              _navItem(Icons.account_circle_outlined, "Hồ sơ", 3),
            ],
          ),
        ),
      ),
    );
  }
}