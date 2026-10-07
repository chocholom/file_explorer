#!/bin/zsh
# Build FileExplorer and assemble a runnable .app bundle in ./dist.
# With --install, also copy it to /Applications (or ~/Applications if that isn't writable).
set -e
cd "$(dirname "$0")"

VERSION="0.3.0"
APP=dist/FileExplorer.app

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FileExplorer "$APP/Contents/MacOS/FileExplorer"

# App icon: rendered by Scripts/make-icon.swift, packed with iconutil.
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FileExplorer</string>
    <key>CFBundleIdentifier</key>
    <string>local.mirek.FileExplorer</string>
    <key>CFBundleName</key>
    <string>FileExplorer</string>
    <key>CFBundleDisplayName</key>
    <string>File Explorer</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP (v${VERSION}) — run with: open $APP"

if [[ "$1" == "--install" ]]; then
    if [[ -w /Applications ]]; then DEST=/Applications; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
    pkill -x FileExplorer 2>/dev/null || true
    rm -rf "$DEST/FileExplorer.app"
    ditto "$APP" "$DEST/FileExplorer.app"
    echo "Installed to $DEST/FileExplorer.app"
fi
