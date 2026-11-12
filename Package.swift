// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TwoFAAuth",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (Base32, TOTP, otpauth links, the account list): no UI, fully unit-tested.
        .target(name: "TwoFACore"),
        // The menu bar app: status item, popover, global shortcuts, screen QR scan, Keychain.
        .executableTarget(name: "TwoFAAuth", dependencies: ["TwoFACore"]),
        .testTarget(name: "TwoFACoreTests", dependencies: ["TwoFACore"]),
    ]
)
