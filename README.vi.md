# 2FA Auth cho macOS

[English](README.md) · **Tiếng Việt**

App Mac nhỏ tạo mã 2FA, quét được mã QR ở **bất kỳ đâu trên màn hình**: mọi profile Chrome, Safari, app chat, ảnh.
Khóa nằm trong Keychain của máy, không lên mạng.

<p>
  <img src="docs/screenshots/list-vi.png" width="260" alt="Danh sách tài khoản">
  <img src="docs/screenshots/add-vi.png" width="260" alt="Thêm tài khoản">
</p>

## Cài đặt

1. Tải **2FA-Auth-0.3.zip** ở [Releases](https://github.com/thanhnhoncntt/2fa-auth-mac/releases/latest)
   (macOS 14+, chip Apple và Intel), kéo **2FA Auth.app** vào **Applications**.
2. App chưa được Apple công chứng nên lần đầu bị chặn: bấm **Xong**, rồi
   **Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Vẫn mở**. Chỉ một lần.
   Hoặc: `xattr -dr com.apple.quarantine "/Applications/2FA Auth.app"`
3. Lần đầu quét QR, cho phép **Ghi màn hình**.

## Dùng

- **⌥⇧A** hiện hoặc ẩn cửa sổ; **⌥⇧Q** quét mã QR (kéo khung quanh mã, `Esc` để huỷ).
- Bấm vào dòng để copy mã, hoặc gõ để tìm rồi **Enter**. Clipboard tự xoá sau 30 giây.
- **Profile** (⚙ Thiết lập → Profile): mỗi profile một danh sách tài khoản riêng, như profile Chrome. Đổi bằng menu
  ở trên cùng hoặc ⌘1, ⌘2…; menu chỉ hiện khi có từ 2 profile.
- Chuột phải vào dòng để sửa hoặc xoá; chuột phải vào icon trên thanh menu để mở menu nhanh.
- **Chuyển từ app khác?** ⚙ Thiết lập → **Nhập từ file…** đọc file xuất từ extension Authenticator trên Chrome,
  Aegis, 2FAS, andOTP, Bitwarden, Ente Auth và danh sách otpauth://. Với Google Authenticator, quét mã QR xuất tài khoản.
- ⚙ Thiết lập còn có sao lưu có mật khẩu của riêng 2FA Auth (tất cả hoặc vài profile; khi khôi phục chọn profile nào
  lấy lại và vào đâu, không xoá gì), ngôn ngữ, khoá Touch ID và mở khi đăng nhập.

## Build

```sh
swift test
./scripts/build-app.sh --install   # build và cài vào ~/Applications
./scripts/build-app.sh --release   # dist/2FA-Auth-<phiên bản>.zip để đăng Releases
```

## Giấy phép

[MIT](LICENSE)
