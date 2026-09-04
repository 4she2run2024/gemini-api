#!/bin/bash
# 用途：编译隔离 CLI helper，并验证前台、daemon、身份与进程边界。
# 使用方法：bash Tests/cli-integration-tests.sh [--auto]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--auto") ]]; then
  echo "用法：bash Tests/cli-integration-tests.sh [--auto]" >&2
  exit 2
fi

command -v python3 >/dev/null
command -v curl >/dev/null

test_root="$(mktemp -d)"
helper_source="$test_root/cli-integration-main.swift"
cli_binary="$test_root/gemini2api-cli-tests"
pid_file="$test_root/helper-pids.txt"
touch "$pid_file"

# 功能：记录需要在 trap 中精确清理的 helper PID。
# 参数：首参数为正整数 PID。
# 返回行为：记录成功返回零，无效 PID 使测试失败。
record_pid() {
  local helper_pid="$1"
  [[ "$helper_pid" =~ ^[1-9][0-9]*$ ]]
  echo "$helper_pid" >>"$pid_file"
}

# 功能：只向已记录且仍存活的 helper 发送 TERM，并回收测试根。
# 参数：无；读取 pid_file 和 test_root。
# 返回行为：不覆盖原测试退出码。
cleanup() {
  local helper_pid
  if [[ -f "$pid_file" ]]; then
    while IFS= read -r helper_pid; do
      if [[ "$helper_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$helper_pid" 2>/dev/null; then
        kill -TERM "$helper_pid" 2>/dev/null || true
      fi
    done <"$pid_file"
  fi
  if [[ -d "$test_root" ]]; then
    swift -e '
      import Foundation
      var recycled_url: NSURL?
      try FileManager.default.trashItem(
        at: URL(fileURLWithPath: CommandLine.arguments[1]),
        resultingItemURL: &recycled_url)
    ' "$test_root" || echo "CLI 集成测试目录回收失败" >&2
  fi
}
trap cleanup EXIT

cat >"$helper_source" <<'SWIFT'
// 用途：为 CLI 端到端测试注入隔离路径和固定文本生成器。
// 使用方法：由 cli-integration-tests.sh 与 production CLI 源码共同编译。

import Darwin
import Foundation

private let TEST_ROOT_ENVIRONMENT = "GEMINI2API_TEST_ROOT"
private let TEST_DAEMON_MODE_ENVIRONMENT = "GEMINI2API_TEST_DAEMON_MODE"

private final class CLIFakeGenerator: TextGenerating {
    // 功能：返回固定文本，证明 HTTP request 到达真实 Gateway 管线。
    // 参数：request 为已经过协议层解析的生成请求。
    // 返回值：固定可断言文本。
    func generate(_ request: GenerationRequest) throws -> String {
        "CLI integration response"
    }

    // 功能：返回固定流式文本。
    // 参数：request 为请求；isCancelled 判断取消；onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        if !isCancelled() { onDelta("CLI integration response") }
    }
}

// 功能：把测试期受管文件移入当前用户废纸篓。
// 参数：url 为待回收文件。
// 返回值：无；回收失败时抛出原始错误。
private func recycle_test_item(_ url: URL) throws {
    var recycled_url: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &recycled_url)
}

// 功能：由隔离测试总目录构造配置与 runtime 路径。
// 参数：root 为动态创建的测试根。
// 返回值：Store 和 RuntimePaths。
private func make_test_dependencies(root: URL) -> (Store, RuntimePaths) {
    let store = Store(config_root: root.appendingPathComponent("config"))
    let paths = RuntimePaths(
        application_support_directory: root.appendingPathComponent("support"),
        logs_directory: root.appendingPathComponent("logs"))
    return (store, paths)
}

// 功能：从 exec child 接管的 lock fd 反查隔离测试根。
// 参数：descriptor 为隐藏 invocation 中的 lock fd。
// 返回值：路径符合测试布局时返回测试根，否则为 nil。
private func test_root_from_lock(descriptor: Int32) -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
    let lock_url = URL(fileURLWithPath: String(cString: buffer))
    let root = lock_url
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let expected_lock = make_test_dependencies(root: root).1.lock_path
    return expected_lock.standardizedFileURL == lock_url.standardizedFileURL ? root : nil
}

