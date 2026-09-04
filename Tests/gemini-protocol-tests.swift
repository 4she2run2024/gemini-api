import Foundation

// 用途：验证 Gemini GenerateContent 路径、请求、响应和 HTTP 路由契约。
// 使用方法：由 bash Tests/run-tests.sh --auto 编译并执行。

private final class FakeGeminiGenerator: TextGenerating {
    var output = "Gemini route"

    // 功能：返回固定文本以验证 Gemini HTTP handler。
    // 参数：request 为待生成请求。
    // 返回值：固定响应文本。
    func generate(_ request: GenerationRequest) throws -> String {
        output
    }

    // 功能：返回固定流式文本；本任务的非流式测试不会调用。
    // 参数：request 为生成请求；isCancelled 判断取消；onDelta 接收增量。
    // 返回值：无。
    func generateStream(
        _ request: GenerationRequest,
        isCancelled: @escaping () -> Bool,
        onDelta: @escaping (String) -> Void
    ) throws {
        if !isCancelled() { onDelta(output) }
    }
}

@main
struct GeminiProtocolTests {
    // 功能：运行 Gemini 路径、请求、工具策略、响应和 HTTP 路由测试。
    // 参数：无。
    // 返回值：无；断言失败或未捕获错误时终止进程。
    static func main() throws {
        try test_strict_routes_and_query()
        test_invalid_routes()
        try test_roleless_content_defaults_to_user()
        try test_request_preserves_conversation_and_tools()
        try test_tool_modes()
        test_tool_modes_are_strict()
        try test_allowed_function_subset_cannot_call_delete()
        try test_parameters_json_schema_is_preserved()
        test_function_declaration_validation()
        try test_parameter_schemas_are_strict()
        try test_json_parameter_schema_recursive_subset()
        test_call_and_response_names_are_stricter_than_declarations()
        test_function_response_must_match_prior_call()
        test_function_response_features_are_unsupported()
        try test_generation_controls_and_field_classification()
        test_generation_control_values_are_strict()
        test_logprobs_requires_response_logprobs_true()
        test_unsupported_features()
        test_text_response()
        test_function_call_response()
        try test_http_route_and_unmatched_path()
        print("GeminiProtocolTests passed")
    }

