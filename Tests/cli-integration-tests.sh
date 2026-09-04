#!/bin/bash
# 用途：编译隔离 CLI helper，并验证前台、daemon、身份与进程边界。
# 使用方法：bash Tests/cli-integration-tests.sh [--auto]
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--auto") ]]; then
  echo "用法：bash Tests/cli-integration-tests.sh [--auto]" >&2
  exit 2
fi

# 功能：判断 Python candidate 是否包含当前 host 架构且能快速运行 Python 3。
# 参数：首参数为 candidate 路径，次参数为 uname 返回的 host 架构。
# 返回行为：架构匹配且无副作用探测成功时返回零，否则返回一。
python_candidate_is_usable() {
  local candidate="$1"
  local host_arch="$2"
  local file_description
  [[ -x "$candidate" ]] || return 1
  file_description="$(file -L -b "$candidate" 2>/dev/null)" || return 1
  [[ "$file_description" == *"Mach-O"* ]] || return 1
  [[ "$file_description" == *"$host_arch"* ]] || return 1
  "$candidate" -c \
    'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' \
    </dev/null >/dev/null 2>&1
}

# 功能：优先解析 Command Line Tools Python，再检查 PATH 中的兼容 candidate。
# 参数：无。
# 返回行为：stdout 输出首个通过 host 架构和运行探测的路径；
# 无可用项时失败。
resolve_python_binary() {
  local host_arch
  local xcrun_candidate
  local path_entry
  local path_candidate
  local -a path_entries
  host_arch="$(uname -m)"
  xcrun_candidate="$(xcrun --find python3 2>/dev/null || true)"
  if [[ -n "$xcrun_candidate" ]] \
    && python_candidate_is_usable "$xcrun_candidate" "$host_arch"; then
    printf '%s\n' "$xcrun_candidate"
    return 0
  fi
  IFS=':' read -r -a path_entries <<<"$PATH"
  for path_entry in "${path_entries[@]}"; do
    [[ -n "$path_entry" ]] || path_entry="."
    path_candidate="$path_entry/python3"
    if python_candidate_is_usable "$path_candidate" "$host_arch"; then
      printf '%s\n' "$path_candidate"
      return 0
    fi
  done
  return 1
}

command -v curl >/dev/null
command -v file >/dev/null

test_root="$(mktemp -d)"
path_python_marker="$test_root/path-python-used.txt"
path_shim_directory="$test_root/path-shims"
mkdir -p "$path_shim_directory"
cat >"$path_shim_directory/python3" <<'BASH'
#!/bin/bash
printf '%s\n' "unexpected PATH python3" >"${GEMINI2API_PATH_PYTHON_MARKER:?}"
printf '%s\n' "PATH python3 shim was executed" >&2
exit 97
BASH
chmod 700 "$path_shim_directory/python3"
export GEMINI2API_PATH_PYTHON_MARKER="$path_python_marker"
export PATH="$path_shim_directory:$PATH"
if ! python_binary="$(resolve_python_binary)"; then
  echo "找不到与当前 host 架构兼容的 Python 3" >&2
  exit 1
fi
[[ "$python_binary" != "$path_shim_directory/python3" ]]

helper_source="$test_root/cli-integration-main.swift"
cli_binary="$test_root/gemini2api-cli-tests"
pid_file="$test_root/helper-pids.txt"
pending_pid_file="$test_root/pending-helper-pids.txt"
touch "$pid_file"
touch "$pending_pid_file"
cli_binary_identity=""

# 功能：通过测试 helper 读取 PID 的 executable path 与启动时间。
# 参数：首参数为正整数 PID。
# 返回行为：stdout 输出 tab 分隔身份；进程不存在或 helper 未就绪时失败。
inspect_pid_identity() {
  local helper_pid="$1"
  [[ -x "$cli_binary" ]] || return 1
  GEMINI2API_TEST_ROOT="$test_root" \
    "$cli_binary" --test-inspect-pid "$helper_pid" 2>/dev/null
}

