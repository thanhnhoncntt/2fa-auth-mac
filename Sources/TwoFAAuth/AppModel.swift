// UI state for the window. Secrets stay in the Keychain and in memory: never log them, and never show a key
// again once its account is saved.
import AppKit
import ServiceManagement
import SwiftUI
import TwoFACore
import UniformTypeIdentifiers

struct FormState: Equatable {
    enum Mode: Equatable { case add, edit(UUID) }
    var mode: Mode = .add
    var issuer = ""
    var name = ""
    var group = ""
    var secret = ""
    /// Set when the form was filled from a scanned QR code; its key is used as is and not shown.
    var fromQr: AccountDraft?
    var error: String?
}

/// The password screen for making a backup or opening one.
struct BackupState: Equatable {
    var password = ""
    var confirm = ""
    var error: String?
    var busy = false
    /// The chosen backup file, for restore.
    var fileName = ""
}

struct Toast: Equatable {
    let message: String
    let isError: Bool
    var opensPermissionSettings = false
}

@MainActor
final class AppModel: ObservableObject {
    enum Screen { case list, form, backup, restore }

    @Published private(set) var accounts: [Account] = []
    @Published var query = ""
    /// The group chip that is selected; nil shows every account.
    @Published var groupFilter: String?
    /// The row that just copied its code, for the inline "Đã copy" mark.
    @Published private(set) var copiedId: UUID?
    @Published var screen: Screen = .list
    @Published var form = FormState()
    @Published var pendingDelete: Account?
    @Published var backup = BackupState()
    private var restoreFile: Data?
    @Published private(set) var toast: Toast?
    @Published private(set) var loadError: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Bumped every time the window comes up, so the search field can take focus again.
    @Published private(set) var openCount = 0

    var showWindow: () -> Void = {}
    var hideWindow: () -> Void = {}

    private var book: AccountBook?
    private var toastTask: Task<Void, Never>?
    private static let clipboardSeconds = 30.0

    init(storage: SecretStorage) {
        do {
            let book = try AccountBook(storage: storage)
            self.book = book
            accounts = book.accounts
        } catch {
            loadError = Self.message(error)
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? OtpError)?.message ?? "Có lỗi, thử lại"
    }