    // 功能：验证省略 Content.role 的官方最小请求按 user 输入解析。
    // 参数：无。
    // 返回值：无。
    private static func test_roleless_content_defaults_to_user() throws {
        let parsed = try parse_gemini_request(
            minimal_request(),
            model: "gemini-3.8-flash",
            stream: false)
        precondition(parsed.messages.count == 1)
        precondition(parsed.messages[0].role == .user)
        precondition(text_value(parsed.messages[0].content[0]) == "Hello")

        for role in ["system", "tool", ""] {
            let request: [String: Any] = [
                "contents": [["role": role, "parts": [["text": "Hello"]]]],
            ]
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证 query 不参与严格路径匹配，且两种 action 映射 stream 状态。
    // 参数：无。
    // 返回值：无。
    private static func test_strict_routes_and_query() throws {
        let route = try parse_gemini_route(
            "/v1beta/models/gemini-3.8-flash:generateContent?key=test")
        precondition(route.model == "gemini-3.8-flash")
        precondition(route.stream == false)

        let stream_route = try parse_gemini_route(
            "/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse&key=test")
        precondition(stream_route.model == "gemini-3.8-flash")
        precondition(stream_route.stream == true)

        let query_route = try parse_gemini_route(
            "/v1beta/models/gemini-auto:generateContent?redirect=/extra/segment")
        precondition(query_route.model == "gemini-auto")

        let encoded_route = try parse_gemini_route(
            "/v1beta/models/gemini%2D3.8%2Dflash:generateContent?key=a%2Fb")
        precondition(encoded_route.model == "gemini-3.8-flash")
    }

    // 功能：验证空模型、额外 segment 和近似 action 都不匹配。
    // 参数：无。
    // 返回值：无。
    private static func test_invalid_routes() {
        let paths = [
            "/v1beta/models/:generateContent",
            "/v1beta/models/gemini-3.8-flash/generateContent",
            "/v1beta/models/team/gemini-3.8-flash:generateContent",
            "/v1beta/models/gemini-3.8-flash:generateContent/extra",
            "/v1beta/models/gemini-3.8-flash:generateContentExtra",
            "/v1/models/gemini-3.8-flash:generateContent",
            "/v1beta/models/gemini%2Fflash:generateContent",
            "/v1beta/models/gemini%3Fflash:generateContent",
            "/v1beta/models/gemini%23flash:generateContent",
            "/v1beta/models/gemini%252Fflash:generateContent",
            "/v1beta/models/gemini%:generateContent",
            "/v1beta/models/gemini%2:generateContent",
            "/v1beta/models/gemini%GG:generateContent",
        ]
        for path in paths {
            assert_invalid_request { _ = try parse_gemini_route(path) }
        }
    }

    // 功能：验证 system、双向文本、functionCall、functionResponse 和声明均保留。
    // 参数：无。
    // 返回值：无。
    private static func test_request_preserves_conversation_and_tools() throws {
        let parsed = try parse_gemini_request(
            conversation_request(mode: "ANY", allowed_names: ["Read"]),
            model: "gemini-3.8-flash",
            stream: false)
        precondition(parsed.model == "gemini-3.8-flash")
        precondition(parsed.stream == false)
        precondition(parsed.messages.count == 4)
        precondition(parsed.messages[0].role == .system)
        precondition(text_value(parsed.messages[0].content[0]) == "Follow policy")
        precondition(parsed.messages[1].role == .user)
        precondition(text_value(parsed.messages[1].content[0]) == "Read README.md")
        precondition(parsed.messages[2].role == .assistant)
        precondition(text_value(parsed.messages[2].content[0]) == "I will read it.")

        let call = tool_call_value(parsed.messages[2].content[1])
        precondition(call?.id == "call_read")
        precondition(call?.name == "Read")
        precondition(call?.arguments["file_path"] as? String == "README.md")

        precondition(parsed.messages[3].role == .user)
        let result = tool_result_value(parsed.messages[3].content[0])
        precondition(result?.call_id == "call_read")
        precondition(result?.name == "Read")
        let output = result?.output as? [String: Any]
        precondition(output?["content"] as? String == "Gemini2API")

        precondition(parsed.tools.count == 1)
        precondition(parsed.tools[0].name == "Read")
        precondition(parsed.tools[0].description == "Read a file")
        precondition(parsed.tools[0].parameters["type"] as? String == "object")
        precondition(parsed.tool_choice.required_name == "Read")
    }

    // 功能：验证 AUTO、NONE、ANY 和单函数允许列表的统一策略映射。
    // 参数：无。
    // 返回值：无。
    private static func test_tool_modes() throws {
        let auto = try parse_gemini_request(
            conversation_request(mode: "AUTO"),
            model: "gemini-auto",
            stream: false)
        if case .auto = auto.tool_choice {} else {
            preconditionFailure("AUTO must map to .auto")
        }

        let none = try parse_gemini_request(
            conversation_request(mode: "NONE"),
            model: "gemini-auto",
            stream: false)
        if case .none = none.tool_choice {} else {
            preconditionFailure("NONE must map to .none")
        }

        let any = try parse_gemini_request(
            conversation_request(mode: "ANY"),
            model: "gemini-auto",
            stream: true)
        if case .required = any.tool_choice {} else {
            preconditionFailure("ANY must map to .required")
        }
        precondition(any.stream)

        let named = try parse_gemini_request(
            conversation_request(mode: "ANY", allowed_names: ["Read"]),
            model: "gemini-auto",
            stream: false)
        precondition(named.tool_choice.required_name == "Read")
    }

    // 功能：验证显式 mode 必须是本 Task 支持的精确字符串枚举。
    // 参数：无。
    // 返回值：无。
    private static func test_tool_modes_are_strict() {
        for mode: Any in [7, "auto", "SOMETIMES", "MODE_UNSPECIFIED"] {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request_with_function_config(["mode": mode]),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
        assert_unsupported {
            _ = try parse_gemini_request(
                request_with_function_config(["mode": "VALIDATED"]),
                model: "gemini-3.8-flash",
                stream: false)
        }
        var validated_request = request_with_function_config([
            "allowedFunctionNames": ["Read"],
            "mode": "VALIDATED",
        ])
        validated_request["tools"] = [["functionDeclarations": [[
            "description": "Read a file",
            "name": "Read",
        ]]]]
        assert_unsupported {
            _ = try parse_gemini_request(
                validated_request,
                model: "gemini-3.8-flash",
                stream: false)
        }
    }

    // 功能：验证 ANY 多允许函数缩小集合，未允许工具无法通过管线校验。
    // 参数：无。
    // 返回值：无。
    private static func test_allowed_function_subset_cannot_call_delete() throws {
        let parsed = try parse_gemini_request(
            restricted_tools_request(),
            model: "gemini-3.8-flash",
            stream: false)
        precondition(parsed.tools.map(\.name) == ["Read", "Write"])
        if case .required = parsed.tool_choice {} else {
            preconditionFailure("multiple allowed functions must map to .required")
        }

        let generator = FakeGeminiGenerator()
        generator.output = """
        ```tool_call
        {"name":"Delete","arguments":{"file_path":"README.md"}}
        ```
        """
        let pipeline = GatewayPipeline(
            generator: generator,
            default_model: "gemini-3.6-flash")
        let context = try pipeline.prepare(parsed)
        assert_gateway_error(expected_code: "tool_protocol_error") {
            _ = try pipeline.generate(context)
        }
    }

    // 功能：验证 parametersJsonSchema 对象不会被静默替换为空 schema。
    // 参数：无。
    // 返回值：无。
    private static func test_parameters_json_schema_is_preserved() throws {
        let declaration: [String: Any] = [
            "name": "Read:file-v1",
            "description": "Read a file",
            "parametersJsonSchema": [
                "type": "object",
                "properties": ["file_path": ["type": "string"]],
                "required": ["file_path"],
            ],
        ]
        let parsed = try parse_gemini_request(
            request_with_declaration(declaration),
            model: "gemini-3.8-flash",
            stream: false)
        precondition(parsed.tools.count == 1)
        precondition(parsed.tools[0].name == "Read:file-v1")
        precondition(parsed.tools[0].parameters["type"] as? String == "object")
        let properties = parsed.tools[0].parameters["properties"]
            as? [String: Any]
        let file_path = properties?["file_path"] as? [String: Any]
        precondition(file_path?["type"] as? String == "string")
        precondition(parsed.tools[0].parameters["required"] as? [String]
            == ["file_path"])
    }

    // 功能：验证函数声明必填字段、名称、schema 互斥和能力边界。
    // 参数：无。
    // 返回值：无。
    private static func test_function_declaration_validation() {
        let invalid_declarations: [[String: Any]] = [
            ["name": "Read"],
            ["name": "Read", "description": ""],
            ["name": "Read", "description": 7],
            ["name": "bad name!", "description": "Invalid name"],
            ["name": "读取", "description": "Non-ASCII name"],
            ["name": String(repeating: "a", count: 129), "description": "Too long"],
            [
                "name": "Read",
                "description": "Read a file",
                "parameters": ["type": "object"],
                "parametersJsonSchema": ["type": "object"],
            ],
            ["name": "Read", "description": "Read a file", "unknown": true],
        ]
        for declaration in invalid_declarations {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request_with_declaration(declaration),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        for key in ["response", "responseJsonSchema", "behavior"] {
            var declaration: [String: Any] = [
                "name": "Read",
                "description": "Read a file",
            ]
            if key == "behavior" {
                declaration[key] = "BLOCKING"
            } else {
                declaration[key] = ["type": "object"]
            }
            assert_unsupported {
                _ = try parse_gemini_request(
                    request_with_declaration(declaration),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证 Google Schema 与 JSON Schema 的根类型和关键嵌套结构。
    // 参数：无。
    // 返回值：无。
    private static func test_parameter_schemas_are_strict() throws {
        let valid_google_schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "path": ["type": "STRING", "nullable": false],
                "tags": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"],
                ],
            ],
            "required": ["path"],
        ]
        let valid_declaration: [String: Any] = [
            "name": "Read",
            "description": "Read a file",
            "parameters": valid_google_schema,
        ]
        let valid = try parse_gemini_request(
            request_with_declaration(valid_declaration),
            model: "gemini-3.8-flash",
            stream: false)
        precondition(valid.tools[0].parameters["type"] as? String == "OBJECT")
        let lowercase = try parse_gemini_request(
            request_with_parameter_schema(
                key: "parameters",
                schema: ["type": "object"]),
            model: "gemini-3.8-flash",
            stream: false)
        precondition(lowercase.tools[0].parameters["type"] as? String == "object")

        let invalid_google_schemas: [[String: Any]] = [
            ["properties": [:]],
            ["type": "STRING"],
            ["type": "OBJECT", "properties": "invalid"],
            ["type": "OBJECT", "properties": ["path": "invalid"]],
            ["type": "OBJECT", "properties": ["path": ["description": "missing"]]],
            ["type": "OBJECT", "required": "path"],
            ["type": "OBJECT", "nullable": 1],
            ["type": "OBJECT", "properties": ["tags": [
                "type": "ARRAY",
                "items": "invalid",
            ]]],
        ]
        for schema in invalid_google_schemas {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request_with_parameter_schema(
                        key: "parameters",
                        schema: schema),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        let invalid_json_schemas: [[String: Any]] = [
            ["properties": [:]],
            ["type": "string"],
            ["type": "object", "properties": "invalid"],
            ["type": "object", "properties": ["path": "invalid"]],
            ["type": "object", "required": "path"],
            ["type": "object", "items": "invalid"],
        ]
        for schema in invalid_json_schemas {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request_with_parameter_schema(
                        key: "parametersJsonSchema",
                        schema: schema),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证 parametersJsonSchema 的递归子集、nullable union 和字段分类。
    // 参数：无。
    // 返回值：无。
    private static func test_json_parameter_schema_recursive_subset() throws {
        let schema: [String: Any] = [
            "$defs": [
                "nullableText": ["type": ["string", "null"]],
            ],
            "additionalProperties": false,
            "anyOf": [
                ["type": "object"],
                ["type": ["object", "null"]],
            ],
            "properties": [
                "choice": ["oneOf": [
                    ["type": "string"],
                    ["type": "integer"],
                ]],
                "tuple": [
                    "prefixItems": [
                        ["type": "string"],
                        ["type": "integer"],
                    ],
                    "type": "array",
                ],
                "value": ["$ref": "#/$defs/nullableText"],
            ],
            "required": ["value"],
            "type": ["object", "null"],
        ]
        let parsed = try parse_gemini_request(
            request_with_parameter_schema(
                key: "parametersJsonSchema",
                schema: schema),
            model: "gemini-3.8-flash",
            stream: false)
        let preserved = parsed.tools[0].parameters
        precondition(preserved["type"] as? [String] == ["object", "null"])
        precondition(preserved["additionalProperties"] as? Bool == false)
        let definitions = preserved["$defs"] as? [String: Any]
        let nullable_text = definitions?["nullableText"] as? [String: Any]
        precondition(nullable_text?["type"] as? [String] == ["string", "null"])

        let malformed_schemas: [[String: Any]] = [
            ["type": "object", "anyOf": "bad"],
            ["type": "object", "$defs": "bad"],
            ["type": "object", "additionalProperties": 7],
            ["type": "object", "prefixItems": "bad"],
            ["type": "object", "oneOf": "bad"],
            ["type": "object", "anyOf": [["type": "invalid"]]],
            ["type": "object", "$defs": ["value": "bad"]],
            ["type": "object", "additionalProperties": ["type": "invalid"]],
            ["type": "array", "prefixItems": [["unknownKeyword": true]]],
            ["type": "object", "oneOf": [["type": ["string", "string"]]]],
            ["type": ["string", "null"]],
            ["type": ["object", "invalid"]],
        ]
        for malformed_schema in malformed_schemas {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request_with_parameter_schema(
                        key: "parametersJsonSchema",
                        schema: malformed_schema),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        assert_unsupported {
            _ = try parse_gemini_request(
                request_with_parameter_schema(
                    key: "parametersJsonSchema",
                    schema: ["type": "object", "allOf": []]),
                model: "gemini-3.8-flash",
                stream: false)
        }
        assert_invalid_request {
            _ = try parse_gemini_request(
                request_with_parameter_schema(
                    key: "parametersJsonSchema",
                    schema: ["type": "object", "unknownKeyword": true]),
                model: "gemini-3.8-flash",
                stream: false)
        }
    }

    // 功能：验证调用和响应名称的窄字符集和 128 字符限制。
    // 参数：无。
    // 返回值：无。
    private static func test_call_and_response_names_are_stricter_than_declarations() {
        let invalid_names = [
            "Read.file",
            "Read:file",
            String(repeating: "a", count: 129),
        ]
        for name in invalid_names {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    function_round_trip_request(
                        call_name: name,
                        response_name: name,
                        response_id: "call_read"),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证 functionResponse 的名称和 ID 必须匹配前序可见调用。
    // 参数：无。
    // 返回值：无。
    private static func test_function_response_must_match_prior_call() {
        let mismatched_requests = [
            function_round_trip_request(
                response_name: "Write",
                response_id: "call_write"),
            function_round_trip_request(
                response_name: "Read",
                response_id: "call_write"),
            function_round_trip_request(
                response_name: "Read",
                response_id: nil),
            [
                "contents": [["parts": [["functionResponse": [
                    "name": "Read",
                    "response": ["content": "done"],
                ]]]]],
            ],
        ]
        for request in mismatched_requests {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证 functionResponse 媒体、继续和调度字段明确 unsupported。
    // 参数：无。
    // 返回值：无。
    private static func test_function_response_features_are_unsupported() {
        let unsupported_fields: [[String: Any]] = [
            ["parts": [["inlineData": [
                "mimeType": "image/png",
                "data": "AA==",
            ]]]],
            ["willContinue": false],
            ["scheduling": "SILENT"],
        ]
        for fields in unsupported_fields {
            assert_unsupported {
                _ = try parse_gemini_request(
                    function_round_trip_request(
                        response_name: "Read",
                        response_id: "call_read",
                        response_fields: fields),
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证生成控制可忽略，未知字段和已知不支持能力被准确分类。
    // 参数：无。
    // 返回值：无。
    private static func test_generation_controls_and_field_classification() throws {
        var generation_request = minimal_request()
        generation_request["generationConfig"] = [
            "temperature": 0.5,
            "topP": 0.8,
            "topK": 20,
            "maxOutputTokens": 512,
            "stopSequences": ["STOP"],
            "candidateCount": 1,
            "presencePenalty": 0.1,
            "responseMimeType": "text/plain",
            "responseLogprobs": true,
            "frequencyPenalty": 0.2,
            "logprobs": 0,
            "seed": 7,
        ]
        let parsed = try parse_gemini_request(
            generation_request,
            model: "gemini-3.8-flash",
            stream: false)
        precondition(parsed.messages.count == 1)

        var unknown_top_level = minimal_request()
        unknown_top_level["contentsTypo"] = true
        assert_invalid_request {
            _ = try parse_gemini_request(
                unknown_top_level,
                model: "gemini-3.8-flash",
                stream: false)
        }

        var invalid_generation_config = minimal_request()
        invalid_generation_config["generationConfig"] = "fast"
        assert_invalid_request {
            _ = try parse_gemini_request(
                invalid_generation_config,
                model: "gemini-3.8-flash",
                stream: false)
        }

        var unknown_generation_field = minimal_request()
        unknown_generation_field["generationConfig"] = ["temperatur": 0.5]
        assert_invalid_request {
            _ = try parse_gemini_request(
                unknown_generation_field,
                model: "gemini-3.8-flash",
                stream: false)
        }

        let unsupported_request_fields: [String: Any] = [
            "cachedContent": "cachedContents/example",
            "model": "models/gemini-3.8-flash",
            "safetySettings": [],
            "serviceTier": "standard",
            "store": true,
        ]
        for (key, value) in unsupported_request_fields {
            var request = minimal_request()
            request[key] = value
            assert_unsupported {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        for mime_type in ["application/json", "text/x.enum"] {
            var unsupported_generation_field = minimal_request()
            unsupported_generation_field["generationConfig"] = [
                "responseMimeType": mime_type,
            ]
            assert_unsupported {
                _ = try parse_gemini_request(
                    unsupported_generation_field,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        var invalid_mime_type = minimal_request()
        invalid_mime_type["generationConfig"] = ["responseMimeType": true]
        assert_invalid_request {
            _ = try parse_gemini_request(
                invalid_mime_type,
                model: "gemini-3.8-flash",
                stream: false)
        }

        try assert_nested_field_classification()
    }

    // 功能：验证 11 个允许生成字段的 JSON 类型与明确范围。
    // 参数：无。
    // 返回值：无。
    private static func test_generation_control_values_are_strict() {
        let invalid_values: [(String, Any)] = [
            ("temperature", "hot"),
            ("temperature", true),
            ("temperature", -0.1),
            ("temperature", 2.1),
            ("topP", true),
            ("topP", -0.1),
            ("topP", 1.1),
            ("topK", 1.5),
            ("topK", 0),
            ("candidateCount", 1.5),
            ("candidateCount", 0),
            ("maxOutputTokens", 1.5),
            ("maxOutputTokens", 0),
            ("seed", 1.5),
            ("seed", Int64(Int32.max) + 1),
            ("presencePenalty", false),
            ("frequencyPenalty", "low"),
            ("responseLogprobs", 1),
            ("logprobs", true),
            ("logprobs", 1.5),
            ("logprobs", -1),
            ("logprobs", 21),
            ("stopSequences", "STOP"),
            ("stopSequences", [1]),
            ("stopSequences", ["1", "2", "3", "4", "5", "6"]),
        ]
        for (key, value) in invalid_values {
            var request = minimal_request()
            request["generationConfig"] = [key: value]
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证 logprobs 只能与严格 JSON true 的 responseLogprobs 一起使用。
    // 参数：无。
    // 返回值：无。
    private static func test_logprobs_requires_response_logprobs_true() {
        for response_value: Any? in [nil, false] {
            var generation_config: [String: Any] = ["logprobs": 5]
            if let response_value = response_value {
                generation_config["responseLogprobs"] = response_value
            }
            var request = minimal_request()
            request["generationConfig"] = generation_config
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证 Content、Part、ToolConfig 和 FunctionCall 嵌套字段分类。
    // 参数：无。
    // 返回值：无。
    private static func assert_nested_field_classification() throws {
        let invalid_requests: [[String: Any]] = [
            ["contents": [["parts": [["text": "Hello"]], "unknown": true]]],
            ["contents": [["parts": [["text": "Hello", "unknown": true]]]]],
            request_with_function_config(["mode": "AUTO", "unknown": true]),
            [
                "contents": [["role": "model", "parts": [["functionCall": [
                    "name": "Read",
                    "args": [:],
                    "unknown": true,
                ]]]]],
            ],
        ]
        for request in invalid_requests {
            assert_invalid_request {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        for key in ["retrievalConfig", "includeServerSideToolInvocations"] {
            var request = minimal_request()
            request["toolConfig"] = [key: [:]]
            assert_unsupported {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        let unsupported_part_keys = [
            "audioTranscription",
            "codeExecutionResult",
            "executableCode",
            "fileData",
            "inlineData",
            "mediaProcessing",
            "mediaResolution",
            "partMetadata",
            "thought",
            "thoughtSignature",
            "toolCall",
            "toolResponse",
            "videoMetadata",
        ]
        for key in unsupported_part_keys {
            let request: [String: Any] = [
                "contents": [["parts": [[key: [:]]]]],
            ]
            assert_unsupported {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证媒体 part 和托管工具不会被降级或静默忽略。
    // 参数：无。
    // 返回值：无。
    private static func test_unsupported_features() {
        for key in ["inlineData", "fileData"] {
            var request = minimal_request()
            request["contents"] = [[
                "role": "user",
                "parts": [[key: ["mimeType": "image/png", "data": "AA=="]]],
            ]]
            assert_unsupported {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }

        let managed_tools = [
            "codeExecution",
            "computerUse",
            "fileSearch",
            "googleMaps",
            "googleSearch",
            "googleSearchRetrieval",
            "mcpServers",
            "urlContext",
        ]
        for key in managed_tools {
            var request = minimal_request()
            request["tools"] = [[key: [:]]]
            assert_unsupported {
                _ = try parse_gemini_request(
                    request,
                    model: "gemini-3.8-flash",
                    stream: false)
            }
        }
    }

    // 功能：验证文本结果使用 Gemini candidate、STOP 和完整 usageMetadata。
    // 参数：无。
    // 返回值：无。
    private static func test_text_response() {
        let response = make_gemini_response(
            result(text: "Gemini2API"),
            response_id: "response_text")
        let candidate = first_candidate(response)
        let parts = content_parts(candidate)
        precondition(parts.count == 1)
        precondition(parts[0]["text"] as? String == "Gemini2API")
        precondition(parts[0]["functionCall"] == nil)
        precondition(candidate["finishReason"] as? String == "STOP")
        precondition(candidate["index"] as? Int == 0)
        precondition(response["modelVersion"] as? String == "gemini-3.8-flash")
        precondition(response["responseId"] as? String == "response_text")
        assert_usage(response)
    }

    // 功能：验证工具调用位于 functionCall part，不会被编码进 text。
    // 参数：无。
    // 返回值：无。
    private static func test_function_call_response() {
        let call = GatewayToolCall(
            id: "call_read",
            name: "Read",
            arguments: ["file_path": "README.md"])
        let response = make_gemini_response(
            result(text: "", calls: [call]),
            response_id: "response_tool")
        let candidate = first_candidate(response)
        let parts = content_parts(candidate)
        precondition(parts.count == 1)
        precondition(parts[0]["text"] == nil)
        let function = parts[0]["functionCall"] as? [String: Any]
        precondition(function?["id"] as? String == "call_read")
        precondition(function?["name"] as? String == "Read")
        let arguments = function?["args"] as? [String: Any]
        precondition(arguments?["file_path"] as? String == "README.md")
        precondition(candidate["finishReason"] as? String == "STOP")
    }

    // 功能：验证严格路径命中 handler，额外 segment 继续返回 404。
    // 参数：无。
    // 返回值：无。
    private static func test_http_route_and_unmatched_path() throws {
        let config = Store()
        config.host = "127.0.0.1"
        config.port = Int.random(in: 20_000...50_000)
        let generator = FakeGeminiGenerator()
        let server = HTTPServer(generator: generator, config: config)
        try server.start()
        defer { server.stop() }
        for _ in 0..<40 where !server.running {
            Thread.sleep(forTimeInterval: 0.05)
        }
        precondition(server.running, "Gemini test server did not become ready")

        let matched = try post(
            path: "/v1beta/models/gemini-3.8-flash:generateContent?key=test",
            port: config.port,
            body: minimal_request())
        precondition(matched.status == 200)
        let candidate = first_candidate(matched.object)
        precondition(content_parts(candidate)[0]["text"] as? String == "Gemini route")

        var text_plain_request = minimal_request()
        text_plain_request["generationConfig"] = ["responseMimeType": "text/plain"]
        let text_plain_response = try post(
            path: "/v1beta/models/gemini-3.8-flash:generateContent",
            port: config.port,
            body: text_plain_request)
        precondition(text_plain_response.status == 200)

        var malformed_generation = minimal_request()
        malformed_generation["generationConfig"] = [
            "temperature": "hot",
            "stopSequences": "STOP",
            "maxOutputTokens": 1.5,
            "responseLogprobs": 1,
        ]
        let malformed_response = try post(
            path: "/v1beta/models/gemini-3.8-flash:generateContent",
            port: config.port,
            body: malformed_generation)
        precondition(malformed_response.status == 400)

        var invalid_logprobs = minimal_request()
        invalid_logprobs["generationConfig"] = ["logprobs": 5]
        let invalid_logprobs_response = try post(
            path: "/v1beta/models/gemini-3.8-flash:generateContent",
            port: config.port,
            body: invalid_logprobs)
        precondition(invalid_logprobs_response.status == 400)

        generator.output = """
        ```tool_call
        {"name":"Delete","arguments":{"file_path":"README.md"}}
        ```
        """
        let denied_tool = try post(
            path: "/v1beta/models/gemini-3.8-flash:generateContent",
            port: config.port,
            body: restricted_tools_request())
        precondition(denied_tool.status == 502)

        var unknown_field = minimal_request()
        unknown_field["contentsTypo"] = true
        let invalid_request = try post(
            path: "/v1beta/models/gemini-3.8-flash:generateContent",
            port: config.port,
            body: unknown_field)
        precondition(invalid_request.status == 400)

        let unmatched = try post(
            path: "/v1beta/models/gemini-3.8-flash:generateContent/extra",
            port: config.port,
            body: minimal_request())
        precondition(unmatched.status == 404)
    }

    // 功能：创建覆盖 system、文本、工具调用、工具结果和声明的请求。
    // 参数：mode 为工具模式；allowed_names 为可选允许函数列表。
    // 返回值：Gemini JSON 请求对象。
    private static func conversation_request(
        mode: String,
        allowed_names: [String]? = nil
    ) -> [String: Any] {
        var function_config: [String: Any] = ["mode": mode]
        if let allowed_names = allowed_names {
            function_config["allowedFunctionNames"] = allowed_names
        }
        return [
            "systemInstruction": ["parts": [["text": "Follow policy"]]],
            "contents": [
                ["role": "user", "parts": [["text": "Read README.md"]]],
                [
                    "role": "model",
                    "parts": [
                        ["text": "I will read it."],
                        ["functionCall": [
                            "id": "call_read",
                            "name": "Read",
                            "args": ["file_path": "README.md"],
                        ]],
                    ],
                ],
                [
                    "role": "user",
                    "parts": [["functionResponse": [
                        "id": "call_read",
                        "name": "Read",
                        "response": ["content": "Gemini2API"],
                    ]]],
                ],
            ],
            "tools": [["functionDeclarations": [[
                "name": "Read",
                "description": "Read a file",
                "parameters": [
                    "type": "object",
                    "properties": ["file_path": ["type": "string"]],
                ],
            ]]]],
            "toolConfig": ["functionCallingConfig": function_config],
        ]
    }

    // 功能：创建最小合法 Gemini 文本请求。
    // 参数：无。
    // 返回值：Gemini JSON 请求对象。
    private static func minimal_request() -> [String: Any] {
        ["contents": [["parts": [["text": "Hello"]]]]]
    }

    // 功能：创建包含未授权 Delete 的多函数 ANY 请求。
    // 参数：无。
    // 返回值：声明三个工具但只允许 Read 和 Write 的请求。
    private static func restricted_tools_request() -> [String: Any] {
        let declarations = ["Read", "Write", "Delete"].map { name in
            [
                "name": name,
                "description": "\(name) a file",
                "parameters": ["type": "object"],
            ] as [String: Any]
        }
        return [
            "contents": [["parts": [["text": "Edit README.md"]]]],
            "tools": [["functionDeclarations": declarations]],
            "toolConfig": ["functionCallingConfig": [
                "mode": "ANY",
                "allowedFunctionNames": ["Read", "Write"],
            ]],
        ]
    }

    // 功能：创建只包含一个函数声明的最小请求。
    // 参数：declaration 为待测试声明。
    // 返回值：Gemini 请求对象。
    private static func request_with_declaration(
        _ declaration: [String: Any]
    ) -> [String: Any] {
        [
            "contents": [["parts": [["text": "Use a tool"]]]],
            "tools": [["functionDeclarations": [declaration]]],
        ]
    }

    // 功能：创建带指定参数 schema 的函数声明请求。
    // 参数：key 为 schema 字段；schema 为待验证对象。
    // 返回值：Gemini 请求对象。
    private static func request_with_parameter_schema(
        key: String,
        schema: [String: Any]
    ) -> [String: Any] {
        request_with_declaration([
            "name": "Read",
            "description": "Read a file",
            key: schema,
        ])
    }

    // 功能：创建带指定 functionCallingConfig 的最小请求。
    // 参数：config 为函数调用配置。
    // 返回值：Gemini 请求对象。
    private static func request_with_function_config(
        _ config: [String: Any]
    ) -> [String: Any] {
        [
            "contents": [["parts": [["text": "Hello"]]]],
            "toolConfig": ["functionCallingConfig": config],
        ]
    }

    // 功能：创建具有前序 Read 调用和可配置响应标识的续轮请求。
    // 参数：response_name 为响应名称；response_id 为响应 ID。
    // 返回值：Gemini 多轮请求对象。
    private static func function_round_trip_request(
        call_name: String = "Read",
        response_name: String,
        response_id: String?,
        response_fields: [String: Any] = [:]
    ) -> [String: Any] {
        var response: [String: Any] = [
            "name": response_name,
            "response": ["content": "done"],
        ]
        if let response_id = response_id {
            response["id"] = response_id
        }
        response_fields.forEach { response[$0.key] = $0.value }
        return [
            "contents": [
                ["role": "model", "parts": [["functionCall": [
                    "id": "call_read",
                    "name": call_name,
                    "args": ["file_path": "README.md"],
                ]]]],
                ["role": "user", "parts": [["functionResponse": response]]],
            ],
        ]
    }

    // 功能：执行 JSON POST 并返回 status 与 JSON object。
    // 参数：path 为 request target；port 为端口；body 为 JSON 对象。
    // 返回值：HTTP status 和响应 JSON object。
    private static func post(
        path: String,
        port: Int,
        body: [String: Any]
    ) throws -> (status: Int, object: [String: Any]) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let semaphore = DispatchSemaphore(value: 0)
        var response_status = 0
        var response_data = Data()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            response_status = (response as? HTTPURLResponse)?.statusCode ?? 0
            response_data = data ?? Data()
            semaphore.signal()
        }.resume()
        precondition(semaphore.wait(timeout: .now() + 5) == .success)
        let object = try JSONSerialization.jsonObject(with: response_data)
            as? [String: Any]
        return (response_status, object ?? [:])
    }

    // 功能：提取统一文本内容。
    // 参数：content 为单个统一内容。
    // 返回值：文本内容；非文本返回 nil。
    private static func text_value(_ content: GatewayContent) -> String? {
        if case .text(let text) = content { return text }
        return nil
    }

    // 功能：提取统一工具调用。
    // 参数：content 为单个统一内容。
    // 返回值：工具调用；其他内容返回 nil。
    private static func tool_call_value(_ content: GatewayContent) -> GatewayToolCall? {
        if case .tool_call(let call) = content { return call }
        return nil
    }

    // 功能：提取统一工具结果。
    // 参数：content 为单个统一内容。
    // 返回值：工具结果；其他内容返回 nil。
    private static func tool_result_value(
        _ content: GatewayContent
    ) -> GatewayToolResult? {
        if case .tool_result(let result) = content { return result }
        return nil
    }

    // 功能：提取第一个 Gemini candidate。
    // 参数：response 为 Gemini 响应对象。
    // 返回值：第一个 candidate；结构错误时终止。
    private static func first_candidate(
        _ response: [String: Any]
    ) -> [String: Any] {
        guard let candidates = response["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            preconditionFailure("missing Gemini candidate")
        }
        return first
    }

    // 功能：提取 candidate 的 content parts 并验证 model 角色。
    // 参数：candidate 为 Gemini candidate。
    // 返回值：content parts；结构错误时终止。
    private static func content_parts(
        _ candidate: [String: Any]
    ) -> [[String: Any]] {
        let content = candidate["content"] as? [String: Any]
        precondition(content?["role"] as? String == "model")
        return content?["parts"] as? [[String: Any]] ?? []
    }

    // 功能：验证 Gemini usageMetadata 使用统一 token 计数。
    // 参数：response 为 Gemini 响应对象。
    // 返回值：无。
    private static func assert_usage(_ response: [String: Any]) {
        let usage = response["usageMetadata"] as? [String: Any]
        precondition(usage?["promptTokenCount"] as? Int == 8)
        precondition(usage?["candidatesTokenCount"] as? Int == 5)
        precondition(usage?["totalTokenCount"] as? Int == 13)
    }

    // 功能：断言操作抛出 invalid_request。
    // 参数：action 为待执行操作。
    // 返回值：无。
    private static func assert_invalid_request(action: () throws -> Void) {
        assert_gateway_error(expected_code: "invalid_request", action: action)
    }

    // 功能：断言操作抛出 unsupported_feature。
    // 参数：action 为待执行操作。
    // 返回值：无。
    private static func assert_unsupported(action: () throws -> Void) {
        assert_gateway_error(expected_code: "unsupported_feature", action: action)
    }

    // 功能：断言操作抛出指定 GatewayProtocolError code。
    // 参数：expected_code 为预期 code；action 为待执行操作。
    // 返回值：无。
    private static func assert_gateway_error(
        expected_code: String,
        action: () throws -> Void
    ) {
        do {
            try action()
            preconditionFailure("expected GatewayProtocolError \(expected_code)")
        } catch let error as GatewayProtocolError {
            precondition(error.code == expected_code)
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }

    // 功能：创建固定 token 计数的统一结果。
    // 参数：text 为文本；calls 为工具调用。
    // 返回值：统一结果。
    private static func result(
        text: String,
        calls: [GatewayToolCall] = []
    ) -> GatewayResult {
        GatewayResult(
            model: "gemini-3.8-flash",
            text: text,
            tool_calls: calls,
            finish_reason: calls.isEmpty ? .stop : .tool_calls,
            usage: GatewayUsage(input_tokens: 8, output_tokens: 5))
    }
}
