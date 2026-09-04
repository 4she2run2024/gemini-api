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
  Sources/http-server-responses.swift \
  Tests/HTTPServerIntegrationTests.swift \
  -framework Network \
  -framework CryptoKit

run_test responses-protocol-tests \
  "${GATEWAY_SOURCES[@]}" \
  Sources/HTTPServer.swift \
  Sources/HTTPServer+Anthropic.swift \
  Sources/HTTPServer+OpenAI.swift \
  Sources/http-server-responses.swift \
  Tests/responses-protocol-tests.swift \
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
