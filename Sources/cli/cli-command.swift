import Foundation

let GEMINI2API_VERSION = "0.2.0"

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

    var description: String {
        return "usage: invalid arguments"
    }
}

private func throw_usage_error() throws -> Never {
    throw CLIUsageError.invalid_arguments
}

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
                guard host == nil, index + 1 < arguments.count else {
                    try throw_usage_error()
                }
                host = arguments[index + 1]
                guard !host!.isEmpty else { try throw_usage_error() }
                index += 2
            case "--port":
                guard port == nil, index + 1 < arguments.count,
                      let parsed_port = Int(arguments[index + 1]),
                      (1...65535).contains(parsed_port) else {
                    try throw_usage_error()
                }
                port = parsed_port
                index += 2
            case "--model":
                guard model == nil, index + 1 < arguments.count else {
                    try throw_usage_error()
                }
                let parsed_model = arguments[index + 1]
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
        guard let timeout = TimeInterval(arguments[2]), timeout > 0,
              timeout.isFinite else {
            try throw_usage_error()
        }
        return .stop(timeout: timeout)
    default:
        try throw_usage_error()
    }
}

func cli_usage() -> String {
    return """
    gemini2api \(GEMINI2API_VERSION)
    用法：gemini2api <serve|status|stop|version|help> [选项]
      serve [--host HOST] [--port PORT] [--model MODEL] [--daemon]
      status [--json]
      stop [--timeout SECONDS]
    """
}
