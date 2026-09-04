import Foundation

// 用途：验证协议无关网关类型的最小公开契约。
// 使用方法：由 bash Tests/run-tests.sh [--auto] 编译并执行。

@main
struct GatewayProtocolTests {
    // 功能：运行命名工具选择、错误映射和 token 总数测试。
    // 参数：无。
    // 返回值：无；断言失败时终止进程。
    static func main() {
        let choice = GatewayToolChoice.named("Read")
        precondition(choice.required_name == "Read")

        let error = GatewayProtocolError.unsupported("image input")
        precondition(error.http_status == 400)
        precondition(error.code == "unsupported_feature")

        let usage = GatewayUsage(input_tokens: 8, output_tokens: 5)
        precondition(usage.total_tokens == 13)

        let tool_result = GatewayToolResult(
            call_id: "toolu_123",
            name: "Read",
            output: "permission denied",
            is_error: true)
        precondition(tool_result.is_error == true)
        print("GatewayProtocolTests passed")
    }
}
