#!/bin/bash
# Собирает ClickForge.app из swift build
set -e
cd "$(dirname "$0")"

echo "Building..."
swift build

EXE=".build/arm64-apple-macosx/debug/ClickForge"
APP="ClickForge.app"

# Сохранить иконку из старого .app перед удалением
ICNS_TMP=""
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ICNS_TMP=$(mktemp) && cp "$APP/Contents/Resources/AppIcon.icns" "$ICNS_TMP"

# Создать структуру .app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/engine"
mkdir -p "$APP/Contents/Resources/tools"

# Исполняемый файл
cp "$EXE" "$APP/Contents/MacOS/ClickForge"
chmod +x "$APP/Contents/MacOS/ClickForge"

# Engine
cp engine/engine.py "$APP/Contents/Resources/engine/"

# FFmpeg в бандле — не зависит от системы
[ -f tools/ffmpeg ] && cp tools/ffmpeg tools/ffprobe "$APP/Contents/Resources/tools/" && chmod +x "$APP/Contents/Resources/tools/ffmpeg" "$APP/Contents/Resources/tools/ffprobe"

# Иконка: сначала из сохранённой копии, иначе — сгенерировать из Assets
# iconutil требует каталог *.iconset с 1x и @2x (icon_16x16.png, icon_16x16@2x.png, ...)
if [ -n "$ICNS_TMP" ] && [ -f "$ICNS_TMP" ]; then
    cp "$ICNS_TMP" "$APP/Contents/Resources/AppIcon.icns"
    rm -f "$ICNS_TMP"
elif [ -d "ClickForge/Assets.xcassets/AppIcon.appiconset" ]; then
    ICONDIR="ClickForge/Assets.xcassets/AppIcon.appiconset"
    TMP_ICONSET=".build/AppIcon.iconset"
    rm -rf "$TMP_ICONSET" && mkdir -p "$TMP_ICONSET"
    [ -f "$ICONDIR/icon_16.png" ]  && cp "$ICONDIR/icon_16.png"  "$TMP_ICONSET/icon_16x16.png"
    [ -f "$ICONDIR/icon_32.png" ]  && cp "$ICONDIR/icon_32.png"  "$TMP_ICONSET/icon_16x16@2x.png" && cp "$ICONDIR/icon_32.png"  "$TMP_ICONSET/icon_32x32.png"
    [ -f "$ICONDIR/icon_64.png" ]  && cp "$ICONDIR/icon_64.png"  "$TMP_ICONSET/icon_32x32@2x.png"
    [ -f "$ICONDIR/icon_128.png" ] && cp "$ICONDIR/icon_128.png" "$TMP_ICONSET/icon_128x128.png"
    [ -f "$ICONDIR/icon_256.png" ] && cp "$ICONDIR/icon_256.png" "$TMP_ICONSET/icon_128x128@2x.png" && cp "$ICONDIR/icon_256.png" "$TMP_ICONSET/icon_256x256.png"
    [ -f "$ICONDIR/icon_512.png" ] && cp "$ICONDIR/icon_512.png" "$TMP_ICONSET/icon_256x256@2x.png" && cp "$ICONDIR/icon_512.png" "$TMP_ICONSET/icon_512x512.png"
    [ -f "$ICONDIR/icon_1024.png" ] && cp "$ICONDIR/icon_1024.png" "$TMP_ICONSET/icon_512x512@2x.png"
    iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$TMP_ICONSET"
    rm -rf "$TMP_ICONSET"
fi

# Info.plist
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ClickForge</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.clickforge.app</string>
	<key>CFBundleName</key>
	<string>ClickForge</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

echo "Done: $APP"
# Закрыть старый процесс — через graceful quit, чтобы onDisappear успел сохранить конфиг
osascript -e 'tell application "ClickForge" to quit' 2>/dev/null || true
sleep 1
open "$APP"