// 功能：构造和 production 相同 API 的 CLIApplication 与 DaemonController。
// 参数：root 为测试根；child_environment 为严格白名单测试模式。
// 返回值：已注入 fake generator 的应用。
private func make_test_application(
    root: URL,
    child_environment: [String: String] = [:]
) -> CLIApplication {
    let (store, paths) = make_test_dependencies(root: root)
    let generator = CLIFakeGenerator()
    return CLIApplication(
        store: store,
        generator: generator,
        controller_factory: { loaded_store, _ in
            make_cli_daemon_controller(
                store: loaded_store,
                paths: paths,
                child_environment: child_environment,
                trash_item: recycle_test_item)
        })
}

// 功能：在新 exec child 中恢复隔离 Store 后调用共享 child runner。
// 参数：invocation 为已校验隐藏参数；root 从受管 lock fd 反查。
// 返回值：不返回。
private func run_test_daemon_child(
    invocation: DaemonChildInvocation,
    root: URL
) -> Never {
    let (store, paths) = make_test_dependencies(root: root)
    store.load()
    let child_mode = ProcessInfo.processInfo.environment[TEST_DAEMON_MODE_ENVIRONMENT]
    let logger_factory: (() throws -> DaemonLogger)?
    if child_mode == "readiness_timeout" {
        logger_factory = {
            _ = Darwin.signal(SIGTERM, SIG_IGN)
            Thread.sleep(forTimeInterval: 12)
            return DaemonLogger(log_url: paths.log_path, trash_item: recycle_test_item)
        }
    } else {
        logger_factory = nil
    }
    run_cli_daemon_child(
        invocation: invocation,
        store: store,
        generator: CLIFakeGenerator(),
        paths: paths,
        process_inspector: DarwinProcessInspector(),
        trash_item: recycle_test_item,
        logger_factory: logger_factory)
}

// 功能：为 timeout 测试发布与真实 PID 身份完全匹配的受管状态。
// 参数：root、pid、host、port 来自 helper 参数。
// 返回值：发布成功返回零，否则返回 runtime。
private func publish_test_state(
    root: URL,
    pid: Int32,
    host: String,
    port: Int
) -> CLIExitCode {
    let paths = make_test_dependencies(root: root).1
    let inspector = DarwinProcessInspector()
    guard let identity = try? inspector.inspect(pid: pid) else {
        return .runtime
    }
    let state_store = RuntimeStateStore(
        paths: paths,
        process_inspector: inspector,
        trash_item: recycle_test_item)
    let state = DaemonState(
        pid: pid,
        executable_path: identity.executable_path,
        process_started_at: identity.process_started_at,
        instance_id: UUID().uuidString,
        host: host,
        port: port,
        version: GEMINI2API_VERSION)
    do {
        try state_store.publish(state)
        return .success
    } catch {
        return .runtime
    }
}

@main
struct CLIIntegrationMain {
    // 功能：先处理隐藏 child，再处理受控测试 helper 或公开 CLI。
    // 参数：无；读取 CommandLine.arguments。
    // 返回值：通过 exit code 结束，daemon child 不返回。
    static func main() {
        switch DaemonChildInvocation.parse(arguments: CommandLine.arguments) {
        case .invocation(let invocation):
            guard let root = test_root_from_lock(
                descriptor: invocation.lock_descriptor) else {
                Darwin.exit(CLIExitCode.usage.rawValue)
            }
            run_test_daemon_child(invocation: invocation, root: root)
        case .invalid:
            write_cli_error(cli_usage())
            Darwin.exit(CLIExitCode.usage.rawValue)
        case .not_internal:
            break
        }

        guard let root_path = getenv(TEST_ROOT_ENVIRONMENT) else {
            Darwin.exit(CLIExitCode.usage.rawValue)
        }
        let root = URL(fileURLWithPath: String(cString: root_path), isDirectory: true)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--test-publish-state", arguments.count == 4,
           let pid = Int32(arguments[1]), let port = Int(arguments[3]) {
            Darwin.exit(publish_test_state(
                root: root,
                pid: pid,
                host: arguments[2],
                port: port).rawValue)
        }

        let child_mode = ProcessInfo.processInfo.environment[TEST_DAEMON_MODE_ENVIRONMENT]
        let child_environment = child_mode.map {
            [TEST_DAEMON_MODE_ENVIRONMENT: $0]
        } ?? [:]
        let application = make_test_application(
            root: root,
            child_environment: child_environment)
        if arguments.first == "--test-multithread-daemon", arguments.count == 2,
           let port = Int(arguments[1]) {
            let release_thread = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                started.signal()
                _ = release_thread.wait(timeout: .now() + 20)
            }
            _ = started.wait(timeout: .now() + 2)
            let exit_code = application.run(arguments: [
                "serve", "--host", "127.0.0.1", "--port", String(port), "--daemon",
            ])
            release_thread.signal()
            Darwin.exit(exit_code.rawValue)
        }
        Darwin.exit(application.run(arguments: arguments).rawValue)
    }
}
SWIFT

