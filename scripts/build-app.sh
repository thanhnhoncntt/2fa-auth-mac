#!/bin/zsh
# Builds "build/2FA Auth.app". --zip also packages dist/2FA-Auth-<version>.zip;
# --install copies it to ~/Applications and (re)starts it.
# Signs with your Apple Development certificate when there is one, so the Keychain and Screen Recording
# permissions survive rebuilds; otherwise ad-hoc (macOS then asks again after each build).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TwoFAAuth
APP="build/2FA Auth.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TwoFAAuth "$APP/Contents/MacOS/TwoFAAuth"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--zip" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  mkdir -p dist
  ZIP="dist/2FA-Auth-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packaged $ZIP"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x TwoFAAuth 2>/dev/null && sleep 0.5 || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"2FA Auth.app"
  cp -R "$APP" ~/Applications/
  # Keep a single copy, so Spotlight and Launchpad do not list the app twice.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
  open ~/Applications/"2FA Auth.app"
  echo "Installed to ~/Applications/2FA Auth.app"
fi