# 功能：在第一个可失败断言前记录 helper PID 及不可变身份。
# 参数：首参数为正整数 PID。
# 返回行为：活进程记录身份；已退出进程无需清理，均返回零。
record_pid() {
  local helper_pid="$1"
  local identity
  local attempt
  [[ "$helper_pid" =~ ^[1-9][0-9]*$ ]]
  printf '%s\n' "$helper_pid" >>"$pending_pid_file"
  identity=""
  for attempt in {1..20}; do
    identity="$(inspect_pid_identity "$helper_pid" || true)"
    [[ -n "$identity" ]] && break
    kill -0 "$helper_pid" 2>/dev/null || return 0
    sleep 0.01
  done
  [[ -n "$identity" ]] || return 0
  printf '%s\t%s\n' "$helper_pid" "$identity" >>"$pid_file"
}

# 功能：在 trap 中重试登记所有已知 PID 的完整身份。
# 参数：无；读取 pending_pid_file。
# 返回行为：已退出 PID 忽略，仍存活且可查询的 PID 写入身份文件。
register_pending_pids() {
  local helper_pid
  local identity
  local current_path
  local current_started_at
  local candidate_command
  local candidate_program
  local candidate_identity
  [[ -f "$pending_pid_file" ]] || return 0
  [[ -n "$cli_binary_identity" ]] || return 0
  while IFS= read -r helper_pid; do
    [[ "$helper_pid" =~ ^[1-9][0-9]*$ ]] || continue
    identity="$(inspect_pid_identity "$helper_pid" || true)"
    [[ -n "$identity" ]] || continue
    IFS=$'\t' read -r current_path current_started_at <<<"$identity"
    [[ "$current_path" == "$cli_binary_identity" ]] || continue
    candidate_command="$(ps -p "$helper_pid" -o command= 2>/dev/null || true)"
    candidate_program="${candidate_command%% *}"
    candidate_identity="$("$python_binary" - "$candidate_program" <<'PYTHON' 2>/dev/null || true
import os
import sys
print(os.path.realpath(sys.argv[1]))
PYTHON
)"
    [[ "$candidate_identity" == "$cli_binary_identity" ]] || continue
    case "$candidate_command" in
      *" --gemini2api-internal-daemon-child "*|*" serve "*) ;;
      *) continue ;;
    esac
    printf '%s\t%s\t%s\n' \
      "$helper_pid" "$current_path" "$current_started_at" >>"$pid_file"
  done < <(sort -u "$pending_pid_file")
}

# 功能：比较 PID 当前身份与登记时的 executable path、启动时间。
# 参数：PID、期望 executable path、期望启动时间。
# 返回行为：完整身份一致返回零，消失、复用或查询失败返回一。
pid_identity_matches() {
  local helper_pid="$1"
  local expected_path="$2"
  local expected_started_at="$3"
  local current_identity
  current_identity="$(inspect_pid_identity "$helper_pid" || true)"
  [[ "$current_identity" == "$expected_path"$'\t'"$expected_started_at" ]]
}

# 功能：从隔离 state 文件补登记 daemon PID，覆盖 parent 返回后的失败窗口。
# 参数：无；只读取固定隔离 state 文件。
# 返回行为：无 state 或无效 JSON 时保持成功。
register_state_pid() {
  local state_path="$test_root/support/Gemini2API/runtime/daemon.json"
  local state_identity
  local state_pid
  local state_executable_path
  local state_started_at
  [[ -f "$state_path" ]] || return 0
  state_identity="$("$python_binary" - "$state_path" <<'PYTHON' 2>/dev/null || true
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
pid = state.get("pid")
executable_path = state.get("executable_path")
started_at = state.get("process_started_at")
if (
    type(pid) is not int
    or pid <= 0
    or not isinstance(executable_path, str)
    or not executable_path
    or type(started_at) is not int
    or started_at <= 0
):
    raise SystemExit(1)
print(f"{pid}\t{executable_path}\t{started_at}")
PYTHON
)"
  [[ -n "$state_identity" ]] || return 0
  IFS=$'\t' read -r \
    state_pid state_executable_path state_started_at <<<"$state_identity"
  pid_identity_matches \
    "$state_pid" "$state_executable_path" "$state_started_at" || return 0
  printf '%s\t%s\t%s\n' \
    "$state_pid" "$state_executable_path" "$state_started_at" >>"$pid_file"
}

