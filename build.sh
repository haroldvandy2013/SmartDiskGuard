#!/bin/zsh
set -e

BUILD_DIR="dist"
APP_NAME="智能外接盘管家.app"
APP_DIR="$BUILD_DIR/$APP_NAME"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat << 'PLIST_EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SmartDiskGuard</string>
    <key>CFBundleIdentifier</key>
    <string>com.apple-silicon.SmartDiskGuard</string>
    <key>CFBundleName</key>
    <string>智能外接盘管家</string>
    <key>CFBundleDisplayName</key>
    <string>智能外接盘管家</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
        <string>x86_64</string>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST_EOF

echo "🔨 正在编译 Apple Silicon (arm64) + Intel (x86_64) 通用主程序..."
if /usr/bin/swiftc -target arm64-apple-macos12.0 src/SmartDiskGuard.swift -o /tmp/SmartDiskGuard_arm64 2>/dev/null && \
   /usr/bin/swiftc -target x86_64-apple-macos12.0 src/SmartDiskGuard.swift -o /tmp/SmartDiskGuard_x86_64 2>/dev/null; then
    /usr/bin/lipo -create -output "$APP_DIR/Contents/MacOS/SmartDiskGuard" /tmp/SmartDiskGuard_arm64 /tmp/SmartDiskGuard_x86_64
    rm -f /tmp/SmartDiskGuard_arm64 /tmp/SmartDiskGuard_x86_64
else
    /usr/bin/arch -arm64 /usr/bin/swiftc src/SmartDiskGuard.swift -o "$APP_DIR/Contents/MacOS/SmartDiskGuard"
fi

echo "🎨 正在渲染应用高清圆角图标..."
/usr/bin/swift scripts/make_icon.swift
/usr/bin/iconutil -c icns /tmp/AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf /tmp/AppIcon.iconset

echo "✍️ 正在签名与清理隔离属性..."
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/xattr -cr "$APP_DIR"

echo "✅ 构建完成！应用路径：$APP_DIR"