gateway_sources=(
  Sources/AnthropicProtocol.swift
  Sources/Config.swift
  Sources/Engine.swift
  Sources/Models.swift
  Sources/Prompt.swift
  Sources/ToolCalling.swift
  Sources/Util.swift
  Sources/gateway-protocol.swift
  Sources/gateway-pipeline.swift
  Sources/HTTPServer.swift
  Sources/HTTPServer+Anthropic.swift
  Sources/HTTPServer+OpenAI.swift
  Sources/http-server-gemini.swift
  Sources/http-server-responses.swift
  Sources/gateway-runtime.swift
  Sources/cli/cli-command.swift
  Sources/cli/runtime-state.swift
  Sources/cli/daemon-logger.swift
  Sources/cli/daemon-controller.swift
  Sources/cli/cli-main.swift
)

swiftc -D GEMINI2API_LIBRARY \
  "${gateway_sources[@]}" "$helper_source" \
  -framework Network -framework CryptoKit -o "$cli_binary"

# 功能：生成当前未占用的随机 loopback 端口。
# 参数：无。
# 返回行为：stdout 输出端口。
random_port() {
  python3 - <<'PYTHON'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PYTHON
}

# 功能：使用隔离测试根执行 CLI。
# 参数：其余参数原样传给 CLI binary。
# 返回行为：透传 CLI 退出码与输出。
run_cli() {
  GEMINI2API_TEST_ROOT="$test_root" "$cli_binary" "$@"
}

