#!/bin/zsh
set -e

if [ ! -d "dist/智能外接硬盘管家.app" ]; then
    ./build.sh
fi

STAGE_DIR="/tmp/SmartDiskGuard_DMG"
DMG_PATH="dist/智能外接硬盘管家_安装包.dmg"
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"

cp -R "dist/智能外接硬盘管家.app" "$STAGE_DIR/"
xattr -cr "$STAGE_DIR/智能外接硬盘管家.app"
codesign --force --deep --sign - "$STAGE_DIR/智能外接硬盘管家.app"

ln -s /Applications "$STAGE_DIR/Applications"

cat << 'EOF' > "$STAGE_DIR/首次打开若报错请双击我.command"
#!/bin/zsh
echo "正在为您安装【智能外接硬盘管家】并解除 macOS 安全隔离限制..."
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)

if [ -d "$SCRIPT_DIR/智能外接硬盘管家.app" ]; then
    cp -Rf "$SCRIPT_DIR/智能外接硬盘管家.app" /Applications/
fi

xattr -cr "/Applications/智能外接硬盘管家.app" 2>/dev/null
codesign --force --deep --sign - "/Applications/智能外接硬盘管家.app" 2>/dev/null

echo "✅ 安装与授权完成！正在为您打开应用..."
open "/Applications/智能外接硬盘管家.app"
EOF
chmod +x "$STAGE_DIR/首次打开若报错请双击我.command"

hdiutil create -volname "智能外接硬盘管家" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE_DIR"

echo "✅ DMG 安装镜像打包完成：$DMG_PATH"
