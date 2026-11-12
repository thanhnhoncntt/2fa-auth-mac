import SwiftUI
import TwoFACore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            switch model.screen {
            case .list: ListScreen()
            case .form: FormScreen()
            case .backup: BackupScreen(restoring: false)
            case .restore: BackupScreen(restoring: true)
            }
            if let toast = model.toast {
                ToastView(toast: toast).padding(12)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }
}

// MARK: list

private struct ListScreen: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Toolbar()
                SearchField(focused: $searchFocused)
                if !model.groups.isEmpty { GroupChips() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
            Divider()

            if let error = model.loadError {
                Message(icon: "exclamationmark.triangle", title: error,
                        detail: "Mở lại app. Nếu macOS hỏi quyền dùng Keychain, chọn Luôn cho phép.")
            } else if model.accounts.isEmpty {
                EmptyState()
            } else if model.visible.isEmpty {
                Message(icon: "magnifyingglass", title: "Không có tài khoản nào khớp", detail: nil)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.visible) { account in
                                AccountRow(account: account, now: context.date)
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }
            }
            if let account = model.pendingDelete { DeleteBar(account: account) }
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.openCount) { searchFocused = true }
    }
}

private struct Toolbar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.scanScreen() } label: {
                Label("Quét QR", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .help("Kéo chọn vùng có mã QR ở bất kỳ đâu trên màn hình (⌥⇧Q)")

            Button { model.startAdd() } label: {
                Label("Nhập khóa", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .help("Nhập khóa thiết lập trang web đưa ra (⌘N)")

            Spacer()

            Menu {
                Button("Sao lưu…") { model.startBackup() }
                Button("Khôi phục…") { model.startRestore() }
                Divider()
                Toggle("Mở khi đăng nhập", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Thêm")
        }
        .controlSize(.large)
    }
}

private struct SearchField: View {
    @EnvironmentObject private var model: AppModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Tìm tài khoản · Enter để copy", text: $model.query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit { if let first = model.visible.first { model.copy(first) } }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}

private struct GroupChips: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Tất cả", group: nil)
                ForEach(model.groups, id: \.self) { chip($0, group: $0) }
            }
        }
    }

