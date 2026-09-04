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

# 功能：断言安全契约禁止的文本不存在于目标脚本。
# 参数：file_path 为脚本路径，unexpected 为禁止文本。
# 返回值：禁止文本不存在时返回零，否则终止测试。
assert_not_contains() {
  local file_path="$1"
  local unexpected="$2"
  if grep -F -- "$unexpected" "$file_path" >/dev/null; then
    fail "$file_path 不应包含 $unexpected"
  fi
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

assert_contains build.sh 'move_to_trash "$bundle"'
assert_contains build.sh 'move_to_trash "$zip_path"'
assert_contains build.sh 'move_to_trash "$build_output_dir"'
assert_contains build.sh 'move_to_trash "$cli_binary"'
assert_contains build.sh 'shared_sources=('
assert_contains build.sh 'app_sources=('
assert_contains build.sh 'cli_sources=('
assert_contains build.sh '"${app_sources[@]}"'
assert_contains build.sh '"${cli_sources[@]}"'
assert_not_contains build.sh 'Sources/*.swift'
assert_not_contains build.sh 'Sources/cli/*.swift'
assert_contains make-dmg.sh 'move_to_trash "$DMG"'
assert_contains make-dmg.sh 'move_to_trash "$STAGE"'

workflow_path=".github/workflows/build.yml"
assert_contains "$workflow_path" 'run: bash Tests/build-artifact-tests.sh --auto'
expected_upload_paths="$(printf '%s\n' \
  'Gemini2API-macOS.zip' \
  'Gemini2API.dmg' \
  'gemini2api-macOS')"
actual_upload_paths="$(awk '
  /^[[:space:]]+path: \|[[:space:]]*$/ {
    path_indent = match($0, /[^[:space:]]/) - 1
    collecting = 1
    next
  }
  collecting && /[^[:space:]]/ {
    item_indent = match($0, /[^[:space:]]/) - 1
    if (item_indent <= path_indent) { exit }
    sub(/^[[:space:]]+/, "")
    print
  }
' "$workflow_path")"
[[ "$actual_upload_paths" == "$expected_upload_paths" ]] \
  || fail "$workflow_path 上传路径不是精确的三个发布产物"

if grep -E \
  '(gh[[:space:]]+release|git[[:space:]]+tag|actions/create-release|action-gh-release)' \
  "$workflow_path" >/dev/null; then
  fail "$workflow_path 不应自动创建 tag 或 Release"
fi

echo "release-script-tests passed"
