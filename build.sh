#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Gemini2API"
BUNDLE="$APP.app"
BINDIR="$BUNDLE/Contents/MacOS"
ZIP="$APP-macOS.zip"
VERSION="0.1.0"

# 功能：把已有产物或临时目录移入当前用户的 macOS 废纸篓。
# 参数：首参数为待回收路径。
# 返回行为：路径不存在时直接成功；移动失败时返回非零。
move_to_trash() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  local trash_dir="${HOME}/.Trash"
  local target_name
  target_name="$(basename "$target")"
  mkdir -p "$trash_dir"
  mv "$target" "$trash_dir/${target_name}.$(date +%Y%m%d-%H%M%S).$$"
}

move_to_trash "$BUNDLE"
move_to_trash "$ZIP"
mkdir -p "$BINDIR"

BUILD_OUTPUT_DIR="$(mktemp -d)"
trap 'move_to_trash "$BUILD_OUTPUT_DIR"' EXIT

echo "编译中…（arm64 + x86_64 通用二进制）"
FRAMEWORKS=(
  -framework AppKit
  -framework Network
  -framework CryptoKit
  -framework ServiceManagement
)
swiftc -O -o "$BUILD_OUTPUT_DIR/$APP.arm64" Sources/*.swift \
  -target arm64-apple-macos13 "${FRAMEWORKS[@]}"
swiftc -O -o "$BUILD_OUTPUT_DIR/$APP.x86_64" Sources/*.swift \
  -target x86_64-apple-macos13 "${FRAMEWORKS[@]}"
lipo -create \
  "$BUILD_OUTPUT_DIR/$APP.arm64" \
  "$BUILD_OUTPUT_DIR/$APP.x86_64" \
  -output "$BINDIR/$APP"

# 从 logo.png 生成 app 图标（macOS 自带 sips/iconutil）
mkdir -p "$BUNDLE/Contents/Resources"
ICONSET="$BUILD_OUTPUT_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s          logo.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
  sips -z $((s*2)) $((s*2)) logo.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC
  "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>com.gemini2api.gateway</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

# 重新注册，强制 Finder 刷新图标缓存。
# macOS 按 bundle id 缓存，否则显示旧图标。
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/"
LSREG+="Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$PWD/$BUNDLE" 2>/dev/null || true

echo "完成：$(pwd)/$BUNDLE"
