// UI state for the window. Secrets stay in the Keychain and in memory: never log them, and never show a key
// again once its account is saved.
import AppKit
import LocalAuthentication
import ServiceManagement
import Observation
import SwiftUI
import TwoFACore
import UniformTypeIdentifiers

struct FormState: Equatable {
    enum Mode: Equatable { case add, edit(UUID) }
    var mode: Mode = .add
    var issuer = ""
    var name = ""
    var group = ""
    var profile = ""
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
    /// Back up: the profiles to include (all of them to start with).
    var profiles: Set<String> = []
    /// Restore: what the file holds once the password opened it; nil until then.
    var found: [AccountDraft]?
    /// Restore: the profiles of the file to bring back, and where to (nil keeps each account's own profile).
    var restoreProfiles: Set<String> = []
    var restoreInto: String?
}

struct Toast: Equatable {
    let message: String
    let isError: Bool
    var opensPermissionSettings = false
}

@MainActor
@Observable
final class AppModel {
    enum Flow: String, Identifiable { case backup, restore; var id: String { rawValue } }

    /// Every account of every profile; the list shows `profileAccounts`.
    private(set) var accounts: [Account] = []
    /// Named profiles; "" (the default profile) comes first in `allProfiles`.
    private(set) var profiles: [String] = []
    private(set) var currentProfile = UserDefaults.standard.string(forKey: AppModel.currentProfileKey) ?? ""
    private(set) var defaultProfileName = UserDefaults.standard.string(forKey: AppModel.defaultProfileKey) ?? ""
    /// Where Import from File puts the accounts; Settings sets it to the open profile.
    var importProfile = ""
    private static let currentProfileKey = "currentProfile"
    private static let defaultProfileKey = "defaultProfileName"
    var query = ""
    /// The group chip that is selected; nil shows every account.
    var groupFilter: String?
    /// The row that just copied its code, for the inline "Đã copy" mark.
    private(set) var copiedId: UUID?
    /// The Add / Edit Account sheet of the main window.
    var formOpen = false
    /// The Back Up or Restore sheet of the Settings window.
    var flow: Flow?
    var form = FormState()
    var pendingDelete: Account?
    var backup = BackupState()
    @ObservationIgnored private var restoreFile: Data?
    private(set) var toast: Toast?
    private(set) var loadError: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Optional lock (off by default): Touch ID or the Mac password before the codes show.
    private(set) var lockEnabled = UserDefaults.standard.bool(forKey: AppModel.lockKey)
    private(set) var isLocked = UserDefaults.standard.bool(forKey: AppModel.lockKey)
    @ObservationIgnored private var autoLock = AutoLock(after: 5 * 60)
    @ObservationIgnored private var unlocking = false
    private static let lockKey = "lockWithTouchID"
    /// Bumped every time the window comes up, so the search field can take focus again.
    private(set) var openCount = 0

    @ObservationIgnored var showWindow: () -> Void = {}
    @ObservationIgnored var hideWindow: () -> Void = {}
    @ObservationIgnored var openSettingsWindow: () -> Void = {}

    @ObservationIgnored private var book: AccountBook?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private static let clipboardSeconds = 30.0

    init(storage: SecretStorage) {
        do {
            let book = try AccountBook(storage: storage)
            self.book = book
            accounts = book.accounts
            profiles = book.profiles
            if !allProfiles.contains(currentProfile) { currentProfile = "" }
        } catch {
            loadError = Self.message(error)
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? OtpError)?.message ?? L("Something went wrong, try again")
    }

