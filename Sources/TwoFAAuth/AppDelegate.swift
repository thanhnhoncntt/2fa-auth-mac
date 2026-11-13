import AppKit
import Carbon.HIToolbox
import SwiftUI
import TwoFACore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    private var hotKeys: HotKeys?
    /// `--no-activate` (for screenshots): windows open behind the others and never take the keyboard.
    private let quiet = CommandLine.arguments.contains("--no-activate")

    /// The Settings window (⌘,), made on first use.
    private lazy var settingsWindow: NSWindow = {
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        settings.title = L("Settings")
        settings.isReleasedWhenClosed = false
        settings.contentViewController = NSHostingController(rootView: SettingsView().environment(model))
        settings.setContentSize(NSSize(width: 440, height: 640))
        if !settings.setFrameUsingName("SettingsWindow") { settings.center() }
        settings.setFrameAutosaveName("SettingsWindow")
        return settings
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--demo` runs on made-up accounts in memory, never touching the Keychain (for trying out the UI).
        model = AppModel(storage: CommandLine.arguments.contains("--demo") ? DemoStorage() : KeychainStorage())
        model.showWindow = { [weak self] in self?.show() }
        // Out of the way while the user picks a QR region, without quitting.
        model.hideWindow = { NSApp.hide(nil) }
        model.openSettingsWindow = { [weak self] in self?.showSettings() }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "2FA Auth"
        // The buttons live in the real window toolbar (SwiftUI's .toolbar, bridged); the title is left out for room.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 420)
        let content = NSHostingController(rootView: ContentView().environment(model))
        content.sizingOptions = [] // keep the window's own size instead of shrinking to the SwiftUI minimum
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 360, height: 520))
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")

        // For the optional lock: leaving the app starts the 5-minute timer; coming back or the screen locking checks it.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.wentAway() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.cameBack() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.lockNow() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.lockNow() }
        }

        NSApp.mainMenu = Self.mainMenu()
        addStatusItem()
        if CommandLine.arguments.contains("--demo"), let screen = Self.argument("--demo-screen") {
            model.showDemoScreen(screen)
        }
        if quiet { window.orderBack(nil) } else { show() }

        let optionShift = optionKey | shiftKey
        hotKeys = HotKeys([
            .init(keyCode: kVK_ANSI_A, modifiers: optionShift) { [weak self] in self?.toggle() },
            .init(keyCode: kVK_ANSI_Q, modifiers: optionShift) { [weak self] in self?.model.scanScreen() },
        ])
    }

    private static func argument(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    /// The menu bar icon: a click shows or hides the window; a right-click (or ⌃-click) opens a short menu.
    private func addStatusItem() {
        // A new status item goes to the far left of the others, which on a full menu bar is behind the notch.
        // Start it at the right end instead, next to the clock; once the user ⌘-drags it, macOS keeps that spot.
        let name = "TwoFAAuth"
        let positionKey = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = name
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "2FA Auth")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let header = NSMenuItem()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let headerView = NSHostingView(rootView: StatusMenuHeader(version: version) { [weak self, weak menu] in
            menu?.cancelTracking()
            self?.show()
        })
        headerView.frame = NSRect(origin: .zero, size: headerView.fittingSize)
        header.view = headerView
        menu.addItem(header)
        menu.addItem(.separator())

        let scan = menu.addItem(withTitle: L("Scan QR Code on Screen"), action: #selector(scanFromMenu), keyEquivalent: "q")
        scan.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(withTitle: L("Enter Setup Key"), action: #selector(addKeyFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Settings…"), action: #selector(settingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit 2FA Auth"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }

        // Attach the menu only for this click, so a plain click keeps toggling the window.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// ⌥⇧A and the menu bar icon: bring the window up, or put it away when it is already in front.
    private func toggle() {
        if NSApp.isActive && window.isVisible && window.isKeyWindow { NSApp.hide(nil) } else { show() }
    }

    private func showSettings() {
        if quiet { settingsWindow.orderBack(nil); return }
        NSApp.unhide(nil)
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func show() {
        if quiet { window.orderBack(nil); return }
        model.willShow()
        NSApp.unhide(nil)
        window.orderFrontRegardless()
        window.makeKey()
        // The plain activate() of macOS 14+ is only a request and was refused from the second click on while
        // another app was in front, leaving the window behind it without keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
    }

    // Clicking the Dock icon (or opening the app again) brings the window back after it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    // Closing the window keeps the app running so the shortcuts keep working; ⌘Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func scanFromMenu() { model.scanScreen() }
    @objc private func addKeyFromMenu() { show(); model.startAdd() }
    @objc private func settingsFromMenu() { model.openSettings() }

    /// A standard app menu; the Edit menu is what makes ⌘C / ⌘V / ⌘A work in the text fields.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: L("About 2FA Auth"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Settings…"), action: #selector(settingsFromMenu), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide 2FA Auth"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Quit 2FA Auth"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "2FA Auth")

        let account = NSMenu(title: L("Accounts"))
        let scan = account.addItem(withTitle: L("Scan QR Code on Screen"), action: #selector(scanFromMenu), keyEquivalent: "q")
        scan.keyEquivalentModifierMask = [.option, .shift]
        account.addItem(withTitle: L("Enter Setup Key"), action: #selector(addKeyFromMenu), keyEquivalent: "n")
        main.addItem(submenu: account, title: L("Accounts"))

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: L("Edit"))

        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: L("Window"))
        NSApp.windowsMenu = windowMenu
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

