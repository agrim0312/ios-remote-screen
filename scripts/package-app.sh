#!/bin/zsh
# Builds a release binary and wraps it in iOSRemoteScreen.app so macOS privacy permissions
# (Screen Recording, Accessibility) belong to "iOS Remote Screen" instead of your terminal.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
app=build/iOSRemoteScreen.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/ios-remote-screen "$app/Contents/MacOS/ios-remote-screen"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.ios-remote-screen</string>
  <key>CFBundleName</key><string>iOS Remote Screen</string>
  <key>CFBundleExecutable</key><string>ios-remote-screen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Set SIGN_IDENTITY (e.g. "Apple Development: you@example.com") to keep macOS privacy grants
# across rebuilds. The default ad-hoc signature changes on every build, so grants must be redone.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier local.ios-remote-screen "$app"
echo "Built $PWD/$app"
echo "Grant permissions (launch through LaunchServices so macOS attributes them to iOS Remote Screen):"
echo "  open -n $PWD/$app --args --request-permissions"
echo "Run:"
echo "  open -n $PWD/$app --stderr /tmp/ios-remote-screen.log --args --launch"
echo "  tail -f /tmp/ios-remote-screen.log   # prints the URL with its token"
