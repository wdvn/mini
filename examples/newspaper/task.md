# 🚀 Nhiệm vụ: Tổng hợp Trí tuệ Công nghệ Đột phá (Daily Digest)

Hôm nay, bạn sẽ đóng vai trò là một Chuyên gia Phân tích Cấp cao để thực hiện quy trình tổng hợp tin tức từ Hacker News, chuyển hóa dữ liệu thô thành một bản báo cáo chiến lược.

## 📋 Quy trình Thực hiện

### Bước 1: Thu thập Dữ liệu Đa tầng (Hacker News API)
Sử dụng `bash` hoặc `python` , `web_search` để thực hiện một script duy nhất thu thập:
- Top 1 stories hiện tại trên trang chủ.
- Chi tiết từng story: Tiêu đề, URL, Điểm số, Người đăng.
- **Quan trọng**: Lấy top 5 bình luận (theo độ phổ biến) của 5 bài viết có thảo luận sôi nổi nhất để phân tích góc nhìn chuyên gia.

### Bước 2: Phân tích & Trích xuất "Tín hiệu" (Signal extraction)
Đừng chỉ liệt kê. Hãy phân tích:
- **Chủ đề nóng**: Có công nghệ nào đang chiếm sóng không? (VD: Một framework mới, một lỗ hổng bảo mật nghiêm trọng, hoặc một xu hướng mã nguồn mở).
- **Sentiment**: Cộng đồng đang ủng hộ hay hoài nghi? Có những giải pháp thay thế nào được nhắc đến trong bình luận?
- **Phân loại**: Gắn nhãn cho các tin tức (Software Engineering, AI/ML, Security, DevOps, Hardware, v.v.).

### Bước 3: Biên soạn Báo cáo "Premium Digest"
Bản báo cáo Markdown của bạn phải đạt tiêu chuẩn chuyên nghiệp cao nhất:

1.  **Header**: `Daily Tech Intelligence Report | [Date]` kèm 1 câu nhận định tổng quan về "nhịp đập" công nghệ hôm nay.
2.  **Executive Brief**: 3 điểm nhấn quan trọng nhất mà một kỹ sư/lãnh đạo công nghệ không thể bỏ qua.
3.  **The Trending Matrix**: Bảng tổng hợp nhanh (Top 10-15 stories).
4.  **Deep Dive Analysis**: Phân tích sâu 5 bài viết xuất sắc nhất. Mỗi mục bao gồm:
    - *The Core*: Tóm tắt giá trị kỹ thuật cốt lõi.
    - *The Discussion*: Điểm nhấn từ thảo luận cộng đồng (Experts' perspective).
    - *Why it matters*: Tại sao tin này quan trọng?
5.  **Hidden Gems**: Đề xuất 1-2 bài viết dù ít điểm nhưng có nội dung kỹ thuật cực kỳ chất lượng.

### Bước 4: Lưu trữ & Hoàn tất (MCP Tool)
Khi báo cáo đã đạt độ hoàn thiện cao nhất:
- Gọi công cụ: `wdvn_api__send_report`.
- Tham số:
    - `filename`: `newspaper_YYYY-MM-DD.md` (theo ngày hiện tại).
    - `content`: Toàn bộ nội dung Markdown đã biên soạn.

## 🏁 Yêu cầu Kết quả
Sau khi gửi báo cáo thành công, hãy tóm tắt lại cho người dùng theo phong cách chuyên nghiệp: "Báo cáo ngày [Date] đã được lưu. Điểm nhấn hôm nay là [X], trong khi cộng đồng đang tập trung thảo luận về [Y]."