import SwiftUI
import TwoFACore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.isLocked {
                LockScreen()
            } else {
                switch model.screen {
                case .list: ListScreen()
                case .form: FormScreen()
                case .backup: BackupScreen(restoring: false)
                case .restore: BackupScreen(restoring: true)
                }
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
                        detail: L("Reopen the app. If macOS asks for Keychain access, choose Always Allow."))
            } else if model.accounts.isEmpty {
                EmptyState()
            } else if model.visible.isEmpty {
                Message(icon: "magnifyingglass", title: L("No matching accounts"), detail: nil)
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
                Label(L("Scan QR"), systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .help(L("Drag a box around a QR code anywhere on screen (⌥⇧Q)"))

            Button { model.startAdd() } label: {
                Label(L("Enter Key"), systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .help(L("Type the setup key a website gives you (⌘N)"))

            Spacer()

            Menu {
                Button(L("Back Up…")) { model.startBackup() }
                Button(L("Restore…")) { model.startRestore() }
                Divider()
                Menu(L("Language")) {
                    languageButton(L("System Default"), code: nil)
                    languageButton("English", code: "en")
                    languageButton("Tiếng Việt", code: "vi")
                }
                Toggle(L("Lock with Touch ID"), isOn: Binding(get: { model.lockEnabled }, set: { model.setLockEnabled($0) }))
                Toggle(L("Open at Login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More"))
        }
        .controlSize(.large)
    }

    private func languageButton(_ title: String, code: String?) -> some View {
        Button((model.language == code ? "✓ " : "") + title) { model.setLanguage(code) }
    }
}

private struct SearchField: View {
    @EnvironmentObject private var model: AppModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Search accounts · Enter to copy"), text: $model.query)
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
                chip(L("All"), group: nil)
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
                        Label(L("Copied"), systemImage: "checkmark.circle.fill")
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
        .help(L("Click to copy the code"))
        .contextMenu {
            Button(L("Copy Code")) { model.copy(account) }
            Button(L("Edit…")) { model.startEdit(account) }
            Divider()
            Button(L("Delete…"), role: .destructive) { model.pendingDelete = account }
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
            Text(L("No accounts yet")).font(.headline)
            Text(L("Click Scan QR and drag a box around a QR code on screen, or click Enter Key."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L("Restore from a Backup File…")) { model.startRestore() }.buttonStyle(.link)
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
            Text(L("Delete %@? Its codes will be gone for good.", account.title)).font(.callout)
            HStack {
                Spacer()
                Button(L("Cancel")) { model.pendingDelete = nil }
                Button(L("Delete"), role: .destructive) { model.confirmDelete() }.buttonStyle(.borderedProminent).tint(.red)
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
                Button(L("Open Settings")) { ScreenScanner.openPermissionSettings() }.controlSize(.small)
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
                Text(isEdit ? L("Edit Account") : L("Add Account")).font(.headline)
                Spacer()
            }
            if model.form.fromQr != nil {
                Label(L("QR code read. Check the name, then click Save."), systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            field(L("Account"), prompt: L("e.g. alex@example.com"), text: $model.form.name).focused($focused)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Group (optional)")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("", text: $model.form.group, prompt: Text(L("e.g. Work"))).textFieldStyle(.roundedBorder)
                    if !model.groups.isEmpty {
                        Menu {
                            ForEach(model.groups, id: \.self) { group in Button(group) { model.form.group = group } }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Pick an existing group"))
                    }
                }
            }
            if needsKey {
                field(L("Setup key"), prompt: L("Letters and digits from the website"), text: $model.form.secret)
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
                    Button(L("Delete Account"), role: .destructive) {
                        model.pendingDelete = model.accounts.first { $0.id == id }
                    }
                    .buttonStyle(.link).foregroundStyle(.red)
                }
                Spacer()
                Button(L("Cancel")) { model.cancelForm() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) { model.saveForm() }.keyboardShortcut(.defaultAction)
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
                Text(restoring ? L("Restore") : L("Back Up")).font(.headline)
                Spacer()
            }
            if restoring {
                Label(model.backup.fileName, systemImage: "doc.badge.clock").font(.callout).lineLimit(1)
                Text(L("Enter the password you set when backing up. Accounts in the file are added to your list; ones already there are skipped, and nothing is deleted."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Back up %ld accounts to a file encrypted with this password. Forget the password and nobody can open the file, not even this app.", model.accounts.count))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            secure(L("Password"), prompt: L("At least %ld characters", Backup.minPasswordLength), text: $model.backup.password).focused($focused)
            if !restoring {
                secure(L("Repeat password"), prompt: "", text: $model.backup.confirm)
            }
            if let error = model.backup.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                if model.backup.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancel")) { model.cancelBackup() }.keyboardShortcut(.cancelAction)
                Button(restoring ? L("Restore") : L("Choose Where to Save…")) {
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

// MARK: lock

private struct LockScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(L("2FA Auth is locked")).font(.headline)
            Button { model.unlock() } label: {
                Label(L("Unlock"), systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text(L("Use Touch ID or your Mac password. Turn the lock off with the ⋯ button."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .onAppear { model.unlock() }
        .onChange(of: model.openCount) { model.unlock() }
    }
}

// MARK: menu bar right-click

/// The top of the menu bar icon's right-click menu: name, version and "Bấm để mở". The whole area opens the window.
struct StatusMenuHeader: View {
    let version: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("2FA Auth").font(.system(size: 14, weight: .semibold))
                    Text(L("Version %@", version)).font(.system(size: 11))
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }
                Spacer(minLength: 16)
                Text(L("Click to open"))
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(hovering ? Color.white.opacity(0.22) : Color.primary.opacity(0.1)))
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .frame(width: 270)
    }
}
