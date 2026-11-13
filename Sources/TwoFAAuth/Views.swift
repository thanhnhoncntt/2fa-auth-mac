import SwiftUI
import TwoFACore

// MARK: Liquid Glass

extension View {
    /// Liquid Glass on macOS 26 and later; the given fill on earlier versions.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, fallback: some ShapeStyle = .quaternary) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint), in: shape)
        } else {
            background(fallback, in: shape)
        }
    }
}

// MARK: main window

/// The main window: toolbar on top (bridged into the real window toolbar), the codes below, sheets for the form.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            if model.isLocked { LockView() } else { ListScreen() }
            if let toast = model.toast { ToastView(toast: toast).padding(12) }
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .toolbar { MainToolbar() }
        .sheet(isPresented: $model.formOpen, onDismiss: { model.pendingDelete = nil }) { FormSheet() }
        .deleteAlert(when: !model.formOpen)
    }
}

private struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.hasProfiles && !model.isLocked { ProfileMenu() }
        }
        // Separate items, so a narrow window only tucks away what does not fit.
        ToolbarItem(placement: .primaryAction) {
            // A split button: click to scan, the arrow for typing a key instead.
            Menu {
                Button { model.scanScreen() } label: { Label(L("Scan QR Code on Screen"), systemImage: "qrcode.viewfinder") }
                Button { model.startAdd() } label: { Label(L("Enter Setup Key"), systemImage: "keyboard") }
            } label: {
                // With the profile menu beside it, the icon alone leaves room for everything.
                if model.hasProfiles {
                    Label(L("Scan QR"), systemImage: "qrcode.viewfinder").labelStyle(.iconOnly)
                } else {
                    Label(L("Scan QR"), systemImage: "qrcode.viewfinder").labelStyle(.titleAndIcon)
                }
            } primaryAction: {
                model.scanScreen()
            }
            .help(L("Drag a box around a QR code anywhere on screen (⌥⇧Q). The arrow: type a setup key instead (⌘N)."))
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.openSettings() } label: { Label(L("Settings"), systemImage: "gearshape") }
                .help(L("Settings: backup, import from other apps, language (⌘,)"))
        }
    }
}

private struct ListScreen: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                SearchField(focused: $searchFocused)
                if !model.groups.isEmpty { GroupChips() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            if let error = model.loadError {
                ContentUnavailableView {
                    Label(error, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L("Reopen the app. If macOS asks for Keychain access, choose Always Allow."))
                }
            } else if model.profileAccounts.isEmpty {
                EmptyState()
            } else if model.visible.isEmpty {
                ContentUnavailableView.search(text: model.query)
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
        }
        .background { ProfileShortcuts() }
        .onAppear { searchFocused = true }
        .onChange(of: model.openCount) { searchFocused = true }
        .onChange(of: model.currentProfile) { searchFocused = true }
    }
}

/// ⌘1…⌘9 switch to the first nine profiles.
private struct ProfileShortcuts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasProfiles {
            ForEach(Array(model.allProfiles.prefix(9).enumerated()), id: \.offset) { index, profile in
                Button("") { model.switchProfile(profile) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct ProfileMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(Array(model.allProfiles.enumerated()), id: \.offset) { index, profile in
                Button {
                    model.switchProfile(profile)
                } label: {
                    Text((profile == model.currentProfile ? "✓ " : "") + model.title(of: profile)
                         + "  ·  \(model.accountCount(of: profile))" + (index < 9 ? "    ⌘\(index + 1)" : ""))
                }
            }
            Divider()
            Button(L("Manage Profiles…")) { model.openSettings() }
        } label: {
            Label(model.title(of: model.currentProfile), systemImage: "person.crop.circle").labelStyle(.titleAndIcon)
        }
        .frame(maxWidth: 120)
        .help(L("Profile: each one has its own accounts (⌘1, ⌘2…)"))
    }
}

private struct SearchField: View {
    @Environment(AppModel.self) private var model
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glass(in: Capsule())
    }
}

