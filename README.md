# Loli Pixel H5 → Render + APK/IPA bằng GitHub Actions

## Cách hoạt động
- Render chạy 2 service: `loli-mysql` (MySQL 5.7 + disk) và `loli-game` (Docker: nginx + Redis + 3 JVM + client H5).
- Render chỉ mở **1 cổng public**, nên nginx gom lại: `/` → game web, `/api/` → backstage (:9001), `/game` → WebSocket của game server (:10001, client dùng `wss`).
- Trang admin (cổng 82 trong bản gốc) **không** được mở ra internet.
- APK/IPA = app Capacitor chứa sẵn client H5, gọi API/WebSocket tới host Render của bạn.

## Bước 1 — Tạo repo GitHub **PRIVATE** và copy file game
Copy nội dung `data.zip` vào `game-data/` (xem `game-data/PUT_GAME_FILES_HERE.txt`), rồi push bằng git hoặc GitHub Desktop
(upload bằng web bị giới hạn file/dung lượng; tổng ~460 MB, không file nào >100 MB):

    git init && git add . && git commit -m "init"
    git branch -M main
    git remote add origin https://github.com/<ban>/<repo>.git
    git push -u origin main

## Bước 2 — Deploy lên Render
Render Dashboard → **New → Blueprint** → chọn repo → **Apply**. Lần build đầu mất vài phút.
Xem Logs của `loli-game`: dòng có tiền tố `[backstage]`, `[cross]`, `[game]`; xong khi thấy `READY`.
Mở `https://<ten-service>.onrender.com/` để chơi bản web. Host chính là phần tên miền đó (không có `https://`).
Lần chạy đầu tự tạo database và import SQL (ghi dấu bằng database `x1_init_done`).

## Bước 3 — APK (Android)
GitHub → **Actions → Build Android APK → Run workflow** → nhập host Render.
Tải `lolipixel-android.apk` ở mục **Releases** (tag `android-N`), cài và bật "cài ứng dụng không rõ nguồn".

## Bước 4 — IPA (iOS)
GitHub → **Actions → Build iOS IPA (unsigned) → Run workflow** → nhập host Render.
File `.ipa` ở Releases **chưa ký**: dùng Sideloadly / AltStore (Apple ID miễn phí, hết hạn sau 7 ngày) hoặc TrollStore để ký và cài.
Cách nhanh hơn không cần IPA: mở link web bằng Safari → Chia sẻ → **Thêm vào Màn hình chính**.

## Chi phí và giới hạn
- Render: web `standard` (2 GB) $25 + MySQL `starter` $7 + disk 2 GB ≈ 32 USD/tháng. Gói Free **không** chạy nổi (512 MB RAM, không gắn disk, ngủ sau 15 phút; private service không có gói Free).
- Hết RAM (service restart liên tục) → đổi `plan: pro` trong `render.yaml` và tăng `XMX_*`. Có thể tắt cross-server bằng `ENABLE_CROSS=0` (chưa chắc game chạy bình thường khi tắt).
- GitHub repo private: 2.000 phút miễn phí/tháng, macOS tính x10 → mỗi lần build iOS tốn khoảng 100–150 phút quota.
- Redis không lưu dữ liệu; MySQL lưu trên disk của Render. Giờ reset ngày theo UTC (7h sáng Việt Nam).

## Xử lý lỗi
- `/api` trả 502: backstage chưa lên xong, xem log `[backstage]`.
- Kẹt ở bước kết nối server: xem log `[game]`; kiểm tra bảng `x1_backstage.game_server` có `socket_type = 'wss'`.
- Muốn import lại dữ liệu từ đầu: xóa database `x1_init_done` (và redeploy). Cảnh báo: bản dump sẽ ghi đè dữ liệu người chơi.
- Đổi host (tên miền riêng): đặt biến `PUBLIC_HOST` cho `loli-game` và build lại APK/IPA với host mới.

## Lưu ý
- Repo phải **private**: đây không phải source của bạn (readme gốc chỉ cho phép nghiên cứu, không thương mại).
- Mật khẩu mặc định trong source (MySQL, Redis) được thay bằng giá trị ngẫu nhiên do Render sinh khi chạy.
- Bộ này chưa được chạy thử trên Render/Actions thật; script patch client/SQL/config đã chạy thử trên dữ liệu thật.
