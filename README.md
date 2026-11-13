# 2FA Auth for macOS

**English** · [Tiếng Việt](README.vi.md)

Version **0.2** · macOS 14 or later · English and Vietnamese.

A small Mac app that makes 2FA codes like an authenticator app. It scans QR codes from **anywhere on screen**:
any Chrome profile, Safari, a chat app, an image in Preview...

## Install

1. Download **2FA-Auth-0.2.zip** from [Releases](https://github.com/thanhnhoncntt/2fa-auth-mac/releases/latest). It runs on Apple Silicon and Intel Macs, macOS 14 or later.
2. Open the zip (double-click) and drag **2FA Auth.app** into the **Applications** folder.
3. Open the app. It is not notarized by Apple (that needs a paid developer account), so the first time macOS says it
   could not verify "2FA Auth". Click **Done**, then open **System Settings → Privacy & Security**, scroll down to
   *"2FA Auth" was blocked*, click **Open Anyway** and confirm with your password or Touch ID. This is needed once.

   Or, in Terminal: `xattr -dr com.apple.quarantine "/Applications/2FA Auth.app"`, then open the app normally.
4. The first time you scan a QR code, allow **Screen Recording** (see below).

**Update:** quit the app (⌘Q), replace it in Applications with the new version and open it. Accounts stay in the
Keychain; macOS may ask once whether 2FA Auth can use them: click **Always Allow**.

**Uninstall:** move the app to the Trash. The accounts stay in the Keychain until you delete the `local.twofa-auth`
item in Keychain Access.

You can also build it yourself from source (see [Build](#build)).

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
./scripts/build-app.sh --release  # the zip for Releases: Apple Silicon + Intel, ad-hoc signed
./scripts/build-app.sh && "build/2FA Auth.app/Contents/MacOS/TwoFAAuth" --demo  # try the UI on made-up accounts, Keychain untouched
```

The script signs with your Apple Development certificate when you have one, so Keychain and Screen Recording
permissions survive rebuilds; otherwise it signs ad hoc. `--release` always signs ad hoc, because the
certificate's name (often your Apple ID email) would ship inside the app. App icon:
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