# 功能：发现并验证唯一测试 binary 的精确 hidden child invocation。
# 参数：无；使用 canonical cli_binary_identity。
# 返回行为：只登记 executable 与 command identity 均匹配的 child。
register_hidden_children() {
  local candidate_pid
  local candidate_command
  local candidate_program
  local candidate_program_identity
  local identity_before
  local identity_after
  local current_path
  local current_started_at
  [[ -n "$cli_binary_identity" ]] || return 0
  while IFS= read -r candidate_pid; do
    [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] || continue
    identity_before="$(inspect_pid_identity "$candidate_pid" || true)"
    [[ -n "$identity_before" ]] || continue
    IFS=$'\t' read -r current_path current_started_at <<<"$identity_before"
    [[ "$current_path" == "$cli_binary_identity" ]] || continue
    candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
    [[ "$candidate_command" == *" --gemini2api-internal-daemon-child "* ]] \
      || continue
    candidate_program="${candidate_command%% *}"
    candidate_program_identity="$(
      "$python_binary" - "$candidate_program" <<'PYTHON' 2>/dev/null || true
import os
import sys
print(os.path.realpath(sys.argv[1]))
PYTHON
)"
    [[ "$candidate_program_identity" == "$cli_binary_identity" ]] || continue
    identity_after="$(inspect_pid_identity "$candidate_pid" || true)"
    [[ "$identity_after" == "$identity_before" ]] || continue
    printf '%s\t%s\t%s\n' \
      "$candidate_pid" "$current_path" "$current_started_at" >>"$pid_file"
  done < <(pgrep -f \
    "$cli_binary_identity --gemini2api-internal-daemon-child" || true)
}

# 功能：向仍为登记身份的精确 PID 发送 TERM，并有界等待身份消失。
# 参数：无；读取 pid_file 的 PID、executable path 与启动时间。
# 返回行为：始终完成全部候选，不使用 SIGKILL。
terminate_registered_helpers() {
  local helper_pid
  local expected_path
  local expected_started_at
  local attempt
  [[ -f "$pid_file" ]] || return 0
  while IFS=$'\t' read -r helper_pid expected_path expected_started_at; do
    if pid_identity_matches "$helper_pid" "$expected_path" "$expected_started_at"; then
      kill -TERM "$helper_pid" 2>/dev/null || true
    fi
  done < <(sort -u "$pid_file")
  while IFS=$'\t' read -r helper_pid expected_path expected_started_at; do
    for attempt in {1..100}; do
      pid_identity_matches "$helper_pid" "$expected_path" "$expected_started_at" \
        || break
      sleep 0.05
    done
  done < <(sort -u "$pid_file")
}