private struct GroupChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(L("All"), group: nil)
                ForEach(model.groups, id: \.self) { chip($0, group: $0) }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chip(_ title: String, group: String?) -> some View {
        let label = HStack(spacing: 5) {
            Text(title)
            Text("\(model.count(in: group))").monospacedDigit().foregroundStyle(.secondary)
        }
        if model.groupFilter == group {
            Button { model.groupFilter = group } label: { label }.buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule).controlSize(.small)
        } else {
            Button { model.groupFilter = group } label: { label }.buttonStyle(.bordered)
                .buttonBorderShape(.capsule).controlSize(.small)
        }
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
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
                            .contentTransition(.numericText())
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
            .fill(Color(hue: hue, saturation: 0.45, brightness: 0.85).gradient)
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
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(L("No accounts yet"), systemImage: "lock.shield")
        } description: {
            Text(L("Click Scan QR and drag a box around a QR code on screen, or type a setup key with ⌘N."))
        } actions: {
            Button(L("Enter Setup Key")) { model.startAdd() }
            Button(L("Import from the Chrome Extension or Another App…")) { model.startImport() }
            Button(L("Restore from a 2FA Auth Backup…")) {
                model.openSettings()
                model.startRestore()
            }
        }
    }
}

private struct ToastView: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(toast.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            if toast.opensPermissionSettings {
                Button(L("Open Settings")) { ScreenScanner.openPermissionSettings() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(legacy ? Color.white : Color.primary)
        .glass(in: RoundedRectangle(cornerRadius: 14), tint: toast.isError ? Color.red.opacity(0.55) : nil,
               fallback: toast.isError ? Color.red.opacity(0.95) : Color.black.opacity(0.85))
        .onTapGesture { model.hideToast() }
    }

    /// Before macOS 26 the toast is a dark or red card with white text.
    private var legacy: Bool {
        if #available(macOS 26.0, *) { false } else { true }
    }
}

private extension View {
    /// "Delete …?" for the account in `pendingDelete`. Attached to the window and to the form sheet; `when`
    /// keeps only the one in front active.
    func deleteAlert(when active: Bool) -> some View {
        modifier(DeleteAlert(active: active))
    }
}

private struct DeleteAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    func body(content: Content) -> some View {
        let shown = Binding(get: { active && model.pendingDelete != nil },
                            set: { if !$0 { model.pendingDelete = nil } })
        content.alert(L("Delete %@? Its codes will be gone for good.", model.pendingDelete?.title ?? ""),
                      isPresented: shown) {
            Button(L("Delete"), role: .destructive) { model.confirmDelete() }
            Button(L("Cancel"), role: .cancel) { model.pendingDelete = nil }
        }
    }
}

// MARK: add / edit sheet

