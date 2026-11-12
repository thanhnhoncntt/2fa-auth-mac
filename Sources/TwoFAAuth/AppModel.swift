// UI state for the window. Secrets stay in the Keychain and in memory: never log them, and never show a key
// again once its account is saved.
import AppKit
import LocalAuthentication
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
    /// Optional lock (off by default): Touch ID or the Mac password before the codes show.
    @Published private(set) var lockEnabled = UserDefaults.standard.bool(forKey: AppModel.lockKey)
    @Published private(set) var isLocked = UserDefaults.standard.bool(forKey: AppModel.lockKey)
    private var autoLock = AutoLock(after: 5 * 60)
    private var unlocking = false
    private static let lockKey = "lockWithTouchID"
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
        (error as? OtpError)?.message ?? L("Something went wrong, try again")
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
        cameBack()
        openCount += 1
    }

    // MARK: optional lock

    /// The user switched away from the app; it locks if they stay away 5 minutes.
    func wentAway() { autoLock.left(at: Date()) }

    func cameBack() {
        if lockEnabled && autoLock.isExpired(at: Date()) { isLocked = true }
        autoLock.returned()
    }

    /// Screen locked or Mac going to sleep.
    func lockNow() {
        if lockEnabled { isLocked = true }
    }

    func unlock() {
        guard isLocked, !unlocking else { return }
        unlocking = true
        Task {
            let ok = await Self.authenticate(L("unlock and show your 2FA codes"))
            unlocking = false
            if ok { isLocked = false }
        }
    }

    func setLockEnabled(_ on: Bool) {
        guard on else {
            lockEnabled = false
            isLocked = false
            UserDefaults.standard.set(false, forKey: Self.lockKey)
            return
        }
        Task {
            // Check it works on this Mac before relying on it.
            guard await Self.authenticate(L("turn on the Touch ID lock")) else { return }
            lockEnabled = true
            UserDefaults.standard.set(true, forKey: Self.lockKey)
            showToast(L("Lock is on. The app locks after 5 minutes away, when the screen locks or when the Mac sleeps."), seconds: 5)
        }
    }

    /// Touch ID, or the Mac password when there is no Touch ID or it fails.
    private static func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
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
                showToast(L("Added %@", account.label))
            case .edit(let id):
                try book.update(id, issuer: form.issuer, name: form.name, group: form.group)
                showToast(L("Saved"))
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
            showToast(L("Deleted %@", account.label))
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
                showToast(L("Screen Recording permission needed: turn on 2FA Auth in System Settings → Privacy & Security → Screen Recording, then reopen the app."),
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
                showToast(L("No QR code in the selected area. Try a slightly larger box."), error: true, seconds: 5)
                return
            }
            useQr(text)
        }
    }

    private func useQr(_ text: String) {
        do {
            let draft = try Otpauth.parse(text)
            if let twin = accounts.first(where: { $0.secret == draft.secret }) {
                showToast(L("This account is already in the list: %@", twin.label), error: true, seconds: 5)
                return
            }
            // Only the account name is shown; the service name from the QR is kept to tell same-email accounts apart.
            form = FormState(issuer: draft.issuer, name: draft.name.isEmpty ? draft.issuer : draft.name, fromQr: draft)
            screen = .form
        } catch {
            showToast(Self.message(error), error: true, seconds: 5)
        }
    }

    private static func summary(_ result: ImportResult) -> String {
        let skipped = result.skipped > 0 ? L(", skipped %ld (already there or invalid)", result.skipped) : ""
        return L("Restored %ld accounts", result.added) + skipped
    }

    // MARK: backup and restore

    func startBackup() {
        guard !accounts.isEmpty else {
            showToast(L("No accounts to back up yet"), error: true)
            return
        }
        backup = BackupState()
        screen = .backup
    }

    /// Encrypts with the typed password, then asks where to save. The file only ever holds the sealed list.
    func saveBackup() {
        guard backup.password == backup.confirm else {
            backup.error = L("The two passwords do not match")
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
            panel.title = L("Save 2FA Auth Backup")
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = L("2FA Auth backup %@.json", Date().formatted(.iso8601.year().month().day()))
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                cancelBackup()
                showToast(L("Backed up %ld accounts to %@", snapshot.count, url.lastPathComponent), seconds: 5)
            } catch {
                backup.error = L("Could not write the file here")
            }
        }
    }

    /// Opens a backup file; the password screen comes next.
    func startRestore() {
        let panel = NSOpenPanel()
        panel.title = L("Choose a 2FA Auth Backup")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            showToast(L("Could not read this file"), error: true)
            return
        }
        guard Backup.isEncrypted(data) else {
            showToast(L("This is not a 2FA Auth backup file"), error: true, seconds: 5)
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
                showToast(Self.summary(imported), seconds: 5)
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

    /// The app's own language choice: nil follows macOS, otherwise "en" or "vi".
    var language: String? {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return (domain["AppleLanguages"] as? [String])?.first
    }

    /// Saves the choice and restarts the app, since macOS reads the language only at launch.
    func setLanguage(_ code: String?) {
        guard code != language else { return }
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        UserDefaults.standard.synchronize()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showToast(L("Could not change Open at Login"), error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