# 功能：等待根 endpoint 返回 HTTP 200。
# 参数：首参数为 port。
# 返回行为：五秒内 ready 返回零，否则返回一。
wait_for_http() {
  local port="$1"
  local attempt
  for attempt in {1..100}; do
    if [[ "$(curl -sS -o /dev/null -w '%{http_code}' \
      --max-time 0.2 "http://127.0.0.1:$port/" 2>/dev/null || true)" == "200" ]]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# 功能：读取并记录当前 daemon 状态中的精确 PID。
# 参数：无。
# 返回行为：stdout 输出 PID，状态无效时失败。
record_daemon_pid() {
  local state_path="$test_root/support/Gemini2API/runtime/daemon.json"
  local daemon_pid
  daemon_pid="$(python3 - "$state_path" <<'PYTHON'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["pid"])
PYTHON
)"
  record_pid "$daemon_pid"
  echo "$daemon_pid"
}

expected_help='gemini2api 0.2.0
用法：gemini2api <serve|status|stop|version|help> [选项]
  serve [--host HOST] [--port PORT] [--model MODEL] [--daemon]
  status [--json]
  stop [--timeout SECONDS]'
[[ "$(run_cli --help)" == "$expected_help" ]]
[[ "$(run_cli --version)" == "Gemini2API 0.2.0" ]]
! run_cli --gemini2api-internal-daemon-child >"$test_root/internal.out" \
  2>"$test_root/internal.err"
[[ ! "$expected_help" =~ gemini2api-internal-daemon-child ]]

config_directory="$test_root/config/.config/gemini2api"
mkdir -p "$config_directory"
cat >"$config_directory/config.json" <<'JSON'
{
  "host": "127.0.0.1",
  "port": 18081,
  "default_model": "gemini-3.6-flash",
  "log_requests": false,
  "api_keys": ["integration-key"]
}
JSON
chmod 600 "$config_directory/config.json"

for signal_name in INT TERM; do
  foreground_port="$(random_port)"
  GEMINI2API_TEST_ROOT="$test_root" \
    "$cli_binary" serve --host 127.0.0.1 --port "$foreground_port" \
    >"$test_root/foreground-$signal_name.out" \
    2>"$test_root/foreground-$signal_name.err" &
  foreground_pid=$!
  record_pid "$foreground_pid"
  wait_for_http "$foreground_port"
  [[ "$(curl -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$foreground_port/")" == "200" ]]
  kill -"$signal_name" "$foreground_pid"
  wait "$foreground_pid"
  [[ ! -e "$test_root/support/Gemini2API/runtime/daemon.json" ]]
done

daemon_port="$(random_port)"
run_cli serve --host 127.0.0.1 --port "$daemon_port" --daemon
daemon_pid="$(record_daemon_pid)"
kill -0 "$daemon_pid"
wait_for_http "$daemon_port"
[[ "$(run_cli status)" == *"running"* ]]
status_json="$(run_cli status --json)"
python3 - "$status_json" "$daemon_pid" "$daemon_port" <<'PYTHON'
import json
import sys
value = json.loads(sys.argv[1])
assert value == {
    "healthy": True,
    "host": "127.0.0.1",
    "managed": True,
    "pid": int(sys.argv[2]),
    "port": int(sys.argv[3]),
    "state": "running",
    "version": "0.2.0",
}
PYTHON
request_body='{"model":"gemini-3.6-flash","input":"ping"}'
[[ "$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "$request_body" "http://127.0.0.1:$daemon_port/v1/responses")" == "401" ]]
request_result="$(curl -sS \
  -H 'Authorization: Bearer integration-key' \
  -H 'Content-Type: application/json' \
  -d "$request_body" "http://127.0.0.1:$daemon_port/v1/responses")"
[[ "$request_result" == *"CLI integration response"* ]]
run_cli stop --timeout 3
! kill -0 "$daemon_pid" 2>/dev/null
[[ ! -e "$test_root/support/Gemini2API/runtime/daemon.json" ]]

concurrent_port="$(random_port)"
set +e
GEMINI2API_TEST_ROOT="$test_root" \
  "$cli_binary" serve --host 127.0.0.1 --port "$concurrent_port" --daemon \
  >"$test_root/concurrent-one.out" 2>"$test_root/concurrent-one.err" &
concurrent_one_pid=$!
record_pid "$concurrent_one_pid"
GEMINI2API_TEST_ROOT="$test_root" \
  "$cli_binary" serve --host 127.0.0.1 --port "$concurrent_port" --daemon \
  >"$test_root/concurrent-two.out" 2>"$test_root/concurrent-two.err" &
concurrent_two_pid=$!
record_pid "$concurrent_two_pid"
wait "$concurrent_one_pid"
concurrent_one_code=$?
wait "$concurrent_two_pid"
concurrent_two_code=$?
set -e
[[ "$concurrent_one_code $concurrent_two_code" == "0 4" \
  || "$concurrent_one_code $concurrent_two_code" == "4 0" ]]
concurrent_daemon_pid="$(record_daemon_pid)"
run_cli stop --timeout 3
! kill -0 "$concurrent_daemon_pid" 2>/dev/null

state_directory="$test_root/support/Gemini2API/runtime"
mkdir -p "$state_directory"
cat >"$state_directory/daemon.json" <<'JSON'
{"executable_path":"/missing/test-helper","host":"127.0.0.1",
"instance_id":"stale","pid":999999,"port":18082,
"process_started_at":1,"version":"0.2.0"}
JSON
chmod 600 "$state_directory/daemon.json"
stale_port="$(random_port)"
run_cli serve --host 127.0.0.1 --port "$stale_port" --daemon
stale_daemon_pid="$(record_daemon_pid)"
wait_for_http "$stale_port"
run_cli stop --timeout 3
! kill -0 "$stale_daemon_pid" 2>/dev/null

sleep 30 &
forged_owner_pid=$!
record_pid "$forged_owner_pid"
cat >"$state_directory/daemon.json" <<JSON
{"executable_path":"/forged/not-owner","host":"127.0.0.1",
"instance_id":"forged","pid":$forged_owner_pid,"port":18083,
"process_started_at":1,"version":"0.2.0"}
JSON
chmod 600 "$state_directory/daemon.json"
set +e
run_cli stop --timeout 0.1 >"$test_root/forged.out" 2>"$test_root/forged.err"
forged_code=$?
set -e
[[ "$forged_code" == "4" ]]
kill -0 "$forged_owner_pid"
kill -TERM "$forged_owner_pid"
wait "$forged_owner_pid" 2>/dev/null || true
swift -e '
  import Foundation
  var recycled_url: NSURL?
  try FileManager.default.trashItem(
    at: URL(fileURLWithPath: CommandLine.arguments[1]),
    resultingItemURL: &recycled_url)
' "$state_directory/daemon.json"

owner_port="$(random_port)"
python3 -m http.server "$owner_port" --bind 127.0.0.1 \
  >"$test_root/owner.out" 2>"$test_root/owner.err" &
port_owner_pid=$!
record_pid "$port_owner_pid"
wait_for_http "$owner_port"
set +e
run_cli serve --host 127.0.0.1 --port "$owner_port" --daemon \
  >"$test_root/owner-start.out" 2>"$test_root/owner-start.err"
owner_start_code=$?
set -e
[[ "$owner_start_code" == "4" ]]
kill -0 "$port_owner_pid"
[[ ! -e "$state_directory/daemon.json" ]]
kill -TERM "$port_owner_pid"
wait "$port_owner_pid" 2>/dev/null || true

timeout_port="$(random_port)"
python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(1)' &
timeout_owner_pid=$!
record_pid "$timeout_owner_pid"
sleep 0.1
run_cli --test-publish-state "$timeout_owner_pid" 127.0.0.1 "$timeout_port"
set +e
run_cli stop --timeout 0.1 >"$test_root/timeout-stop.out" 2>"$test_root/timeout-stop.err"
timeout_stop_code=$?
set -e
[[ "$timeout_stop_code" == "5" ]]
kill -0 "$timeout_owner_pid"
wait "$timeout_owner_pid"
swift -e '
  import Foundation
  var recycled_url: NSURL?
  try FileManager.default.trashItem(
    at: URL(fileURLWithPath: CommandLine.arguments[1]),
    resultingItemURL: &recycled_url)
' "$state_directory/daemon.json"

readiness_port="$(random_port)"
set +e
GEMINI2API_TEST_ROOT="$test_root" \
GEMINI2API_TEST_DAEMON_MODE=readiness_timeout \
  "$cli_binary" serve --host 127.0.0.1 --port "$readiness_port" --daemon \
  >"$test_root/readiness.out" 2>"$test_root/readiness.err"
readiness_code=$?
set -e
[[ "$readiness_code" == "5" ]]
readiness_child_pid="$(pgrep -f \
  "$cli_binary --gemini2api-internal-daemon-child" | head -1 || true)"
if [[ -n "$readiness_child_pid" ]]; then
  record_pid "$readiness_child_pid"
fi
sleep 2.5
[[ ! -e "$state_directory/daemon.json" ]]

multithread_port="$(random_port)"
run_cli --test-multithread-daemon "$multithread_port"
multithread_daemon_pid="$(record_daemon_pid)"
wait_for_http "$multithread_port"
run_cli stop --timeout 3
! kill -0 "$multithread_daemon_pid" 2>/dev/null

while IFS= read -r recorded_pid; do
  ! kill -0 "$recorded_pid" 2>/dev/null
done <"$pid_file"
[[ ! -e "$state_directory/daemon.json" ]]
! find "$state_directory" -name '*.staging' -print -quit | grep -q .
! pgrep -f "$cli_binary" >/dev/null

echo "cli-integration-tests passed"
