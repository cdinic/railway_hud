#!/bin/bash
set -e

APP="RailwayHUD.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "→ Compiling..."
swift build -c release 2>&1

echo "→ Packaging $APP..."
rm -rf "$APP"
mkdir -p "$MACOS"

cp .build/release/RailwayHUD "$MACOS/RailwayHUD"

cat > "$CONTENTS/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.local.railway-hud</string>
    <key>CFBundleName</key>
    <string>Railway HUD</string>
    <key>CFBundleDisplayName</key>
    <string>Railway HUD</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>RailwayHUD</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Railway HUD OAuth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>com.local.railway-hud</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo ""
echo "✓ Done: $APP"
echo ""
echo "Run it:        open $APP"
echo "Install:       cp -r $APP /Applications/"
echo "Auto-start:    System Settings → General → Login Items → add RailwayHUD.app"
