#!/usr/bin/env bash
# Builds Capio.app (universal: Apple silicon and Intel) and zips it. Run on a Mac with Xcode.
# Env: VERSION (default 0.7.1), CAPIO_SIGN_IDENTITY (default: ~/.capio-signing/identity; ad hoc when there is none).
set -euo pipefail
umask 022
cd "$(dirname "$0")"
VERSION="${VERSION:-0.7.1}"
APP="build/Capio.app"
# The public half of the key that signs every update; the app only installs archives signed with it.
UPDATE_KEY="HoKiQ4iyesiwgOv6doKw6TqQP98kPd8OUJY3m2q+HAk="
ARCHS=(--arch arm64 --arch x86_64)

echo "── self test ─────────────────────────────────────────────"
swift run -c release capio-selftest

echo "── build ─────────────────────────────────────────────────"
swift build -c release "${ARCHS[@]}" --product Capio
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Capio"
lipo -info "$BIN"

echo "── icon ──────────────────────────────────────────────────"
rm -rf build/Capio.iconset && mkdir -p build
swift run -c release capio-makeicon build/Capio.iconset
iconutil -c icns build/Capio.iconset -o build/AppIcon.icns

echo "── bundle ────────────────────────────────────────────────"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Capio"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Capio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>net.solutionmax.capio</string>
<key>CFBundleName</key><string>Capio</string>
<key>CFBundleDisplayName</key><string>Capio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Capio records your voice with a screencast when you turn the microphone on.</string>
<key>NSCameraUsageDescription</key><string>Capio shows your webcam in a corner of a screencast when you turn it on.</string>
<key>CapioUpdateFeed</key><string>https://github.com/Solutionmax/capio/releases/latest/download/capio-update.json</string>
<key>CapioUpdatePublicKey</key><string>${UPDATE_KEY}</string>
<key>NSHumanReadableCopyright</key><string>Capio ${VERSION} · SolutionMAX</string>
</dict></plist>
PLIST

echo "── sign ──────────────────────────────────────────────────"
# Own identity (Tools/make-signing-identity.sh) keeps Screen Recording across updates; ad hoc only when there is none.
KC="$HOME/Library/Keychains/capio-signing.keychain-db"
IDENTITY="${CAPIO_SIGN_IDENTITY:-$(cat "$HOME/.capio-signing/identity" 2>/dev/null || echo -)}"
if [ "$IDENTITY" != "-" ]; then
  printf 'unlock-keychain -p "%s" "%s"\n' "$(cat "$HOME/.capio-signing/keychain-password")" "$KC" | security -i >/dev/null
else
  echo "NOTE: no signing identity, signing ad hoc: macOS will ask for Screen Recording again after this build"
fi
codesign --force --sign "$IDENTITY" --options runtime --entitlements Capio.entitlements --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
if [ "$IDENTITY" != "-" ]; then
  codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc" && { echo "came out ad hoc, not signed with $IDENTITY" >&2; exit 5; }
  codesign -d -r- "$APP" 2>&1 | grep "designated"
fi

echo "── zip ───────────────────────────────────────────────────"
rm -f "build/Capio-${VERSION}.zip"
(cd build && ditto -c -k --sequesterRsrc --keepParent Capio.app "Capio-${VERSION}.zip")
echo
echo "Done: $(cd build && pwd)/Capio-${VERSION}.zip"