    var visible: [Account] {
        accounts.filter { $0.matches(query) && (groupFilter == nil || $0.group == groupFilter) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func count(in group: String?) -> Int {
        group.map { g in accounts.filter { $0.group == g }.count } ?? accounts.count
    }

    var groups: [String] {
        Array(Set(accounts.map(\.group).filter { !$0.isEmpty })).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func willShow() {
        if screen == .list { query = "" }
        openCount += 1
    }

    // MARK: toast

    func showToast(_ message: String, error: Bool = false, seconds: Double = 2.5, opensPermissionSettings: Bool = false) {
        toastTask?.cancel()
        toast = Toast(message: message, isError: error, opensPermissionSettings: opensPermissionSettings)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func hideToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: copy

    /// Copies the current code, marked concealed so clipboard managers skip it, and clears it after 30 seconds
    /// unless something else was copied meanwhile.
    func copy(_ account: Account) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(account.code(at: Date()), forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let stamp = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardSeconds) {
            if board.changeCount == stamp { board.clearContents() }
        }
        copiedId = account.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.copiedId == account.id { self?.copiedId = nil }
        }
    }

    // MARK: form

    func startAdd() {
        form = FormState()
        screen = .form
    }

    func startEdit(_ account: Account) {
        form = FormState(mode: .edit(account.id), issuer: account.issuer, name: account.name, group: account.group)
        screen = .form
    }

    func cancelForm() {
        form = FormState()
        pendingDelete = nil
        screen = .list
    }

    func saveForm() {
        guard let book else { return }
        do {
            switch form.mode {
            case .add:
                var draft = form.fromQr ?? AccountDraft(secret: form.secret)
                draft.issuer = form.issuer
                draft.name = form.name
                draft.group = form.group
                let account = try book.add(draft)
                showToast("Đã thêm \(account.label)")
            case .edit(let id):
                try book.update(id, issuer: form.issuer, name: form.name, group: form.group)
                showToast("Đã lưu")
            }
            accounts = book.accounts
            cancelForm()
        } catch {
            form.error = Self.message(error)
        }
    }

    func confirmDelete() {
        guard let book, let account = pendingDelete else { return }
        do {
            try book.remove(account.id)
            accounts = book.accounts
            if let filter = groupFilter, !groups.contains(filter) { groupFilter = nil }
            cancelForm()
            showToast("Đã xóa \(account.label)")
        } catch {
            pendingDelete = nil
            showToast(Self.message(error), error: true)
        }
    }

    // MARK: QR

    func scanScreen() {
        Task { @MainActor in
            guard ScreenScanner.hasPermission else {
                ScreenScanner.requestPermission()
                screen = .list
                showWindow()
                showToast("Cần quyền Ghi màn hình: bật 2FA Auth trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Ghi màn hình, rồi mở lại app.",
                          error: true, seconds: 15, opensPermissionSettings: true)
                return
            }
            hideWindow()
            hideToast()
            try? await Task.sleep(nanoseconds: 150_000_000) // let the window get out of the picture
            let image = await ScreenScanner.captureRegion()
            showWindow()
            guard let image else { return } // Esc
            let texts = ScreenScanner.readQRCodes(in: image)
            guard let text = texts.first(where: Otpauth.isOtpauth) ?? texts.first else {
                showToast("Không thấy mã QR trong vùng đã chọn. Thử kéo khung rộng hơn một chút.", error: true, seconds: 5)
                return
            }
            useQr(text)
        }
    }

    private func useQr(_ text: String) {
        do {
            let draft = try Otpauth.parse(text)
            if let twin = accounts.first(where: { $0.secret == draft.secret }) {
                showToast("Tài khoản này đã có trong danh sách: \(twin.label)", error: true, seconds: 5)
                return
            }
            // Only the account name is shown; the service name from the QR is kept to tell same-email accounts apart.
            form = FormState(issuer: draft.issuer, name: draft.name.isEmpty ? draft.issuer : draft.name, fromQr: draft)
            screen = .form
        } catch {
            showToast(Self.message(error), error: true, seconds: 5)
        }
    }

    private static func summary(_ result: ImportResult, verb: String) -> String {
        let skipped = result.skipped > 0 ? ", bỏ qua \(result.skipped) (đã có hoặc bị lỗi)" : ""
        return "\(verb) \(result.added) tài khoản\(skipped)"
    }

    // MARK: backup and restore

    func startBackup() {
        guard !accounts.isEmpty else {
            showToast("Chưa có tài khoản nào để sao lưu", error: true)
            return
        }
        backup = BackupState()
        screen = .backup
    }

    /// Encrypts with the typed password, then asks where to save. The file only ever holds the sealed list.
    func saveBackup() {
        guard backup.password == backup.confirm else {
            backup.error = "Hai mật khẩu chưa giống nhau"
            return
        }
        let (snapshot, password) = (accounts, backup.password)
        backup.error = nil
        backup.busy = true
        Task {
            let result = await Task.detached { Result { try Backup.encrypt(snapshot, password: password) } }.value
            backup.busy = false
            let data: Data
            do { data = try result.get() } catch {
                backup.error = Self.message(error)
                return
            }
            let panel = NSSavePanel()
            panel.title = "Lưu file sao lưu 2FA Auth"
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "2FA Auth sao lưu \(Date().formatted(.iso8601.year().month().day())).json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                cancelBackup()
                showToast("Đã sao lưu \(snapshot.count) tài khoản vào \(url.lastPathComponent)", seconds: 5)
            } catch {
                backup.error = "Không ghi được file vào chỗ này"
            }
        }
    }

    /// Opens a backup file; the password screen comes next.
    func startRestore() {
        let panel = NSOpenPanel()
        panel.title = "Chọn file sao lưu 2FA Auth"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            showToast("Không đọc được file này", error: true)
            return
        }
        guard Backup.isEncrypted(data) else {
            showToast("File này không phải file sao lưu của 2FA Auth", error: true, seconds: 5)
            return
        }
        restoreFile = data
        backup = BackupState(fileName: url.lastPathComponent)
        screen = .restore
    }

    /// Merges the backup into the list: accounts already here (same key) are skipped, nothing is deleted.
    func finishRestore() {
        guard let book, let file = restoreFile else { return }
        let password = backup.password
        backup.error = nil
        backup.busy = true
        Task {
            let result = await Task.detached { Result { try Backup.decrypt(file, password: password) } }.value
            backup.busy = false
            do {
                let imported = try book.importDrafts(try result.get())
                accounts = book.accounts
                cancelBackup()
                showToast(Self.summary(imported, verb: "Đã khôi phục"), seconds: 5)
            } catch {
                backup.error = Self.message(error)
            }
        }
    }

    func cancelBackup() {
        backup = BackupState()
        restoreFile = nil
        screen = .list
    }

    // MARK: settings

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showToast("Không đổi được mục Mở khi đăng nhập", error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