    private func chip(_ title: String, group: String?) -> some View {
        let selected = model.groupFilter == group
        return Button { model.groupFilter = group } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(model.count(in: group))")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08)))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private struct AccountRow: View {
    @EnvironmentObject private var model: AppModel
    let account: Account
    let now: Date
    @State private var hovering = false

    var body: some View {
        let remaining = account.secondsRemaining(at: now)
        let urgent = remaining <= 5
        let copied = model.copiedId == account.id
        Button { model.copy(account) } label: {
            HStack(spacing: 12) {
                // The service's initial tells same-email accounts apart better than the email's.
                Avatar(text: account.issuer.isEmpty ? account.title : account.issuer)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if copied {
                        Label("Đã copy", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text(OTP.format(account.code(at: now)))
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .foregroundStyle(urgent ? Color.red : Color.primary)
                    }
                    if !account.detail.isEmpty {
                        Text(account.detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(copied ? Color.green : (hovering ? Color.accentColor : Color.secondary))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                    CountdownRing(fraction: Double(remaining) / Double(account.period), seconds: remaining, urgent: urgent)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
            .animation(.easeOut(duration: 0.15), value: copied)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Bấm để copy mã")
        .contextMenu {
            Button("Copy mã") { model.copy(account) }
            Button("Sửa…") { model.startEdit(account) }
            Divider()
            Button("Xóa…", role: .destructive) { model.pendingDelete = account }
        }
    }
}

private struct Avatar: View {
    let text: String

    var body: some View {
        let hue = Double(text.unicodeScalars.reduce(7) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        Circle()
            .fill(Color(hue: hue, saturation: 0.45, brightness: 0.85))
            .frame(width: 36, height: 36)
            .overlay(Text(text.prefix(1).uppercased()).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct CountdownRing: View {
    let fraction: Double
    let seconds: Int
    let urgent: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(urgent ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(seconds)").font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(urgent ? Color.red : Color.secondary)
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Chưa có tài khoản").font(.headline)
            Text("Bấm Quét QR rồi kéo khung quanh mã QR trên màn hình, hoặc Nhập khóa.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Khôi phục từ file sao lưu…") { model.startRestore() }.buttonStyle(.link)
            Spacer()
        }
        .padding(24)
    }
}

private struct Message: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(title).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

private struct DeleteBar: View {
    @EnvironmentObject private var model: AppModel
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Xóa \(account.title)? Mã của tài khoản này sẽ mất hẳn.").font(.callout)
            HStack {
                Spacer()
                Button("Hủy") { model.pendingDelete = nil }
                Button("Xóa", role: .destructive) { model.confirmDelete() }.buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
    }
}

private struct ToastView: View {
    @EnvironmentObject private var model: AppModel
    let toast: Toast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(toast.message).font(.callout).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            if toast.opensPermissionSettings {
                Button("Mở Cài đặt") { ScreenScanner.openPermissionSettings() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(toast.isError ? Color.red.opacity(0.95) : Color.black.opacity(0.85)))
        .onTapGesture { model.hideToast() }
    }
}

// MARK: form

private struct FormScreen: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    private var isEdit: Bool { if case .edit = model.form.mode { true } else { false } }
    private var needsKey: Bool { !isEdit && model.form.fromQr == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { model.cancelForm() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(isEdit ? "Sửa tài khoản" : "Thêm tài khoản").font(.headline)
                Spacer()
            }
            if model.form.fromQr != nil {
                Label("Đã đọc mã QR. Kiểm tra lại tên rồi bấm Lưu.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            field("Tài khoản", prompt: "VD: alex@gmail.com", text: $model.form.name).focused($focused)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nhóm (không bắt buộc)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("", text: $model.form.group, prompt: Text("VD: Công việc")).textFieldStyle(.roundedBorder)
                    if !model.groups.isEmpty {
                        Menu {
                            ForEach(model.groups, id: \.self) { group in Button(group) { model.form.group = group } }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Chọn nhóm có sẵn")
                    }
                }
            }
            if needsKey {
                field("Khóa thiết lập", prompt: "Chuỗi chữ và số trang web đưa ra", text: $model.form.secret)
                    .font(.system(.body, design: .monospaced))
            }
            if let error = model.form.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Spacer()
            if let account = model.pendingDelete {
                DeleteBar(account: account).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if case .edit(let id) = model.form.mode {
                    Button("Xóa tài khoản", role: .destructive) {
                        model.pendingDelete = model.accounts.first { $0.id == id }
                    }
                    .buttonStyle(.link).foregroundStyle(.red)
                }
                Spacer()
                Button("Hủy") { model.cancelForm() }.keyboardShortcut(.cancelAction)
                Button("Lưu") { model.saveForm() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(16)
        .onAppear { focused = true }
    }

    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: backup and restore

private struct BackupScreen: View {
    @EnvironmentObject private var model: AppModel
    let restoring: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { model.cancelBackup() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(restoring ? "Khôi phục" : "Sao lưu").font(.headline)
                Spacer()
            }
            if restoring {
                Label(model.backup.fileName, systemImage: "doc.badge.clock").font(.callout).lineLimit(1)
                Text("Nhập mật khẩu đã đặt lúc sao lưu. Tài khoản trong file được gộp vào danh sách; tài khoản đã có thì bỏ qua, không xoá gì.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sao lưu \(model.accounts.count) tài khoản ra một file được mã hoá bằng mật khẩu này. Quên mật khẩu là không mở được file, kể cả bằng app.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            secure("Mật khẩu", prompt: "Ít nhất \(Backup.minPasswordLength) ký tự", text: $model.backup.password).focused($focused)
            if !restoring {
                secure("Nhập lại mật khẩu", prompt: "", text: $model.backup.confirm)
            }
            if let error = model.backup.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                if model.backup.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Hủy") { model.cancelBackup() }.keyboardShortcut(.cancelAction)
                Button(restoring ? "Khôi phục" : "Chọn nơi lưu…") {
                    if restoring { model.finishRestore() } else { model.saveBackup() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.backup.busy || model.backup.password.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(16)
        .onAppear { focused = true }
    }

    private func secure(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
        }
    }
}
