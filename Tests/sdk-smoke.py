"""用途：使用 OpenAI 和 Anthropic 官方 SDK 验证 Gemini2API。

使用方法：设置 GEMINI2API_BASE_URL 后，
在安装官方 SDK 的隔离环境中直接运行。
"""

import json
import os

from anthropic import Anthropic
from openai import OpenAI


EXPECTED_TEXT = "Gemini2API SDK ok"
MODEL = "gemini-3.8-flash"
READ_TOOL_SCHEMA = {
    "type": "object",
    "properties": {"file_path": {"type": "string"}},
    "required": ["file_path"],
    "additionalProperties": False,
}


def assert_expected_text(text: str, label: str) -> None:
    """断言 SDK 已解码出预期文本。

    参数为文本和检查标签；无返回值。
    """
    assert text == EXPECTED_TEXT, f"{label} text mismatch"


def assert_read_arguments(arguments: object, label: str) -> None:
    """断言 SDK 已解码 Read 参数。

    参数为参数对象和检查标签；无返回值。
    """
    if isinstance(arguments, str):
        arguments = json.loads(arguments)
    assert isinstance(arguments, dict), f"{label} arguments are not an object"
    assert arguments.get("file_path") == "README.md", f"{label} arguments mismatch"


def run_openai_smoke(base_url: str) -> None:
    """验证 OpenAI 文本、流式和 function call。

    参数为服务根 URL；无返回值。
    """
    client = OpenAI(api_key="test-key", base_url=f"{base_url}/v1")

    models = list(client.models.list())
    assert models and models[0].id, "OpenAI models decode failed"

    chat = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "user", "content": "Say SDK ok"}],
    )
    assert_expected_text(chat.choices[0].message.content or "", "OpenAI Chat")

    chat_stream_text = "".join(
        chunk.choices[0].delta.content or ""
        for chunk in client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": "Say SDK ok"}],
            stream=True,
        )
        if chunk.choices
    )
    assert_expected_text(chat_stream_text, "OpenAI Chat stream")

    response = client.responses.create(model=MODEL, input="Say SDK ok", store=False)
    assert_expected_text(response.output_text, "OpenAI Responses")

    response_stream_text = "".join(
        event.delta
        for event in client.responses.create(
            model=MODEL,
            input="Say SDK ok",
            store=False,
            stream=True,
        )
        if event.type == "response.output_text.delta"
    )
    assert_expected_text(response_stream_text, "OpenAI Responses stream")

    tool_response = client.responses.create(
        model=MODEL,
        input="Read the README",
        store=False,
        tools=[{
            "type": "function",
            "name": "Read",
            "description": "Read a local file",
            "parameters": READ_TOOL_SCHEMA,
        }],
        tool_choice={"type": "function", "name": "Read"},
    )
    tool_calls = [item for item in tool_response.output if item.type == "function_call"]
    assert tool_calls and tool_calls[0].name == "Read", "OpenAI function call decode failed"
    assert_read_arguments(tool_calls[0].arguments, "OpenAI")


def run_anthropic_smoke(base_url: str) -> None:
    """验证 Anthropic 文本、流式和 tool use。

    参数为服务根 URL；无返回值。
    """
    client = Anthropic(api_key="test-key", base_url=base_url)
    messages = [{"role": "user", "content": "Say SDK ok"}]
    message = client.messages.create(model=MODEL, max_tokens=128, messages=messages)
    assert_expected_text(message.content[0].text, "Anthropic Messages")

    count = client.messages.count_tokens(model=MODEL, messages=[{
        "role": "user",
        "content": "Count this",
    }])
    assert count.input_tokens > 0, "Anthropic token count decode failed"

    with client.messages.stream(
        model=MODEL,
        max_tokens=128,
        messages=messages,
    ) as stream:
        stream_text = "".join(stream.text_stream)
    assert_expected_text(stream_text, "Anthropic Messages stream")

    tool_message = client.messages.create(
        model=MODEL,
        max_tokens=128,
        messages=[{"role": "user", "content": "Read the README"}],
        tools=[{
            "name": "Read",
            "description": "Read a local file",
            "input_schema": READ_TOOL_SCHEMA,
        }],
        tool_choice={"type": "tool", "name": "Read"},
    )
    tool_blocks = [block for block in tool_message.content if block.type == "tool_use"]
    assert tool_blocks and tool_blocks[0].name == "Read", "Anthropic tool decode failed"
    assert_read_arguments(tool_blocks[0].input, "Anthropic")


def main() -> None:
    """运行两个 Python 官方 SDK smoke；无参数及返回值。"""
    base_url = os.environ["GEMINI2API_BASE_URL"].rstrip("/")
    run_openai_smoke(base_url)
    run_anthropic_smoke(base_url)
    print("sdk-smoke.py PASS openai=text,stream,tool anthropic=text,stream,tool")


if __name__ == "__main__":
    main()