    var visible: [Account] {
        profileAccounts.filter { $0.matches(query) && (groupFilter == nil || $0.group == groupFilter) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func count(in group: String?) -> Int {
        group.map { g in profileAccounts.filter { $0.group == g }.count } ?? profileAccounts.count
    }

    var groups: [String] {
        Array(Set(profileAccounts.map(\.group).filter { !$0.isEmpty })).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func willShow() {
        if !formOpen { query = "" }
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
        form = FormState(profile: currentProfile)
        formOpen = true
    }

    func startEdit(_ account: Account) {
        form = FormState(mode: .edit(account.id), issuer: account.issuer, name: account.name, group: account.group,
                         profile: account.profile)
        formOpen = true
    }

    func cancelForm() {
        form = FormState()
        pendingDelete = nil
        formOpen = false
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
                draft.profile = form.profile
                let account = try book.add(draft)
                showToast(L("Added %@", account.label))
            case .edit(let id):
                let moved = accounts.first { $0.id == id }?.profile != form.profile
                try book.update(id, issuer: form.issuer, name: form.name, group: form.group, profile: form.profile)
                showToast(moved ? L("Moved to %@", title(of: form.profile)) : L("Saved"))
            }
            let added = form.mode == .add ? form.profile : nil
            refresh()
            cancelForm()
            if let added, added != currentProfile { switchProfile(added) }
        } catch {
            form.error = Self.message(error)
        }
    }

    func confirmDelete() {
        guard let book, let account = pendingDelete else { return }
        do {
            try book.remove(account.id)
            refresh()
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
                formOpen = false
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
        // Google Authenticator's export QR codes hold several accounts: add them all at once.
        if Migration.isGoogleExport(text) {
            do { importAccounts(try Migration.parse(Data(text.utf8)), fromFile: false) } catch {
                showToast(Self.message(error), error: true, seconds: 5)
            }
            return
        }
        do {
            let draft = try Otpauth.parse(text)
            if let twin = profileAccounts.first(where: { $0.secret == draft.secret }) {
                showToast(L("This account is already in the list: %@", twin.label), error: true, seconds: 5)
                return
            }
            // Only the account name is shown; the service name from the QR is kept to tell same-email accounts apart.
            form = FormState(issuer: draft.issuer, name: draft.name.isEmpty ? draft.issuer : draft.name,
                             profile: currentProfile, fromQr: draft)
            formOpen = true
        } catch {
            showToast(Self.message(error), error: true, seconds: 5)
        }
    }

    private static func summary(_ result: ImportResult) -> String {
        let skipped = result.skipped > 0 ? L(", skipped %ld (already there or invalid)", result.skipped) : ""
        return L("Restored %ld accounts", result.added) + skipped
    }

    // MARK: profiles

    var allProfiles: [String] { [""] + profiles }
    /// The profile switcher only shows once there is a second profile, so a single list stays as simple as before.
    var hasProfiles: Bool { !profiles.isEmpty }
    var profileAccounts: [Account] { accounts.filter { $0.profile == currentProfile } }

    func title(of profile: String) -> String {
        profile.isEmpty ? (defaultProfileName.isEmpty ? L("Main") : defaultProfileName) : profile
    }

    func accountCount(of profile: String) -> Int { accounts.filter { $0.profile == profile }.count }

    private func refresh() {
        guard let book else { return }
        accounts = book.accounts
        profiles = book.profiles
        if !allProfiles.contains(currentProfile) { switchProfile("") }
    }

    func switchProfile(_ profile: String) {
        guard allProfiles.contains(profile) else { return }
        currentProfile = profile
        UserDefaults.standard.set(profile, forKey: Self.currentProfileKey)
        groupFilter = nil
        query = ""
        pendingDelete = nil
        if formOpen { cancelForm() }
    }

    /// Creates a profile and switches to it. Returns false (with a message) when the name is taken or empty.
    @discardableResult
    func addProfile(_ name: String) -> Bool {
        guard let book else { return false }
        do {
            let clean = try book.addProfile(name)
            refresh()
            switchProfile(clean)
            showToast(L("Created the profile %@", clean))
            return true
        } catch {
            showToast(Self.message(error), error: true)
            return false
        }
    }

    @discardableResult
    func renameProfile(_ old: String, to new: String) -> Bool {
        guard let book else { return false }
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if old.isEmpty {
            // The default profile has no stored name; an empty one goes back to "Main".
            if profiles.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
                showToast(L("There is already a profile named %@", clean), error: true)
                return false
            }
            defaultProfileName = clean
            UserDefaults.standard.set(clean, forKey: Self.defaultProfileKey)
            return true
        }
        do {
            try book.renameProfile(old, to: clean)
            let wasCurrent = currentProfile == old
            accounts = book.accounts
            profiles = book.profiles
            if wasCurrent { switchProfile(clean) }
            return true
        } catch {
            showToast(Self.message(error), error: true)
            return false
        }
    }

    func deleteProfile(_ profile: String) {
        guard let book, !profile.isEmpty else { return }
        do {
            try book.removeProfile(profile)
            refresh()
            showToast(L("Deleted the profile %@", profile))
        } catch {
            showToast(Self.message(error), error: true, seconds: 5)
        }
    }

    /// `--demo --demo-screen=…`: opens a screen directly, to look at it without clicking through.
    func showDemoScreen(_ name: String) {
        switch name {
        case "settings": openSettings()
        case "form": startAdd()
        case "backup": openSettings(); startBackup()
        case "restore":
            backup = BackupState(fileName: "2FA Auth backup 2026-11-13.json", found: accounts.map {
                AccountDraft(issuer: $0.issuer, name: $0.name, group: $0.group, secret: $0.secret, profile: $0.profile)
            })
            backup.restoreProfiles = Set(allProfiles)
            flow = .restore; openSettingsWindow()
        default: break
        }
    }

    // MARK: settings screen

    func openSettings() {
        pendingDelete = nil
        importProfile = currentProfile
        openSettingsWindow()
    }



    // MARK: import from other apps

    /// Opens an export file of another app (the Authenticator Chrome extension, Aegis, 2FAS…). Picking a
    /// 2FA Auth backup by mistake goes to the password screen of Restore instead.
    func startImport() {
        let panel = NSOpenPanel()
        panel.title = L("Choose the File Exported from the Other App")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 10_000_000, let data = try? Data(contentsOf: url) else {
            showToast(L("Could not read this file"), error: true)
            return
        }
        if Backup.isEncrypted(data) {
            restoreFile = data
            backup = BackupState(fileName: url.lastPathComponent)
            flow = .restore; openSettingsWindow()
            return
        }
        do { importAccounts(try Migration.parse(data), fromFile: true, into: importProfile) } catch {
            showToast(Self.message(error), error: true, seconds: 6)
        }
    }

    /// Adds what was found to `profile` (the open one by default) and shows that profile.
    private func importAccounts(_ found: MigrationResult, fromFile: Bool, into target: String? = nil) {
        guard let book else { return }
        guard !found.drafts.isEmpty else {
            showToast(L("None of the %ld accounts can be used here: they are counter-based (HOTP), Steam or password-protected", found.unsupported),
                      error: true, seconds: 8)
            return
        }
        do {
            let profile = allProfiles.contains(target ?? "") ? (target ?? currentProfile) : currentProfile
            let result = try book.importDrafts(found.drafts.map { var d = $0; d.profile = profile; return d })
            refresh()
            switchProfile(profile)
            showWindow()
            var message = hasProfiles ? L("Imported %ld accounts into %@", result.added, title(of: profile))
                                      : L("Imported %ld accounts", result.added)
            if result.skipped > 0 { message += L(", skipped %ld (already there or invalid)", result.skipped) }
            if found.unsupported > 0 { message += L(", %ld not supported (counter-based, Steam or password-protected)", found.unsupported) }
            if fromFile { message += "\n" + L("Now delete the exported file: it holds your keys unprotected.") }
            showToast(message, seconds: 10)
        } catch {
            showToast(Self.message(error), error: true, seconds: 5)
        }
    }

    // MARK: backup and restore

    func startBackup() {
        guard !accounts.isEmpty else {
            showToast(L("No accounts to back up yet"), error: true)
            return
        }
        backup = BackupState(profiles: Set(allProfiles))
        flow = .backup
    }

    /// Encrypts with the typed password, then asks where to save. The file only ever holds the sealed list.
    func saveBackup() {
        guard backup.password == backup.confirm else {
            backup.error = L("The two passwords do not match")
            return
        }
        let chosen = backup.profiles
        let (snapshot, password) = (accounts.filter { chosen.contains($0.profile) }, backup.password)
        guard !snapshot.isEmpty else {
            backup.error = L("Choose at least one profile with accounts")
            return
        }
        // "2FA Auth backup Acme Corp 2026-11-13.json" when only one profile of several goes in.
        let only = hasProfiles && chosen.count == 1 ? chosen.first.map { title(of: $0) + " " } ?? "" : ""
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
            panel.nameFieldStringValue = L("2FA Auth backup %@.json", only + Date().formatted(.iso8601.year().month().day()))
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
        flow = .restore
    }

    /// Step 1 of restore: open the file with the password. With one profile on both sides it restores straight
    /// away; otherwise step 2 lets the user pick which profiles of the file come back, and where to.
    func unlockRestore() {
        guard let file = restoreFile else { return }
        let password = backup.password
        backup.error = nil
        backup.busy = true
        Task {
            let result = await Task.detached { Result { try Backup.decrypt(file, password: password) } }.value
            backup.busy = false
            do {
                let drafts = try result.get()
                backup.password = ""
                backup.found = drafts
                backup.restoreProfiles = Set(drafts.map(\.profile))
                backup.restoreInto = nil
                if !hasProfiles && drafts.allSatisfy({ $0.profile.isEmpty }) { finishRestore() }
            } catch {
                backup.error = Self.message(error)
            }
        }
    }

    /// Step 2: merges the chosen accounts into the list. Accounts already there (same key in the same profile)
    /// are skipped; nothing in the app is deleted or replaced.
    func finishRestore() {
        guard let book, let found = backup.found else { return }
        let picked = Backup.pick(found, profiles: backup.restoreProfiles, into: backup.restoreInto)
        guard !picked.isEmpty else {
            backup.error = L("Choose at least one profile with accounts")
            return
        }
        do {
            let imported = try book.importDrafts(picked)
            let target = backup.restoreInto
            refresh()
            cancelBackup()
            showWindow()
            if let target { switchProfile(target) }
            showToast(Self.summary(imported), seconds: 5)
        } catch {
            backup.error = Self.message(error)
        }
    }

    func cancelBackup() {
        backup = BackupState()
        restoreFile = nil
        flow = nil
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
