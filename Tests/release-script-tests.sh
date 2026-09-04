#!/bin/bash
# 用途：静态验证 Release 脚本只使用动态临时目录和 macOS 废纸篓。
# 使用方法：bash Tests/release-script-tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "Release 脚本安全检查失败：$1" >&2
  exit 1
}

assert_contains() {
  local file_path="$1"
  local expected="$2"
  grep -F -- "$expected" "$file_path" >/dev/null \
    || fail "$file_path 缺少 $expected"
}

for script_path in build.sh make-dmg.sh; do
  bash -n "$script_path"
  if grep -E '(^|[;&|[:space:]])rm([[:space:]]|$)' "$script_path" >/dev/null; then
    fail "$script_path 包含永久删除命令"
  fi
  if grep -F '/tmp' "$script_path" >/dev/null; then
    fail "$script_path 包含硬编码 /tmp 路径"
  fi
  assert_contains "$script_path" 'mktemp -d'
  assert_contains "$script_path" 'move_to_trash'
done

assert_contains build.sh 'move_to_trash "$BUNDLE"'
assert_contains build.sh 'move_to_trash "$ZIP"'
assert_contains build.sh 'move_to_trash "$BUILD_OUTPUT_DIR"'
assert_contains make-dmg.sh 'move_to_trash "$DMG"'
assert_contains make-dmg.sh 'move_to_trash "$STAGE"'

echo "release-script-tests passed"
