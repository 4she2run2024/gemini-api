#!/bin/bash
# 用途：验证 Gemini2API App 与独立 CLI 发布产物的架构、版本和链接边界。
# 使用方法：bash Tests/build-artifact-tests.sh [--auto]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--auto") ]]; then
  echo "用法：bash Tests/build-artifact-tests.sh [--auto]" >&2
  exit 2
fi

app_binary="Gemini2API.app/Contents/MacOS/Gemini2API"
cli_binary="gemini2api-macOS"
info_plist="Gemini2API.app/Contents/Info.plist"

# 功能：输出明确的产物契约失败原因并结束测试。
# 参数：message 为不包含敏感数据的失败说明。
# 返回值：不返回；固定以状态码 1 结束。
fail() {
  local message="$1"
  echo "产物验证失败：$message" >&2
  exit 1
}

# 功能：对比实际文本与精确期望值。
# 参数：actual、expected 和用于诊断的 label。
# 返回值：文本相等时返回零，否则调用 fail。
assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] \
    || fail "$label 期望为 $expected，实际为 $actual"
}

# 功能：验证 Mach-O 产物同时包含 arm64 和 x86_64。
# 参数：binary_path 为待验证的可执行文件。
# 返回值：两种架构齐全时返回零，否则返回非零。
assert_universal_binary() {
  local binary_path="$1"
  local architectures
  architectures="$(lipo -archs "$binary_path")"
  test "$architectures" = "x86_64 arm64" \
    || test "$architectures" = "arm64 x86_64" \
    || fail "$binary_path 不是 arm64+x86_64 通用二进制"
}

[[ -x "$app_binary" ]] || fail "$app_binary 不可执行"
[[ -x "$cli_binary" ]] || fail "$cli_binary 不可执行"
assert_universal_binary "$app_binary"
assert_universal_binary "$cli_binary"

short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
build_version="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
assert_equals "$short_version" "0.2.1" "App 短版本"
assert_equals "$build_version" "0.2.1" "App 构建版本"

if otool -L "$cli_binary" | grep -F AppKit >/dev/null; then
  fail "$cli_binary 不应链接 AppKit"
fi
assert_equals "$(./gemini2api-macOS --version)" \
  "Gemini2API 0.2.1" "CLI 版本输出"

echo "build-artifact-tests passed"