# 功能：补登记 state/hidden child，两轮终止并有界等待后回收测试根。
# 参数：无；仅作用于当前 mktemp 根与已验证 PID。
# 返回行为：不覆盖原测试退出码。
cleanup() {
  register_pending_pids || true
  register_state_pid || true
  register_hidden_children || true
  terminate_registered_helpers || true
  register_pending_pids || true
  register_state_pid || true
  register_hidden_children || true
  terminate_registered_helpers || true
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
import Dispatch
import Foundation

private let TEST_ROOT_ENVIRONMENT = "GEMINI2API_TEST_ROOT"
private let TEST_DAEMON_MODE_ENVIRONMENT = "GEMINI2API_TEST_DAEMON_MODE"
private let TEST_FOREGROUND_FAILURE_ENVIRONMENT =
    "GEMINI2API_TEST_FOREGROUND_FAILURE"
private let GENERATOR_RESOLUTION_MARKER = "generator-resolution.txt"

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
    return CLIApplication(
        store: store,
        generator_factory: {
            let resolution = store.apiKeys == ["integration-key"]
                ? "store-loaded"
                : "store-not-loaded"
            let marker = root.appendingPathComponent(GENERATOR_RESOLUTION_MARKER)
            try? Data(resolution.utf8).write(to: marker)
            return CLIFakeGenerator()
        },
        controller_factory: { loaded_store, _ in
            make_cli_daemon_controller(
                store: loaded_store,
                paths: paths,
                child_environment: child_environment,
                trash_item: recycle_test_item)
        },
        runtime_factory: { loaded_store, generator in
            let server = HTTPServer(generator: generator, config: loaded_store)
            let runtime = GatewayRuntime(
                store: loaded_store,
                generator: generator,
                server: server)
            if ProcessInfo.processInfo.environment[
                TEST_FOREGROUND_FAILURE_ENVIRONMENT] == "1" {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    server.state_did_fail?(POSIXError(.ECONNABORTED))
                }
            }
            return runtime
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
        if arguments.first == "--test-inspect-pid", arguments.count == 2,
           let pid = Int32(arguments[1]),
           let identity = try? DarwinProcessInspector().inspect(pid: pid) {
            write_cli_output(
                "\(identity.executable_path)\t\(identity.process_started_at)")
            Darwin.exit(CLIExitCode.success.rawValue)
        }
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
cli_binary_identity="$("$python_binary" - "$cli_binary" <<'PYTHON'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PYTHON
)"

# 功能：生成当前未占用的随机 loopback 端口。
# 参数：无。
# 返回行为：stdout 输出端口。
random_port() {
  "$python_binary" - <<'PYTHON'
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

# 功能：断言当前公开命令尚未请求 generator factory。
# 参数：无；读取 generator_marker。
# 返回行为：被提前解析时输出明确 RED 原因并失败。
assert_generator_not_resolved() {
  if [[ -e "$generator_marker" ]]; then
    echo "generator resolved before Store.load or without runtime command" >&2
    return 1
  fi
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
  daemon_pid="$("$python_binary" - "$state_path" <<'PYTHON'
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
generator_marker="$test_root/generator-resolution.txt"
assert_generator_not_resolved
[[ "$(run_cli --help)" == "$expected_help" ]]
[[ "$(run_cli --version)" == "Gemini2API 0.2.0" ]]
! run_cli invalid-command >"$test_root/invalid.out" 2>"$test_root/invalid.err"
! run_cli --gemini2api-internal-daemon-child >"$test_root/internal.out" \
  2>"$test_root/internal.err"
[[ ! "$expected_help" =~ gemini2api-internal-daemon-child ]]
assert_generator_not_resolved

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

for invalid_config_case in host port model; do
  "$python_binary" - "$config_directory/config.json" "$invalid_config_case" <<'PYTHON'
import json
import sys

config = {
    "host": "127.0.0.1",
    "port": 18081,
    "default_model": "gemini-3.6-flash",
    "log_requests": False,
    "api_keys": ["integration-key"],
}
case = sys.argv[2]
if case == "host":
    config["host"] = "invalid host"
elif case == "port":
    config["port"] = 0
else:
    config["default_model"] = "unknown-model"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(config, handle)
PYTHON
  chmod 600 "$config_directory/config.json"
  set +e
  run_cli status >"$test_root/status-invalid-$invalid_config_case.out" \
    2>"$test_root/status-invalid-$invalid_config_case.err"
  invalid_status_code=$?
  set -e
  if [[ "$invalid_status_code" != "2" ]]; then
    echo "invalid status $invalid_config_case exit=$invalid_status_code, want=2" >&2
    exit 1
  fi
  [[ ! -s "$test_root/status-invalid-$invalid_config_case.out" ]]
  [[ "$(<"$test_root/status-invalid-$invalid_config_case.err")" == *"配置错误"* ]]
done
if [[ -e "$generator_marker" ]]; then
  mv "$generator_marker" "$test_root/status-generator-resolution.txt"
fi

"$python_binary" - "$config_directory/config.json" <<'PYTHON'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "host": "127.0.0.1",
        "port": 18081,
        "default_model": "gemini-3.6-flash",
        "log_requests": False,
        "api_keys": ["integration-key"],
    }, handle)
PYTHON
chmod 600 "$config_directory/config.json"

if [[ -n ${GEMINI2API_TEST_STATE_CLEANUP_MODE:-} ]]; then
  state_cleanup_mode="$GEMINI2API_TEST_STATE_CLEANUP_MODE"
  state_cleanup_pid="${GEMINI2API_TEST_STATE_CLEANUP_PID:?}"
  state_cleanup_path="${GEMINI2API_TEST_STATE_CLEANUP_PATH:?}"
  state_cleanup_started_at="${GEMINI2API_TEST_STATE_CLEANUP_STARTED_AT:?}"
  state_cleanup_file="$test_root/support/Gemini2API/runtime/daemon.json"
  mkdir -p "$(dirname "$state_cleanup_file")"
  "$python_binary" - \
    "$state_cleanup_mode" \
    "$state_cleanup_pid" \
    "$state_cleanup_path" \
    "$state_cleanup_started_at" \
    "$state_cleanup_file" <<'PYTHON'
import json
import sys

mode, pid, executable_path, started_at, output_path = sys.argv[1:]
state_pid = 2147483647 if mode == "stale" else int(pid)
state_path = executable_path + ".forged" if mode == "forged" else executable_path
state_started_at = int(started_at) + 1 if mode == "reused" else int(started_at)
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump({
        "pid": state_pid,
        "executable_path": state_path,
        "process_started_at": state_started_at,
    }, handle)
PYTHON
  chmod 600 "$state_cleanup_file"
  false
fi

if [[ ${GEMINI2API_TEST_EARLY_FAILURE:-} == "1" ]]; then
  early_failure_manifest="${GEMINI2API_TEST_EARLY_FAILURE_MANIFEST:?}"
  early_failure_port="$(random_port)"
  printf '%s\t%s\t%s\n' \
    "$test_root" \
    "$cli_binary_identity" \
    "$test_root/support/Gemini2API/runtime/daemon.json" \
    >"$early_failure_manifest"
  run_cli serve --host 127.0.0.1 --port "$early_failure_port" --daemon
  false
fi

# 功能：证明 trap 不会信任 stale、复用或伪造 state 中的裸 PID。
# 参数：首参数为 state 情形：stale、reused 或 forged。
# 返回行为：嵌套失败清理未向无关 owner 发送 TERM 时成功。
run_state_cleanup_identity_probe() {
  local cleanup_mode="$1"
  local term_marker="$test_root/state-cleanup-$cleanup_mode-term.txt"
  local ready_marker="$test_root/state-cleanup-$cleanup_mode-ready.txt"
  local sentinel_pid
  local sentinel_identity
  local sentinel_path
  local sentinel_started_at
  local probe_code
  "$python_binary" - "$term_marker" "$ready_marker" <<'PYTHON' &
import pathlib
import signal
import sys
import time

term_path = pathlib.Path(sys.argv[1])
ready_path = pathlib.Path(sys.argv[2])

def handle_term(_signal_number, _frame):
    term_path.write_text("TERM\n", encoding="utf-8")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, handle_term)
ready_path.write_text("ready\n", encoding="utf-8")
while True:
    time.sleep(1)
PYTHON
  sentinel_pid=$!
  record_pid "$sentinel_pid"
  for _ in {1..100}; do
    [[ -e "$ready_marker" ]] && break
    sleep 0.01
  done
  [[ -e "$ready_marker" ]]
  sentinel_identity="$(inspect_pid_identity "$sentinel_pid")"
  IFS=$'\t' read -r sentinel_path sentinel_started_at <<<"$sentinel_identity"
  set +e
  GEMINI2API_TEST_STATE_CLEANUP_MODE="$cleanup_mode" \
  GEMINI2API_TEST_STATE_CLEANUP_PID="$sentinel_pid" \
  GEMINI2API_TEST_STATE_CLEANUP_PATH="$sentinel_path" \
  GEMINI2API_TEST_STATE_CLEANUP_STARTED_AT="$sentinel_started_at" \
    bash Tests/cli-integration-tests.sh --auto \
    >"$test_root/state-cleanup-$cleanup_mode.out" \
    2>"$test_root/state-cleanup-$cleanup_mode.err"
  probe_code=$?
  set -e
  [[ "$probe_code" != "0" ]]
  if [[ -e "$term_marker" ]] || ! kill -0 "$sentinel_pid" 2>/dev/null; then
    echo "cleanup trusted $cleanup_mode state without saved identity" >&2
    return 1
  fi
  kill -TERM "$sentinel_pid"
  wait "$sentinel_pid"
}

