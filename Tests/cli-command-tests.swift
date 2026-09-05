// 用途：验证 Gemini2API 纯 CLI 命令解析及 usage 契约。
// 使用方法：由 bash Tests/run-tests.sh [--auto] 编译并执行。

import Foundation

// 功能：尝试解析参数并将错误转换为 nil，便于断言拒绝行为。
// 参数：arguments 为不含程序名的命令行参数数组。
// 返回值：解析成功返回命令，解析失败返回 nil。
func try_parse(_ arguments: [String]) -> CLICommand? {
    do {
        return try parse_cli_command(arguments)
    } catch {
        return nil
    }
}

// 功能：断言给定参数必须产生 usage 错误。
// 参数：arguments 为不含程序名的非法命令行参数数组。
// 返回值：无；断言失败时终止测试进程。
func expect_usage_error(_ arguments: [String]) {
    do {
        _ = try parse_cli_command(arguments)
        preconditionFailure("应拒绝无效参数")
    } catch {
        precondition(String(describing: error).contains("usage"))
    }
}

@main
struct CLICommandTests {
    // 功能：运行 CLI 命令解析契约测试。
    // 参数：无。
    // 返回值：无；断言失败时终止测试进程。
    static func main() {
        precondition(try_parse([]) == nil)
        precondition(try_parse(["unknown"]) == nil)
        precondition(try_parse(["serve"]) == .serve(
            ServeOptions(host: nil, port: nil, model: nil, daemon: false)))
        precondition(try_parse(["serve", "--host", "127.0.0.1", "--port", "8080",
                                "--model", "gemini-3.8-flash@think=3", "--daemon"])
                    == .serve(ServeOptions(host: "127.0.0.1", port: 8080,
                                           model: "gemini-3.8-flash@think=3", daemon: true)))
        precondition(try_parse(["status"]) == .status(json: false))
        precondition(try_parse(["status", "--json"]) == .status(json: true))
        precondition(try_parse(["stop"]) == .stop(timeout: 10))
        precondition(try_parse(["stop", "--timeout", "2.5"]) == .stop(timeout: 2.5))
        precondition(try_parse(["version"]) == .version)
        precondition(try_parse(["help"]) == .help)
        precondition(try_parse(["--help"]) == .help)
        precondition(try_parse(["-h"]) == .help)
        precondition(try_parse(["--version"]) == .version)
        precondition(try_parse(["serve", "--port", "65535"]) != nil)
        precondition(try_parse(["serve", "--port", "1"]) != nil)
        let missing_value_cases = [
            ["serve", "--host"],
            ["serve", "--port"],
            ["serve", "--model"],
            ["stop", "--timeout"],
        ]
        for arguments in missing_value_cases {
            expect_usage_error(arguments)
        }
        let reserved_value_cases = [
            ["serve", "--host", "--daemon"],
            ["serve", "--port", "--daemon"],
            ["serve", "--model", "--daemon"],
            ["stop", "--timeout", "--help"],
        ]
        for arguments in reserved_value_cases {
            expect_usage_error(arguments)
        }
        let unknown_option_value_cases = [
            ["serve", "--host", "--definitely-unknown-option"],
            ["serve", "--port", "--definitely-unknown-option"],
            ["serve", "--model", "--definitely-unknown-option"],
            ["stop", "--timeout", "--definitely-unknown-option"],
        ]
        for arguments in unknown_option_value_cases {
            expect_usage_error(arguments)
        }
        let duplicate_value_cases = [
            ["serve", "--host", "127.0.0.1", "--host", "127.0.0.2"],
            ["serve", "--port", "8080", "--port", "8081"],
            ["serve", "--model", "gemini-3.6-flash", "--model",
             "gemini-3.8-flash"],
        ]
        for arguments in duplicate_value_cases {
            expect_usage_error(arguments)
        }
        expect_usage_error(["serve", "--port", "0"])
        expect_usage_error(["serve", "--port", "-1"])
        expect_usage_error(["serve", "--port", "65536"])
        expect_usage_error(["stop", "--timeout", "-1"])
        expect_usage_error(["serve", "--daemon", "--daemon"])
        expect_usage_error(["status", "--daemon"])
        expect_usage_error(["--gemini2api-internal-daemon-child"])
        expect_usage_error(["serve", "--model", "unknown-model"])
        expect_usage_error(["serve", "--model", "gemini-3.8-flash@think=5"])
        expect_usage_error(["serve", "--model", "gemini-3.8-flash@think=bogus"])
        expect_usage_error(["--help", "serve"])
        precondition(cli_usage().contains("gemini2api"))
        print("CLICommandTests passed")
    }
}
