// 2FA Auth for macOS: a regular app with a Dock icon and one window; global shortcuts ⌥⇧A and ⌥⇧Q.
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