for state_cleanup_case in forged reused stale; do
  run_state_cleanup_identity_probe "$state_cleanup_case"
done

cleanup_probe_manifest="$test_root/cleanup-probe-manifest.txt"
set +e
GEMINI2API_TEST_EARLY_FAILURE=1 \
GEMINI2API_TEST_EARLY_FAILURE_MANIFEST="$cleanup_probe_manifest" \
  bash Tests/cli-integration-tests.sh --auto \
  >"$test_root/cleanup-probe.out" 2>"$test_root/cleanup-probe.err"
cleanup_probe_code=$?
set -e
[[ "$cleanup_probe_code" != "0" ]]
IFS=$'\t' read -r cleanup_probe_root cleanup_probe_binary cleanup_probe_state \
  <"$cleanup_probe_manifest"
[[ ! -e "$cleanup_probe_root" ]]
[[ ! -e "$cleanup_probe_state" ]]
! pgrep -f \
  "$cleanup_probe_binary --gemini2api-internal-daemon-child" >/dev/null
assert_generator_not_resolved

for signal_name in INT TERM; do
  foreground_port="$(random_port)"
  GEMINI2API_TEST_ROOT="$test_root" \
    "$cli_binary" serve --host 127.0.0.1 --port "$foreground_port" \
    >"$test_root/foreground-$signal_name.out" \
    2>"$test_root/foreground-$signal_name.err" &
  foreground_pid=$!
  record_pid "$foreground_pid"
  wait_for_http "$foreground_port"
  [[ "$(<"$generator_marker")" == "store-loaded" ]]
  [[ "$(curl -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$foreground_port/")" == "200" ]]
  kill -"$signal_name" "$foreground_pid"
  wait "$foreground_pid"
  [[ ! -e "$test_root/support/Gemini2API/runtime/daemon.json" ]]
done

foreground_failure_port="$(random_port)"
set +e
GEMINI2API_TEST_ROOT="$test_root" \
GEMINI2API_TEST_FOREGROUND_FAILURE=1 \
  "$cli_binary" serve --host 127.0.0.1 --port "$foreground_failure_port" \
  >"$test_root/foreground-failure.out" \
  2>"$test_root/foreground-failure.err"
foreground_failure_code=$?
set -e
[[ "$foreground_failure_code" == "5" ]]
[[ ! -e "$test_root/support/Gemini2API/runtime/daemon.json" ]]

daemon_port="$(random_port)"
run_cli serve --host 127.0.0.1 --port "$daemon_port" --daemon
daemon_pid="$(record_daemon_pid)"
[[ "$(<"$generator_marker")" == "store-loaded" ]]
kill -0 "$daemon_pid"
wait_for_http "$daemon_port"
[[ "$(run_cli status)" == *"running"* ]]
status_json="$(run_cli status --json)"
"$python_binary" - "$status_json" "$daemon_pid" "$daemon_port" <<'PYTHON'
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
"$python_binary" -m http.server "$owner_port" --bind 127.0.0.1 \
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
"$python_binary" -c \
  'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(1)' &
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
register_hidden_children
[[ "$readiness_code" == "5" ]]
sleep 2.5
[[ ! -e "$state_directory/daemon.json" ]]

multithread_port="$(random_port)"
run_cli --test-multithread-daemon "$multithread_port"
multithread_daemon_pid="$(record_daemon_pid)"
wait_for_http "$multithread_port"
run_cli stop --timeout 3
! kill -0 "$multithread_daemon_pid" 2>/dev/null

while IFS=$'\t' read -r recorded_pid recorded_path recorded_started_at; do
  ! pid_identity_matches "$recorded_pid" "$recorded_path" "$recorded_started_at"
done <"$pid_file"
[[ ! -e "$state_directory/daemon.json" ]]
! find "$state_directory" -name '*.staging' -print -quit | grep -q .
! pgrep -f "$cli_binary" >/dev/null
[[ ! -e "$path_python_marker" ]]

echo "cli-integration-tests passed"
