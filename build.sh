#!/bin/bash
# 用途：构建 Gemini2API 通用 App 与不链接 AppKit 的通用 CLI。
# 使用方法：在项目根目录执行 ./build.sh。
set -euo pipefail
cd "$(dirname "$0")"

app_name="Gemini2API"
bundle="$app_name.app"
binary_dir="$bundle/Contents/MacOS"
zip_path="$app_name-macOS.zip"
cli_binary="gemini2api-macOS"
version="0.2.0"
trash_sequence=0
build_output_dir=""
bundle_created=0
cli_created=0
build_succeeded=0

# 功能：把已有产物或临时目录移入当前用户的 macOS 废纸篓。
# 参数：首参数为待回收路径。
# 返回行为：路径不存在时直接成功；移动失败时返回非零。
move_to_trash() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  local trash_dir="${HOME}/.Trash"
  local target_name
  local trash_target
  target_name="$(basename "$target")"
  mkdir -p "$trash_dir"
  while true; do
    trash_sequence=$((trash_sequence + 1))
    trash_target="$trash_dir/${target_name}.$(date +%Y%m%d-%H%M%S).$$.$trash_sequence"
    [[ ! -e "$trash_target" && ! -L "$trash_target" ]] && break
  done
  mv "$target" "$trash_target"
}

# 功能：保留构建退出码，并回收临时目录与失败时的新产物。
# 参数：无；使用当前构建的路径和所有权标记。
# 返回行为：不返回；以进入 EXIT trap 时的退出码结束。
cleanup_build() {
  local exit_status=$?
  trap - EXIT
  set +e
  move_to_trash "$build_output_dir"
  if [[ "$build_succeeded" -ne 1 ]]; then
    [[ "$bundle_created" -eq 1 ]] && move_to_trash "$bundle"
    [[ "$cli_created" -eq 1 ]] && move_to_trash "$cli_binary"
  fi
  exit "$exit_status"
}

trap cleanup_build EXIT

move_to_trash "$bundle"
move_to_trash "$zip_path"
move_to_trash "$cli_binary"
bundle_created=1
mkdir -p "$binary_dir"

build_output_dir="$(mktemp -d)"

echo "编译中…（arm64 + x86_64 通用二进制）"
shared_sources=(
  Sources/AnthropicProtocol.swift
  Sources/Config.swift
  Sources/Engine.swift
  Sources/HTTPServer.swift
  Sources/HTTPServer+Anthropic.swift
  Sources/HTTPServer+OpenAI.swift
  Sources/Models.swift
  Sources/Prompt.swift
  Sources/ToolCalling.swift
  Sources/Util.swift
  Sources/gateway-pipeline.swift
  Sources/gateway-protocol.swift
  Sources/gateway-runtime.swift
  Sources/http-server-gemini.swift
  Sources/http-server-responses.swift
)
app_sources=(
  "${shared_sources[@]}"
  Sources/AppDelegate.swift
  Sources/SettingsWindow.swift
  Sources/main.swift
)
cli_sources=(
  "${shared_sources[@]}"
  Sources/cli/cli-command.swift
  Sources/cli/cli-main.swift
  Sources/cli/daemon-controller.swift
  Sources/cli/daemon-logger.swift
  Sources/cli/runtime-state.swift
)
app_frameworks=(
  -framework AppKit
  -framework Network
  -framework CryptoKit
  -framework ServiceManagement
)
cli_frameworks=(
  -framework Network
  -framework CryptoKit
)

swiftc -O -o "$build_output_dir/$app_name.arm64" "${app_sources[@]}" \
  -target arm64-apple-macos13 "${app_frameworks[@]}"
swiftc -O -o "$build_output_dir/$app_name.x86_64" "${app_sources[@]}" \
  -target x86_64-apple-macos13 "${app_frameworks[@]}"
lipo -create \
  "$build_output_dir/$app_name.arm64" \
  "$build_output_dir/$app_name.x86_64" \
  -output "$binary_dir/$app_name"

swiftc -O -o "$build_output_dir/$cli_binary.arm64" "${cli_sources[@]}" \
  -target arm64-apple-macos13 "${cli_frameworks[@]}"
swiftc -O -o "$build_output_dir/$cli_binary.x86_64" "${cli_sources[@]}" \
  -target x86_64-apple-macos13 "${cli_frameworks[@]}"
cli_created=1
lipo -create \
  "$build_output_dir/$cli_binary.arm64" \
  "$build_output_dir/$cli_binary.x86_64" \
  -output "$cli_binary"

# 从 logo.png 生成 app 图标（macOS 自带 sips/iconutil）
mkdir -p "$bundle/Contents/Resources"
iconset="$build_output_dir/AppIcon.iconset"
mkdir -p "$iconset"
for icon_size in 16 32 128 256 512; do
  double_size=$((icon_size * 2))
  sips -z "$icon_size" "$icon_size" logo.png \
    --out "$iconset/icon_${icon_size}x${icon_size}.png" >/dev/null
  sips -z "$double_size" "$double_size" logo.png \
    --out "$iconset/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC
  "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundleDisplayName</key><string>$app_name</string>
  <key>CFBundleIdentifier</key><string>com.gemini2api.gateway</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleExecutable</key><string>$app_name</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$bundle" 2>/dev/null || true

# 重新注册，强制 Finder 刷新图标缓存。
# macOS 按 bundle id 缓存，否则显示旧图标。
lsregister_path="/System/Library/Frameworks/CoreServices.framework/Versions/A/"
lsregister_path+="Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$lsregister_path" ] \
  && "$lsregister_path" -f "$PWD/$bundle" 2>/dev/null || true

echo "完成：$(pwd)/$bundle"
echo "完成：$(pwd)/$cli_binary"
build_succeeded=1
