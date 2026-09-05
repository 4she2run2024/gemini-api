#!/bin/bash
# 用途：编译并执行 Gemini2API Swift 测试。
# 使用方法：bash Tests/run-tests.sh [--auto]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--auto") ]]; then
  echo "用法：bash Tests/run-tests.sh [--auto]" >&2
  exit 2
fi

TEST_OUTPUT_DIR="$(mktemp -d)"

# 功能：把测试编译产物移入当前用户废纸篓。
# 参数：无；使用 TEST_OUTPUT_DIR。
# 返回行为：回收失败时仅报告错误，不覆盖原测试退出码。
recycle_test_output() {
  swift -e '
    import Foundation
    var recycled_url: NSURL?
    try FileManager.default.trashItem(
      at: URL(fileURLWithPath: CommandLine.arguments[1]),
      resultingItemURL: &recycled_url)
  ' "$TEST_OUTPUT_DIR" || echo "测试编译产物回收失败" >&2
}
trap recycle_test_output EXIT

GATEWAY_SOURCES=(
  Sources/AnthropicProtocol.swift
  Sources/Config.swift
  Sources/Engine.swift
  Sources/Models.swift
  Sources/Prompt.swift
  Sources/ToolCalling.swift
  Sources/Util.swift
  Sources/gateway-protocol.swift
  Sources/gateway-pipeline.swift
)

# 功能：编译并执行一组 Swift 测试。
# 首参数：测试名称，用作临时可执行文件名。
# 其余参数：原样传递给 swiftc 的源文件和编译参数。
# 返回行为：编译或测试失败时返回相应的非零状态；成功时返回零。
run_test() {
  local test_name="$1"
  shift
  swiftc "$@" -o "$TEST_OUTPUT_DIR/$test_name"
  "$TEST_OUTPUT_DIR/$test_name"
}

run_test stream-routing-tests \
  "${GATEWAY_SOURCES[@]}" \
  Tests/StreamRoutingTests.swift \
  -framework CryptoKit

run_test http-server-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/http-server-gemini.swift \
  Sources/http-server-responses.swift \
  Tests/HTTPServerIntegrationTests.swift \
  -framework Network \
  -framework CryptoKit

run_test responses-protocol-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/http-server-gemini.swift \
  Sources/http-server-responses.swift \
  Tests/responses-protocol-tests.swift \
  -framework Network \
  -framework CryptoKit

run_test gemini-protocol-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/http-server-gemini.swift \
  Sources/http-server-responses.swift \
  Tests/gemini-protocol-tests.swift \
  -framework Network \
  -framework CryptoKit

run_test gateway-protocol-tests \
  "${GATEWAY_SOURCES[@]}" \
  Tests/gateway-protocol-tests.swift \
  -framework CryptoKit

run_test gateway-pipeline-tests \
  "${GATEWAY_SOURCES[@]}" \
  Tests/gateway-pipeline-tests.swift \
  -framework CryptoKit

run_test config-migration-tests \
  Sources/Config.swift \
  Tests/config-migration-tests.swift

run_test cli-command-tests \
  Sources/Models.swift \
  Sources/cli/cli-command.swift \
  Tests/cli-command-tests.swift

run_test runtime-state-tests \
  Sources/Models.swift \
  Sources/cli/cli-command.swift \
  Sources/cli/runtime-state.swift \
  Tests/runtime-state-tests.swift

run_test daemon-logger-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/cli/daemon-logger.swift \
  Tests/daemon-logger-tests.swift \
  -framework CryptoKit

run_test gateway-runtime-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/http-server-gemini.swift \
  Sources/http-server-responses.swift \
  Sources/gateway-runtime.swift \
  Tests/gateway-runtime-tests.swift \
  -framework Network \
  -framework CryptoKit

run_test daemon-controller-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/http-server-gemini.swift \
  Sources/http-server-responses.swift \
  Sources/gateway-runtime.swift \
  Sources/cli/cli-command.swift \
  Sources/cli/runtime-state.swift \
  Sources/cli/daemon-logger.swift \
  Sources/cli/daemon-controller.swift \
  Tests/daemon-controller-tests.swift \
  -framework Network \
  -framework CryptoKit

run_test cli-main-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/http-server-gemini.swift \
  Sources/http-server-responses.swift \
  Sources/gateway-runtime.swift \
  Sources/cli/cli-command.swift \
  Sources/cli/runtime-state.swift \
  Sources/cli/daemon-logger.swift \
  Sources/cli/daemon-controller.swift \
  Sources/cli/cli-main.swift \
  Tests/cli-main-tests.swift \
  -D GEMINI2API_LIBRARY \
  -framework Network \
  -framework CryptoKit

bash -n Tests/build-artifact-tests.sh
bash Tests/release-script-tests.sh
bash Tests/cli-integration-tests.sh --auto
