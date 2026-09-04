// 用途：定义 Gemini2API 纯 CLI 命令、选项及参数解析契约。
// 使用方法：传入命令行参数数组调用 parse_cli_command 获取结构化命令。

import Foundation

let GEMINI2API_VERSION = "0.2.0"
private let CLI_RESERVED_OPTIONS: Set<String> = [
    "--host", "--port", "--model", "--daemon", "--timeout", "--json",
    "--help", "-h", "--version",
]

enum CLIExitCode: Int32 {
    case success = 0
    case usage = 2
    case stopped = 3
    case conflict = 4
    case runtime = 5
}

struct ServeOptions: Equatable {
    let host: String?
    let port: Int?
    let model: String?
    let daemon: Bool
}

enum CLICommand: Equatable {
    case serve(ServeOptions)
    case status(json: Bool)
    case stop(timeout: TimeInterval)
    case version
    case help
}

private enum CLIUsageError: Error, CustomStringConvertible {
    case invalid_arguments

    // 功能：返回不泄露用户参数值的 usage 错误描述。
    // 参数：无。
    // 返回值：固定的 usage 错误文本。
    var description: String {
        return "usage: invalid arguments"
    }
}

// 功能：抛出统一的 CLI usage 错误。
// 参数：无。
// 返回值：不会正常返回；始终抛出 CLIUsageError。
private func throw_usage_error() throws -> Never {
    throw CLIUsageError.invalid_arguments
}

// 功能：读取 valued option 的下一 token，并拒绝把保留 option 当作值。
// 参数：arguments 为完整参数；index 为当前 option 位置。
// 返回值：合法的下一 token；缺失或保留 token 时抛出 usage 错误。
private func cli_option_value(_ arguments: [String], index: Int) throws -> String {
    guard index + 1 < arguments.count else { try throw_usage_error() }
    let value = arguments[index + 1]
    guard !value.isEmpty, !CLI_RESERVED_OPTIONS.contains(value) else {
        try throw_usage_error()
    }
    return value
}

// 功能：依据现有 MODELS 和 think 范围校验模型选项。
// 参数：value 为待校验的模型标识。
// 返回值：模型存在且 think 合法时返回 true，否则返回 false。
private func valid_model(_ value: String) -> Bool {
    let components = value.split(separator: "@", maxSplits: 1,
                                 omittingEmptySubsequences: false)
    guard let model = MODELS.first(where: { $0.id == components[0] }) else {
        return false
    }
    guard components.count == 2 else {
        return true
    }
    let suffix = String(components[1])
    guard suffix.hasPrefix("think=") else {
        return false
    }
    guard let think = Int(suffix.dropFirst("think=".count)) else {
        return false
    }
    _ = model
    return (0...4).contains(think)
}

// 功能：解析纯 CLI 参数并构造结构化命令。
// 参数：arguments 为不含程序名的命令行参数数组。
// 返回值：成功时返回 CLICommand，参数不合法时抛出 usage 错误。
func parse_cli_command(_ arguments: [String]) throws -> CLICommand {
    guard let command = arguments.first else {
        try throw_usage_error()
    }
    if command == "--help" || command == "-h" {
        guard arguments.count == 1 else { try throw_usage_error() }
        return .help
    }
    if command == "--version" {
        guard arguments.count == 1 else { try throw_usage_error() }
        return .version
    }

    switch command {
    case "help":
        guard arguments.count == 1 else { try throw_usage_error() }
        return .help
    case "version":
        guard arguments.count == 1 else { try throw_usage_error() }
        return .version
    case "serve":
        var host: String?
        var port: Int?
        var model: String?
        var daemon = false
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--host":
                guard host == nil else { try throw_usage_error() }
                host = try cli_option_value(arguments, index: index)
                index += 2
            case "--port":
                guard port == nil else { try throw_usage_error() }
                let port_value = try cli_option_value(arguments, index: index)
                guard let parsed_port = Int(port_value),
                      (1...65535).contains(parsed_port) else {
                    try throw_usage_error()
                }
                port = parsed_port
                index += 2
            case "--model":
                guard model == nil else { try throw_usage_error() }
                let parsed_model = try cli_option_value(arguments, index: index)
                guard valid_model(parsed_model) else { try throw_usage_error() }
                model = parsed_model
                index += 2
            case "--daemon":
                guard !daemon else { try throw_usage_error() }
                daemon = true
                index += 1
            default:
                try throw_usage_error()
            }
        }
        return .serve(ServeOptions(host: host, port: port, model: model,
                                   daemon: daemon))
    case "status":
        guard arguments.count <= 2 else { try throw_usage_error() }
        if arguments.count == 2 && arguments[1] != "--json" {
            try throw_usage_error()
        }
        return .status(json: arguments.count == 2)
    case "stop":
        guard arguments.count == 1 || arguments.count == 3 else {
            try throw_usage_error()
        }
        if arguments.count == 1 { return .stop(timeout: 10) }
        guard arguments[1] == "--timeout" else { try throw_usage_error() }
        let timeout_value = try cli_option_value(arguments, index: 1)
        guard let timeout = TimeInterval(timeout_value), timeout > 0,
              timeout.isFinite else {
            try throw_usage_error()
        }
        return .stop(timeout: timeout)
    default:
        try throw_usage_error()
    }
}

// 功能：生成 CLI 帮助用法文本。
// 参数：无。
// 返回值：包含版本和命令选项的 usage 文本。
func cli_usage() -> String {
    return """
    gemini2api \(GEMINI2API_VERSION)
    用法：gemini2api <serve|status|stop|version|help> [选项]
      serve [--host HOST] [--port PORT] [--model MODEL] [--daemon]
      status [--json]
      stop [--timeout SECONDS]
    """
}
