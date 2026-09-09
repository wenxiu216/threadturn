#!/bin/zsh
# 编译并打包成 ~/Applications/Threadturn.app
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E 'error|warning: unre|Compiling|Build complete' | grep -v 'warning' || true
BIN=.build/release/Threadturn
[ -x "$BIN" ] || { echo "编译失败"; exit 1; }
APP="$HOME/Applications/Threadturn.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Threadturn"
cp Assets/Threadturn.icns Assets/MenuBarIcon.png Assets/MenuBarIcon@2x.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Threadturn</string>
<key>CFBundleDisplayName</key><string>Threadturn</string>
<key>CFBundleIdentifier</key><string>com.threadturn.app</string>
<key>CFBundleExecutable</key><string>Threadturn</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleIconFile</key><string>Threadturn</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Dev"' | awk '{print $2}')
if [ -n "$ID" ]; then
  codesign --force --sign "$ID" "$APP" >/dev/null 2>&1 && echo "已用固定证书签名 ($ID)"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "临时签名（重打包后需重新授权辅助功能；跑一次 ./make-cert.sh 可免）"
fi
echo "打包完成: $APP"
