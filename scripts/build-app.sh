#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$(dirname "$ROOT")/会声.app}"
BUILD_DIR="${HUISHENG_BUILD_DIR:-$ROOT/.build}"
swift build --package-path "$ROOT" --scratch-path "$BUILD_DIR" -c release
BIN="$(swift build --package-path "$ROOT" --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
mkdir -p "$DESTINATION/Contents/MacOS" "$DESTINATION/Contents/Resources"
cp "$BIN/HuiSheng" "$DESTINATION/Contents/MacOS/HuiSheng"
swift "$ROOT/scripts/make-icon.swift" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$DESTINATION/Contents/Resources/AppIcon.icns"
cat > "$DESTINATION/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HuiSheng</string>
<key>CFBundleIdentifier</key><string>local.huisheng.recorder</string>
<key>CFBundleName</key><string>会声</string>
<key>CFBundleDisplayName</key><string>会声</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>会声需要访问麦克风，将你的声音与会议声音一起保存到本机。</string>
<key>NSScreenCaptureUsageDescription</key><string>会声需要屏幕与系统音频录制权限来获取会议声音。本版本只保存音频，不保存屏幕画面。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
</dict></plist>
PLIST
xattr -cr "$DESTINATION"
codesign --force --sign - --identifier local.huisheng.recorder "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
printf '应用已生成：%s\n' "$DESTINATION"
