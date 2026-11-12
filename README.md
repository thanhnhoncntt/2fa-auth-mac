# 2FA Auth for macOS

**English** · [Tiếng Việt](README.vi.md)

Version **0.2** · macOS 14 or later · English and Vietnamese.

A small Mac app that makes 2FA codes like an authenticator app. It scans QR codes from **anywhere on screen**:
any Chrome profile, Safari, a chat app, an image in Preview...

## Use

| Task | How |
|---|---|
| Open the window | Click the Dock icon or the 🔐 menu bar icon, or press **⌥⇧A** anywhere (again to hide). Closing the window (⌘W) keeps the app running for the shortcuts; ⌘Q quits |
| Copy a code | Click its row. Or type a few letters to search, then **Enter** (copies the first row). Copied codes are cleared from the clipboard after 30 seconds |
| Scan a QR code | **⌥⇧Q** or the **Scan QR** button. The window steps aside; drag a box around the QR code like ⌘⇧4. `Esc` cancels |
| Type a setup key | **Enter Key** button |
| Filter by group | Click a group chip under the search field |
| Edit / delete | Right-click a row. The service name read from a QR code is kept and shown in small type under the code |
| Open at login | **⋯ → Open at Login** |
| Language | **⋯ → Language**: System Default / English / Tiếng Việt (the app restarts) |
| Quick menu | Right-click the menu bar icon: version, open, scan, back up, restore, quit |

On the first scan macOS asks for **Screen Recording** permission: turn it on for 2FA Auth in System Settings →
Privacy & Security → Screen Recording, then reopen the app.

## Back up and restore

- **Back up:** ⋯ → **Back Up…** (or ⌘S), set a password (8+ characters), choose where to save. The `.json` file is
  sealed with AES-256-GCM under a key derived from the password with PBKDF2-SHA256 (600,000 rounds, random salt),
  so it is fine in iCloud Drive or on a USB stick. **Forget the password and nobody can open the file**, not even the app.
- **Restore:** ⋯ → **Restore…** (or ⌘O), pick the file, type the password. Accounts are merged into your list;
  ones with a key you already have are skipped, and nothing is deleted.

## Security

**Optional, off by default:** ⋯ → **Lock with Touch ID**. When on, codes show only after Touch ID (or your Mac
password); the app locks again after 5 minutes away, when the screen locks or when the Mac sleeps. Turning on
**FileVault** (System Settings → Privacy & Security) encrypts the whole disk as well.

- Keys live in the **login Keychain** on this Mac only, as one item of service `local.twofa-auth`. No sync, no network.
- The screenshot taken for a scan sits in the user's private temp folder and is deleted right after the code is read.
- Copied codes are marked "concealed" so clipboard managers skip them.

## Build

```sh
swift test                        # Base32, TOTP (RFC 4226/6238), otpauth, account list, backups, translations
./scripts/build-app.sh            # builds build/2FA Auth.app
./scripts/build-app.sh --install  # installs to ~/Applications, restarts it, removes the build copy
./scripts/build-app.sh --zip      # packages dist/2FA-Auth-<version>.zip
./scripts/build-app.sh && "build/2FA Auth.app/Contents/MacOS/TwoFAAuth" --demo  # try the UI on made-up accounts, Keychain untouched
```

The script signs with your Apple Development certificate when you have one, so Keychain and Screen Recording
permissions survive rebuilds; otherwise it signs ad hoc. App icon:
`swift scripts/make-icon.swift . && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.

| Path | Role |
|---|---|
| `Sources/TwoFACore/` | Pure logic with tests: `OTP.swift`, `Otpauth.swift` (QR links), `Account.swift`, `AccountBook.swift`, `Backup.swift` (encrypted backups), `AutoLock.swift` |
| `Sources/TwoFAAuth/AppDelegate.swift` | Window, menu bar icon, menus, shortcuts |
| `Sources/TwoFAAuth/AppModel.swift` | UI state: copy, forms, scan, backups, lock, language |
| `Sources/TwoFAAuth/Views.swift` | SwiftUI views |
| `Sources/TwoFAAuth/ScreenScanner.swift` | Region pick with `screencapture -i`, QR reading with Vision |
| `Sources/TwoFAAuth/KeychainStorage.swift` | Keychain storage |
| `Sources/TwoFAAuth/HotKeys.swift` | Global shortcuts (Carbon, no Accessibility permission needed) |
| `Resources/vi.lproj/Localizable.strings` | Vietnamese. English source strings live in the code as `L("…")`; a test checks every one is translated |