private struct FormSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private var isEdit: Bool { if case .edit = model.form.mode { true } else { false } }
    private var needsKey: Bool { !isEdit && model.form.fromQr == nil }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField(L("Account"), text: $model.form.name, prompt: Text(L("e.g. alex@example.com")))
                    .focused($focused)
                HStack(spacing: 6) {
                    TextField(L("Group (optional)"), text: $model.form.group, prompt: Text(L("e.g. Work")))
                    if !model.groups.isEmpty {
                        Menu {
                            ForEach(model.groups, id: \.self) { group in Button(group) { model.form.group = group } }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Pick an existing group"))
                    }
                }
                if model.hasProfiles {
                    Picker(L("Profile"), selection: $model.form.profile) {
                        ForEach(model.allProfiles, id: \.self) { Text(model.title(of: $0)).tag($0) }
                    }
                }
            } header: {
                Text(isEdit ? L("Edit Account") : L("Add Account")).font(.headline)
            } footer: {
                if let error = model.form.error {
                    Text(error).foregroundStyle(.red)
                } else if model.form.fromQr != nil {
                    Label(L("QR code read. Check the name, then click Save."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if needsKey {
                Section(L("Setup key")) {
                    TextField(L("Setup key"), text: $model.form.secret, prompt: Text(L("Letters and digits from the website")))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                }
            }
            if case .edit(let id) = model.form.mode {
                Section {
                    Button(L("Delete Account"), role: .destructive) {
                        model.pendingDelete = model.accounts.first { $0.id == id }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { model.cancelForm() } }
            ToolbarItem(placement: .confirmationAction) { Button(L("Save")) { model.saveForm() } }
        }
        .deleteAlert(when: true)
        .onAppear { focused = true }
    }
}

// MARK: lock

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(L("2FA Auth is locked"), systemImage: "lock.fill")
        } description: {
            Text(L("Use Touch ID or your Mac password. Turn the lock off in Settings."))
        } actions: {
            Button { model.unlock() } label: { Label(L("Unlock"), systemImage: "touchid") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { model.unlock() }
        .onChange(of: model.openCount) { model.unlock() }
    }
}

// MARK: settings window

/// The Settings window (⌘,): profiles, import from other apps, the app's own backup, general options.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            if model.isLocked {
                LockView()
            } else {
                settingsForm
            }
            if let toast = model.toast { ToastView(toast: toast).padding(12) }
        }
        .frame(minWidth: 400, idealWidth: 440, minHeight: 460, idealHeight: 640)
        .sheet(item: $model.flow) { flow in BackupSheet(restoring: flow == .restore) }
    }

    private var settingsForm: some View {
        @Bindable var model = model
        return Form {
            Section {
                ProfilesEditor()
            } header: {
                Text(L("Profiles"))
            } footer: {
                Text(L("Each profile has its own accounts, like Chrome profiles. Switch with the menu at the top or ⌘1, ⌘2…"))
            }

            Section {
                if model.hasProfiles {
                    Picker(L("Into"), selection: $model.importProfile) {
                        ForEach(model.allProfiles, id: \.self) { Text(model.title(of: $0)).tag($0) }
                    }
                    .help(L("The profile that gets the imported accounts"))
                }
                LabeledContent {
                    Button(L("Import from File…")) { model.startImport() }.buttonStyle(.borderedProminent)
                } label: {
                    Text(L("Bring your accounts over from the Authenticator Chrome extension or another authenticator app. Export them there without a password, then choose the file here."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L("Move from Another App"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Works with: Authenticator (Chrome extension), Aegis, 2FAS, andOTP, Bitwarden, Ente Auth and lists of otpauth:// links."))
                    Text(L("Google Authenticator: choose Transfer accounts → Export, then scan each QR code with Scan QR."))
                }
            }

            Section {
                LabeledContent {
                    HStack {
                        Button(L("Back Up…")) { model.startBackup() }
                        Button(L("Restore…")) { model.startRestore() }
                    }
                } label: {
                    Text(L("A password-protected copy of the accounts in this app, which only 2FA Auth can open. Keep it to move to a new Mac or in case something goes wrong."))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L("Back Up 2FA Auth"))
            } footer: {
                if model.hasProfiles {
                    Text(L("Back up every profile or only some; when restoring, choose which profiles come back and where."))
                }
            }

            Section(L("General")) {
                Picker(L("Language"), selection: Binding(get: { model.language ?? "" },
                                                         set: { model.setLanguage($0.isEmpty ? nil : $0) })) {
                    Text(L("System Default")).tag("")
                    Text("English").tag("en")
                    Text("Tiếng Việt").tag("vi")
                }
                Toggle(isOn: Binding(get: { model.lockEnabled }, set: { model.setLockEnabled($0) })) {
                    Text(L("Lock with Touch ID"))
                    Text(L("Asks for Touch ID or the Mac password before showing codes, and locks again after 5 minutes away."))
                }
                Toggle(L("Open at Login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

/// The profile rows in Settings: click a name to switch, pencil to rename, trash to remove an empty one.
private struct ProfilesEditor: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var editing: String?
    @State private var editText = ""

    var body: some View {
        ForEach(model.allProfiles, id: \.self) { profile in row(profile) }
        HStack(spacing: 6) {
            TextField(L("New profile, e.g. Company A"), text: $newName, prompt: Text(L("New profile, e.g. Company A")))
                .labelsHidden()
                .onSubmit(add)
            Button(L("Add"), action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        if model.addProfile(newName) { newName = "" }
    }

    @ViewBuilder
    private func row(_ profile: String) -> some View {
        let current = profile == model.currentProfile
        let count = model.accountCount(of: profile)
        HStack(spacing: 8) {
            Image(systemName: current ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
            if editing == profile {
                TextField(L("Rename"), text: $editText)
                    .labelsHidden()
                    .onSubmit { if model.renameProfile(profile, to: editText) { editing = nil } }
                    .onExitCommand { editing = nil }
            } else {
                Button { model.switchProfile(profile) } label: {
                    HStack {
                        Text(model.title(of: profile)).fontWeight(current ? .semibold : .regular).lineLimit(1)
                        Spacer()
                        Text(L("%ld accounts", count)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Switch to this profile"))
                Button { editText = model.title(of: profile); editing = profile } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help(L("Rename"))
                if !profile.isEmpty {
                    Button { model.deleteProfile(profile) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(count > 0)
                        .help(count > 0 ? L("Move or delete its accounts first") : L("Delete this profile"))
                }
            }
        }
    }
}

// MARK: backup and restore sheet

private struct BackupSheet: View {
    @Environment(AppModel.self) private var model
    let restoring: Bool
    @FocusState private var focused: Bool

    private var choosing: Bool { restoring && model.backup.found != nil }

    var body: some View {
        Form {
            if choosing { restoreChoices } else { passwordStep }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { model.cancelBackup() } }
            ToolbarItem(placement: .confirmationAction) {
                if choosing {
                    Button(L("Restore")) { model.finishRestore() }
                        .disabled(model.backup.restoreProfiles.isEmpty)
                } else {
                    Button(restoring ? L("Continue") : L("Choose Where to Save…")) {
                        if restoring { model.unlockRestore() } else { model.saveBackup() }
                    }
                    .disabled(model.backup.busy || model.backup.password.isEmpty || (!restoring && model.backup.profiles.isEmpty))
                }
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var passwordStep: some View {
        @Bindable var model = model
        if !restoring && model.hasProfiles {
            Section(L("Profiles to back up")) {
                ForEach(model.allProfiles, id: \.self) { profile in
                    Toggle(isOn: member(profile, of: \.profiles)) {
                        Text(model.title(of: profile)) + Text("  " + L("%ld accounts", model.accountCount(of: profile))).foregroundColor(.secondary)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        Section {
            if restoring {
                LabeledContent(L("File"), value: model.backup.fileName)
            }
            SecureField(L("Password"), text: $model.backup.password, prompt: Text(L("At least %ld characters", Backup.minPasswordLength)))
                .focused($focused)
            if !restoring {
                SecureField(L("Repeat password"), text: $model.backup.confirm)
            }
        } header: {
            Text(restoring ? L("Restore") : L("Back Up")).font(.headline)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.backup.error { Text(error).foregroundStyle(.red) }
                if model.backup.busy { ProgressView().controlSize(.small) }
                Text(restoring
                     ? L("Enter the password you set when backing up. Next you can choose which profiles to bring back.")
                     : L("A file encrypted with this password. Forget the password and nobody can open the file, not even this app."))
            }
        }
    }

    @ViewBuilder private var restoreChoices: some View {
        @Bindable var model = model
        let found = model.backup.found ?? []
        Section {
            ForEach(Backup.profiles(in: found), id: \.name) { item in
                Toggle(isOn: member(item.name, of: \.restoreProfiles)) {
                    Text(model.title(of: item.name)) + Text("  " + L("%ld accounts", item.count)).foregroundColor(.secondary)
                }
                .toggleStyle(.checkbox)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Restore")).font(.headline)
                Text(L("Profiles in this backup"))
            }
        }
        Section {
            Picker(L("Restore into"), selection: $model.backup.restoreInto) {
                Text(L("Their own profiles")).tag(String?.none)
                ForEach(model.allProfiles, id: \.self) { Text(model.title(of: $0)).tag(String?.some($0)) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.backup.error { Text(error).foregroundStyle(.red) }
                Text(L("Nothing in the app is deleted or replaced: the accounts are added, and ones already in that profile are skipped. A profile that does not exist yet is created."))
            }
        }
    }

    /// A checkbox for one profile in a set of BackupState.
    private func member(_ profile: String, of set: WritableKeyPath<BackupState, Set<String>>) -> Binding<Bool> {
        Binding(get: { model.backup[keyPath: set].contains(profile) },
                set: { on in
                    if on { model.backup[keyPath: set].insert(profile) } else { model.backup[keyPath: set].remove(profile) }
                })
    }
}

// MARK: menu bar right-click

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
