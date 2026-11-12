import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    private var hotKeys: HotKeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--demo` runs on made-up accounts in memory, never touching the Keychain (for trying out the UI).
        model = AppModel(storage: CommandLine.arguments.contains("--demo") ? DemoStorage() : KeychainStorage())
        model.showWindow = { [weak self] in self?.show() }
        // Out of the way while the user picks a QR region, without quitting.
        model.hideWindow = { NSApp.hide(nil) }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "2FA Auth"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 420)
        let content = NSHostingController(rootView: ContentView().environmentObject(model))
        content.sizingOptions = [] // keep the window's own size instead of shrinking to the SwiftUI minimum
        window.contentViewController = content
        window.setContentSize(NSSize(width: 360, height: 520))
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")

        NSApp.mainMenu = Self.mainMenu()
        addStatusItem()
        show()

        let optionShift = optionKey | shiftKey
        hotKeys = HotKeys([
            .init(keyCode: kVK_ANSI_A, modifiers: optionShift) { [weak self] in self?.toggle() },
            .init(keyCode: kVK_ANSI_Q, modifiers: optionShift) { [weak self] in self?.model.scanScreen() },
        ])
    }

    /// The menu bar icon: one click shows or hides the same window as the Dock icon.
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
            button.action = #selector(toggleFromStatusItem)
        }
    }

    @objc private func toggleFromStatusItem() { toggle() }

    /// ⌥⇧A and the menu bar icon: bring the window up, or put it away when it is already in front.
    private func toggle() {
        if NSApp.isActive && window.isVisible && window.isKeyWindow { NSApp.hide(nil) } else { show() }
    }

    private func show() {
        model.willShow()
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
    @objc private func backupFromMenu() { show(); model.startBackup() }
    @objc private func restoreFromMenu() { show(); model.startRestore() }

    /// A standard app menu; the Edit menu is what makes ⌘C / ⌘V / ⌘A work in the text fields.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Giới thiệu 2FA Auth", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Ẩn 2FA Auth", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Thoát 2FA Auth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "2FA Auth")

        let account = NSMenu(title: "Tài khoản")
        let scan = account.addItem(withTitle: "Quét mã QR trên màn hình", action: #selector(scanFromMenu), keyEquivalent: "q")
        scan.keyEquivalentModifierMask = [.option, .shift]
        account.addItem(withTitle: "Nhập khóa thiết lập", action: #selector(addKeyFromMenu), keyEquivalent: "n")
        account.addItem(.separator())
        account.addItem(withTitle: "Sao lưu…", action: #selector(backupFromMenu), keyEquivalent: "s")
        account.addItem(withTitle: "Khôi phục…", action: #selector(restoreFromMenu), keyEquivalent: "o")
        main.addItem(submenu: account, title: "Tài khoản")

        let edit = NSMenu(title: "Sửa")
        edit.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Sửa")

        let windowMenu = NSMenu(title: "Cửa sổ")
        windowMenu.addItem(withTitle: "Thu nhỏ", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Đóng", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: "Cửa sổ")
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
