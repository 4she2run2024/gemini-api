#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="Gemini2API"
DMG="Gemini2API.dmg"

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

# 需要 create-dmg：brew install create-dmg
command -v create-dmg >/dev/null || { echo "请先安装：brew install create-dmg"; exit 1; }

# 确保 .app 已构建
[ -d "$APP.app" ] || ./build.sh

move_to_trash "$DMG"
STAGE="$(mktemp -d)"
trap 'move_to_trash "$STAGE"' EXIT
cp -R "$APP.app" "$STAGE/"

create-dmg \
  --volname "$APP" \
  --background "assets/dmg-bg.png" \
  --window-pos 200 120 \
  --window-size 640 440 \
  --icon-size 128 \
  --icon "$APP.app" 160 170 \
  --app-drop-link 480 170 \
  --no-internet-enable \
  "$DMG" "$STAGE"

echo "完成：$(pwd)/$DMG"
