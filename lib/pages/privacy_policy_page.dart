import 'package:flutter/material.dart';
import 'legal_page.dart';

/// ⚠️ Nội dung mẫu — hãy đọc kỹ và chỉnh sửa lại cho khớp với thực tế
/// dữ liệu app đang thu thập (đã thấy trong code: vị trí GPS qua
/// Geolocator, JWT token, FCM token cho push notification, thông tin
/// tài khoản/kèo qua WordPress) trước khi phát hành chính thức.
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const LegalPage(
      title: "Chính sách bảo mật",
      sections: [
        LegalSection(
          body: "Cập nhật lần cuối: 17/07/2026\n\n"
              "Chính sách bảo mật này giải thích cách chúng tôi thu thập, "
              "sử dụng và bảo vệ thông tin cá nhân của bạn khi sử dụng "
              "ứng dụng KeoGo.",
        ),
        LegalSection(
          heading: "1. Thông tin chúng tôi thu thập",
          body: "• Thông tin tài khoản: tên hiển thị, email, số điện thoại "
              "(nếu bạn cung cấp khi đăng ký/đăng nhập).\n"
              "• Vị trí thiết bị: ứng dụng có thể yêu cầu quyền truy cập "
              "vị trí GPS để phục vụ các tính năng liên quan đến vị trí.\n"
              "• Thông tin thiết bị: mã định danh đẩy thông báo (để gửi "
              "thông báo đẩy), loại thiết bị, hệ điều hành.\n"
              "• Nội dung do bạn tạo: các kèo/lời mời, tin nhắn, hình ảnh "
              "bạn đăng tải trong ứng dụng.",
        ),
        LegalSection(
          heading: "2. Mục đích sử dụng thông tin",
          body: "Chúng tôi sử dụng thông tin thu thập được để:\n"
              "• Cung cấp và duy trì hoạt động của ứng dụng.\n"
              "• Xác thực tài khoản và bảo mật đăng nhập.\n"
              "• Gửi thông báo đẩy liên quan đến hoạt động của bạn.\n"
              "• Cải thiện trải nghiệm người dùng và khắc phục lỗi.\n"
              "• Tuân thủ nghĩa vụ pháp lý khi cần thiết.",
        ),
        LegalSection(
          heading: "3. Chia sẻ thông tin với bên thứ ba",
          body: "Chúng tôi không bán thông tin cá nhân của bạn cho bên thứ "
              "ba. Thông tin có thể được chia sẻ với các nhà cung cấp dịch "
              "vụ hỗ trợ vận hành ứng dụng (ví dụ: dịch vụ lưu trữ máy chủ, "
              "dịch vụ gửi thông báo đẩy), và chỉ trong phạm vi cần thiết "
              "để cung cấp dịch vụ.",
        ),
        LegalSection(
          heading: "4. Bảo mật dữ liệu",
          body: "Chúng tôi áp dụng các biện pháp kỹ thuật hợp lý (mã hoá "
              "kết nối, xác thực bằng token) để bảo vệ thông tin của bạn. "
              "Tuy nhiên, không có phương thức truyền tải hoặc lưu trữ "
              "điện tử nào an toàn tuyệt đối 100%.",
        ),
        LegalSection(
          heading: "5. Quyền của bạn",
          body: "Bạn có quyền truy cập, chỉnh sửa thông tin cá nhân của "
              "mình trong phần hồ sơ tài khoản. Bạn cũng có thể yêu cầu "
              "xoá tài khoản và toàn bộ dữ liệu liên quan ngay trong ứng "
              "dụng (mục Cài đặt tài khoản → Xoá tài khoản).",
        ),
        LegalSection(
          heading: "6. Quyền riêng tư của trẻ em",
          body: "Ứng dụng không hướng đến đối tượng trẻ em dưới 13 tuổi và "
              "chúng tôi không cố ý thu thập thông tin cá nhân từ trẻ em "
              "dưới độ tuổi này.",
        ),
        LegalSection(
          heading: "7. Thay đổi chính sách",
          body: "Chúng tôi có thể cập nhật chính sách bảo mật này theo "
              "thời gian. Mọi thay đổi quan trọng sẽ được thông báo trong "
              "ứng dụng.",
        ),
        LegalSection(
          heading: "8. Liên hệ",
          body: "Nếu có bất kỳ câu hỏi nào về chính sách bảo mật này, vui "
              "lòng liên hệ chúng tôi qua: xuanhung1606@gmail.com.",
        ),
      ],
    );
  }
}