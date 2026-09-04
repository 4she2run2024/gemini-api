import Foundation

func try_parse(_ arguments: [String]) -> CLICommand? {
    do {
        return try parse_cli_command(arguments)
    } catch {
        return nil
    }
}

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
        expect_usage_error(["serve", "--port", "0"])
        expect_usage_error(["serve", "--port", "65536"])
        expect_usage_error(["serve", "--port"])
        expect_usage_error(["serve", "--daemon", "--daemon"])
        expect_usage_error(["status", "--daemon"])
        expect_usage_error(["serve", "--model", "unknown-model"])
        expect_usage_error(["serve", "--model", "gemini-3.8-flash@think=5"])
        expect_usage_error(["serve", "--model", "gemini-3.8-flash@think=bogus"])
        expect_usage_error(["--help", "serve"])
        precondition(cli_usage().contains("gemini2api"))
        print("CLICommandTests passed")
    }
}
