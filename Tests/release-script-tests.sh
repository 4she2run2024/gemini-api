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

# 功能：保留测试退出码，并把故障注入目录移入废纸篓。
# 参数：无；使用 build_test_root。
# 返回值：不返回；以进入 trap 时的退出码结束。
cleanup_build_test() {
  local exit_status=$?
  trap - EXIT
  set +e
  if [[ -d "$build_test_root" ]]; then
    swift -e '
      import Foundation
      var recycled_url: NSURL?
      try FileManager.default.trashItem(
        at: URL(fileURLWithPath: CommandLine.arguments[1]),
        resultingItemURL: &recycled_url)
    ' "$build_test_root" >/dev/null
  fi
  exit "$exit_status"
}

build_test_root="$(mktemp -d)"
trap cleanup_build_test EXIT
fixture_root="$build_test_root/fixture"
shim_dir="$build_test_root/shims"
isolated_trash="$build_test_root/trash"
build_temp="$fixture_root/build-output-$RANDOM-$$"
move_log="$build_test_root/moves.tsv"
real_mv="$(command -v mv)"
mkdir -p "$fixture_root/Gemini2API.app" "$shim_dir" "$isolated_trash"
printf '%s\n' "old-bundle" >"$fixture_root/Gemini2API.app/preexisting-marker"
printf '%s\n' "old-cli" >"$fixture_root/gemini2api-macOS"
chmod +x "$fixture_root/gemini2api-macOS"
cp build.sh "$fixture_root/build.sh"

cat >"$shim_dir/mktemp" <<'SHIM'
#!/bin/bash
set -euo pipefail
mkdir -p "$BUILD_TEST_TEMP"
printf '%s\n' "$BUILD_TEST_TEMP"
SHIM

cat >"$shim_dir/swiftc" <<'SHIM'
#!/bin/bash
set -euo pipefail
output_path=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    output_path="$2"
    break
  fi
  shift
done
[[ -n "$output_path" ]]
mkdir -p "$(dirname "$output_path")"
printf '%s\n' "fake-swift-binary" >"$output_path"
chmod +x "$output_path"
SHIM

cat >"$shim_dir/lipo" <<'SHIM'
#!/bin/bash
set -euo pipefail
output_path=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-output" ]]; then
    output_path="$2"
    break
  fi
  shift
done
[[ -n "$output_path" ]]
mkdir -p "$(dirname "$output_path")"
printf '%s\n' "fake-universal-binary" >"$output_path"
chmod +x "$output_path"
SHIM

cat >"$shim_dir/sips" <<'SHIM'
#!/bin/bash
exit 42
SHIM

cat >"$shim_dir/mv" <<'SHIM'
#!/bin/bash
set -euo pipefail
source_path="$1"
requested_destination="$2"
sandbox_destination="$BUILD_TEST_TRASH/${requested_destination##*/}"
printf '%s\t%s\t%s\n' \
  "$source_path" "$requested_destination" "$sandbox_destination" >>"$MOVE_LOG"
"$BUILD_TEST_REAL_MV" "$source_path" "$sandbox_destination"
SHIM
chmod +x "$shim_dir/mktemp" "$shim_dir/swiftc" "$shim_dir/lipo"
chmod +x "$shim_dir/sips" "$shim_dir/mv"

set +e
PATH="$shim_dir:$PATH" \
BUILD_TEST_TEMP="$build_temp" \
BUILD_TEST_TRASH="$isolated_trash" \
BUILD_TEST_REAL_MV="$real_mv" \
MOVE_LOG="$move_log" \
  bash "$fixture_root/build.sh" >/dev/null 2>&1
build_status=$?
set -e

[[ "$build_status" -eq 42 ]] || fail "故障构建未保留 sips 退出码 42"
[[ ! -e "$fixture_root/Gemini2API.app" ]] \
  || fail "故障构建遗留本次新建 App bundle"
[[ ! -e "$fixture_root/gemini2api-macOS" ]] \
  || fail "故障构建遗留本次新建 CLI"
[[ ! -e "$build_temp" ]] || fail "故障构建遗留临时目录"

bundle_moves="$(awk -F '\t' '$1 == "Gemini2API.app" { count += 1 } END { print count + 0 }' \
  "$move_log")"
cli_moves="$(awk -F '\t' '$1 == "gemini2api-macOS" { count += 1 } END { print count + 0 }' \
  "$move_log")"
temp_moves="$(awk -F '\t' -v target="$build_temp" \
  '$1 == target { count += 1 } END { print count + 0 }' "$move_log")"
[[ "$bundle_moves" -eq 2 ]] || fail "App bundle 未分别回收旧产物与失败新产物"
[[ "$cli_moves" -eq 2 ]] || fail "CLI 未分别回收旧产物与失败新产物"
[[ "$temp_moves" -eq 1 ]] || fail "构建临时目录未被精确回收一次"

old_bundle_path="$(awk -F '\t' '$1 == "Gemini2API.app" { print $3; exit }' "$move_log")"
old_cli_path="$(awk -F '\t' '$1 == "gemini2api-macOS" { print $3; exit }' "$move_log")"
[[ -f "$old_bundle_path/preexisting-marker" ]] \
  || fail "构建前 App bundle 未在隔离 Trash 中保留"
[[ "$(<"$old_cli_path")" == "old-cli" ]] \
  || fail "构建前 CLI 在隔离 Trash 中被覆盖"

if awk -F '\t' -v trash_prefix="${HOME}/.Trash/" '
  index($2, trash_prefix) != 1 { invalid = 1 }
  END { exit invalid }
' "$move_log"; then
  :
else
  fail "构建清理目标不是当前用户 macOS Trash"
fi

echo "release-script-tests passed"
