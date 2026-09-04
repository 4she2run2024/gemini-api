/**
 * 用途：使用 Google Gen AI 官方 Node SDK 验证文本、流式和 function call。
 * 使用方法：在含 @google/genai 的隔离目录内运行本文件副本。
 */

import {GoogleGenAI} from "@google/genai";

const EXPECTED_TEXT = "Gemini2API SDK ok";
const MODEL = "gemini-3.8-flash";

/** 功能：断言 SDK 解码文本；参数：文本和标签；返回：无。 */
function assert_expected_text(text, label) {
  if (text !== EXPECTED_TEXT) {
    throw new Error(`${label} text mismatch`);
  }
}

/**
 * 功能：运行 Gemini SDK 文本、流式和 function call 验收。
 * 参数：无。返回：无。
 */
async function main() {
  const base_url = process.env.GEMINI2API_BASE_URL;
  if (!base_url) throw new Error("GEMINI2API_BASE_URL is required");

  const client = new GoogleGenAI({
    apiKey: "test-key",
    httpOptions: {
      baseUrl: base_url.replace(/\/$/, ""),
      headers: {"x-goog-api-key": "test-key"},
    },
  });

  const response = await client.models.generateContent({
    model: MODEL,
    contents: "Say SDK ok",
  });
  assert_expected_text(response.text ?? "", "Gemini GenerateContent");

  let stream_text = "";
  const stream = await client.models.generateContentStream({
    model: MODEL,
    contents: "Say SDK ok",
  });
  for await (const chunk of stream) stream_text += chunk.text ?? "";
  assert_expected_text(stream_text, "Gemini GenerateContent stream");

  const tool_response = await client.models.generateContent({
    model: MODEL,
    contents: "Read the README",
    config: {
      tools: [{
        functionDeclarations: [{
          name: "Read",
          description: "Read a local file",
          parametersJsonSchema: {
            type: "object",
            properties: {file_path: {type: "string"}},
            required: ["file_path"],
            additionalProperties: false,
          },
        }],
      }],
      toolConfig: {
        functionCallingConfig: {
          mode: "ANY",
          allowedFunctionNames: ["Read"],
        },
      },
    },
  });
  const function_calls = tool_response.functionCalls ?? [];
  if (function_calls[0]?.name !== "Read") {
    throw new Error("Gemini function call decode failed");
  }
  if (function_calls[0]?.args?.file_path !== "README.md") {
    throw new Error("Gemini function arguments decode failed");
  }

  console.log("gemini-sdk-smoke PASS text,stream,tool");
}

await main();
