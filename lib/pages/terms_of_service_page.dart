import 'package:flutter/material.dart';
import 'legal_page.dart';

/// ⚠️ Nội dung mẫu — hãy đọc kỹ và chỉnh sửa lại cho khớp với thực tế
/// hoạt động của app (hệ thống kèo/lời mời, sản phẩm, thanh toán nếu có)
/// trước khi phát hành chính thức.
class TermsOfServicePage extends StatelessWidget {
  const TermsOfServicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const LegalPage(
      title: "Điều khoản sử dụng",
      sections: [
        LegalSection(
          body: "Cập nhật lần cuối: 17/07/2026\n\n"
              "Khi sử dụng ứng dụng KeoGo, bạn đồng ý tuân thủ các "
              "điều khoản sử dụng dưới đây.",
        ),
        LegalSection(
          heading: "1. Chấp nhận điều khoản",
          body: "Bằng việc tạo tài khoản hoặc sử dụng ứng dụng, bạn xác "
              "nhận đã đọc, hiểu và đồng ý bị ràng buộc bởi các điều khoản "
              "này cũng như Chính sách bảo mật của chúng tôi.",
        ),
        LegalSection(
          heading: "2. Tài khoản người dùng",
          body: "• Bạn chịu trách nhiệm bảo mật thông tin đăng nhập của "
              "mình.\n"
              "• Bạn phải cung cấp thông tin chính xác khi đăng ký.\n"
              "• Chúng tôi có quyền tạm khoá hoặc xoá tài khoản vi phạm "
              "điều khoản sử dụng.",
        ),
        LegalSection(
          heading: "3. Quy tắc ứng xử",
          body: "Khi tạo hoặc tham gia kèo/lời mời trong ứng dụng, bạn "
              "đồng ý:\n"
              "• Không đăng nội dung vi phạm pháp luật, phản cảm, hoặc "
              "gây hại cho người khác.\n"
              "• Không mạo danh người khác hoặc cung cấp thông tin sai "
              "lệch.\n"
              "• Tôn trọng các thành viên khác trong quá trình tương tác.",
        ),
        LegalSection(
          heading: "4. Nội dung do người dùng tạo",
          body: "Bạn giữ quyền sở hữu đối với nội dung mình đăng tải, "
              "nhưng cấp cho chúng tôi quyền hiển thị nội dung đó trong "
              "phạm vi hoạt động của ứng dụng. Chúng tôi có quyền gỡ bỏ "
              "nội dung vi phạm điều khoản mà không cần báo trước.",
        ),
        LegalSection(
          heading: "5. Giới hạn trách nhiệm",
          body: "Ứng dụng được cung cấp trên cơ sở \"nguyên trạng\". "
              "Chúng tôi không chịu trách nhiệm đối với các thiệt hại phát "
              "sinh từ việc sử dụng ứng dụng, bao gồm nhưng không giới "
              "hạn ở các giao dịch, thoả thuận giữa người dùng với nhau "
              "thông qua tính năng kèo/lời mời.",
        ),
        LegalSection(
          heading: "6. Chấm dứt sử dụng",
          body: "Bạn có thể ngừng sử dụng ứng dụng và xoá tài khoản bất "
              "kỳ lúc nào trong mục Cài đặt. Chúng tôi có quyền chấm dứt "
              "quyền truy cập của bạn nếu phát hiện vi phạm nghiêm trọng "
              "các điều khoản này.",
        ),
        LegalSection(
          heading: "7. Thay đổi điều khoản",
          body: "Chúng tôi có thể cập nhật điều khoản sử dụng theo thời "
              "gian. Việc tiếp tục sử dụng ứng dụng sau khi có thay đổi "
              "đồng nghĩa với việc bạn chấp nhận các điều khoản mới.",
        ),
        LegalSection(
          heading: "8. Liên hệ",
          body: "Nếu có bất kỳ câu hỏi nào về điều khoản sử dụng này, vui "
              "lòng liên hệ chúng tôi qua: xuanhung1606@gmail.com.",
        ),
      ],
    );
  }
}