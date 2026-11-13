# 2FA Auth cho macOS

[English](README.md) · **Tiếng Việt**

Phiên bản **0.2** · macOS 14 trở lên.

App nhỏ có cửa sổ riêng và icon trên Dock, tạo mã 2FA như app Authenticator. Quét được mã QR ở **bất kỳ đâu
trên màn hình**: mọi profile Chrome, Safari, Telegram, ảnh trong Preview...

## Cài đặt

1. Tải **2FA-Auth-0.2.zip** ở trang [Releases](https://github.com/thanhnhoncntt/2fa-auth-mac/releases/latest). Chạy được trên Mac chip Apple và Mac Intel, macOS 14 trở lên.
2. Mở file zip (bấm đúp) rồi kéo **2FA Auth.app** vào thư mục **Applications** (Ứng dụng).
3. Mở app. App chưa được Apple công chứng (notarize, việc này cần tài khoản developer trả phí), nên lần đầu macOS báo
   không xác minh được "2FA Auth". Bấm **Xong**, rồi mở **Cài đặt hệ thống → Quyền riêng tư & Bảo mật**, kéo xuống dòng
   *"2FA Auth" đã bị chặn*, bấm **Vẫn mở** và xác nhận bằng mật khẩu hoặc Touch ID. Chỉ cần làm một lần.

   Hoặc trong Terminal: `xattr -dr com.apple.quarantine "/Applications/2FA Auth.app"`, rồi mở app như bình thường.
4. Lần đầu quét mã QR, cho phép **Ghi màn hình** (xem bên dưới).

**Cập nhật:** thoát app (⌘Q), thay app trong Applications bằng bản mới rồi mở lại. Tài khoản vẫn nằm trong Keychain;
macOS có thể hỏi một lần cho 2FA Auth dùng chúng: bấm **Luôn cho phép**.

**Gỡ cài đặt:** kéo app vào Thùng rác. Tài khoản vẫn nằm trong Keychain cho tới khi bạn xoá mục `local.twofa-auth`
trong Truy cập Chuỗi khoá (Keychain Access).

Có thể tự build từ mã nguồn (xem [Build](#build)).

## Dùng

| Việc | Cách |
|---|---|
| Mở cửa sổ | Bấm icon trên Dock, icon 🔐 trên thanh menu, hoặc **⌥⇧A** ở bất kỳ đâu (bấm lần nữa để ẩn). Đóng cửa sổ (⌘W) app vẫn chạy để giữ phím tắt; ⌘Q để thoát |
| Copy mã | Bấm vào dòng. Hoặc gõ vài chữ để tìm rồi **Enter** (copy dòng đầu). Mã tự xoá khỏi clipboard sau 30 giây |
| Quét QR | **⌥⇧Q**, hoặc nút **Quét QR**. Cửa sổ tạm ẩn, kéo khung quanh mã QR như ⌘⇧4. `Esc` để huỷ |
| Nhập khóa tay | Nút **Nhập khóa** |
| Lọc theo nhóm | Bấm chip nhóm dưới ô tìm |
| Sửa / xoá | Chuột phải vào dòng. Form chỉ có tên tài khoản và nhóm; tên dịch vụ đọc từ QR được giữ và hiện chữ nhỏ dưới mã |
| Tự mở khi bật máy | **⋯ → Mở khi đăng nhập** |
| Ngôn ngữ | **⋯ → Ngôn ngữ**: Theo hệ thống / English / Tiếng Việt (app tự mở lại) |
| Menu nhanh | Chuột phải vào icon trên thanh menu: phiên bản, mở app, quét QR, sao lưu, khôi phục, thoát |

Lần quét đầu tiên, macOS hỏi quyền **Ghi màn hình**: bật cho 2FA Auth trong Cài đặt hệ thống → Quyền riêng tư &
Bảo mật → Ghi màn hình, rồi mở lại app.

## Sao lưu và khôi phục

- **Sao lưu:** ⋯ → **Sao lưu…** (hoặc ⌘S), đặt mật khẩu (ít nhất 8 ký tự), chọn nơi lưu. File `.json` được mã hoá
  AES-256-GCM, khoá tạo từ mật khẩu bằng PBKDF2-SHA256 (600.000 vòng, salt ngẫu nhiên), nên có thể để trong iCloud Drive
  hay USB. **Quên mật khẩu là không mở được file**, kể cả bằng app.
- **Khôi phục:** ⋯ → **Khôi phục…** (hoặc ⌘O), chọn file, nhập mật khẩu. Tài khoản được gộp vào danh sách hiện có;
  tài khoản trùng khóa được bỏ qua, không xoá gì.

## Bảo mật

**Tuỳ chọn, mặc định tắt:** ⋯ → **Khoá bằng Touch ID**. Khi bật, phải quét vân tay (hoặc nhập mật khẩu Mac) mới
thấy mã; app tự khoá lại khi rời app quá 5 phút, khi khoá màn hình hoặc máy ngủ. Nên bật thêm **FileVault**
(Cài đặt hệ thống → Quyền riêng tư & Bảo mật) để cả ổ đĩa được mã hoá.

- Khóa nằm trong **Keychain** (login keychain, chỉ máy này), một mục của dịch vụ `local.twofa-auth`. Không đồng bộ, không gọi mạng.
- Ảnh chụp khi quét chỉ nằm trong thư mục tạm riêng của user và bị xoá ngay sau khi đọc mã.
- Mã copy được đánh dấu "concealed" để các app quản lý clipboard bỏ qua.

## Build

```sh
swift test                      # test: Base32, TOTP (RFC 4226/6238), otpauth, danh sách, sao lưu, bản dịch
./scripts/build-app.sh          # tạo build/2FA Auth.app
./scripts/build-app.sh --install  # cài vào ~/Applications, mở lại, xoá bản build
./scripts/build-app.sh --zip      # đóng gói dist/2FA-Auth-<phiên bản>.zip
./scripts/build-app.sh --release  # file zip để đăng Releases: chip Apple + Intel, ký ad-hoc
./scripts/build-app.sh && "build/2FA Auth.app/Contents/MacOS/TwoFAAuth" --demo  # thử giao diện với tài khoản giả, không đụng Keychain
```

Icon app: `swift scripts/make-icon.swift . && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.
Script ký bằng chứng chỉ Apple Development nếu có, nên quyền Keychain và Ghi màn hình được giữ qua các lần build.
`--release` luôn ký ad-hoc, vì tên chứng chỉ (thường là email Apple ID) sẽ nằm trong app.

| Đường dẫn | Vai trò |
|---|---|
| `Sources/TwoFACore/` | Logic thuần, có test: `OTP.swift`, `Otpauth.swift` (đọc link QR), `Account.swift`, `AccountBook.swift`, `Backup.swift` (file sao lưu mã hoá), `AutoLock.swift` (hẹn giờ tự khoá) |
| `Sources/TwoFAAuth/AppDelegate.swift` | Cửa sổ, icon thanh menu, menu chuẩn, phím tắt |
| `Sources/TwoFAAuth/AppModel.swift` | Trạng thái giao diện: copy, form, quét, sao lưu |
| `Sources/TwoFAAuth/Views.swift` | Giao diện SwiftUI |
| `Resources/vi.lproj/Localizable.strings` | Bản dịch tiếng Việt (chuỗi gốc tiếng Anh nằm trong code, dạng `L("…")`) |
| `Sources/TwoFAAuth/ScreenScanner.swift` | Chọn vùng bằng `screencapture -i`, đọc QR bằng Vision |
| `Sources/TwoFAAuth/KeychainStorage.swift` | Lưu danh sách vào Keychain |
| `Sources/TwoFAAuth/HotKeys.swift` | Phím tắt toàn hệ thống (Carbon, không cần quyền Trợ năng) |
