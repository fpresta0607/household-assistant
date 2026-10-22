import assert from "node:assert/strict";
import { registerHooks } from "node:module";

// Recorded against OpenClaw 2026.9.4 (3a9d69db), history profile with recovery disabled.
export const HISTORY_TEXT_CASES = [
  ["<think>HIDDEN_INLINE</think>Visible", "Visible"],
  ["Visible<thinking>HIDDEN_UNCLOSED", "Visible"],
  ["<reasoning>HIDDEN_ONLY", ""],
  ['<tool_call>{"name":"exec","arguments":{"text":"HIDDEN_TOOL"}}</tool_call>Visible', "Visible"],
  ['[TOOL_CALL]tool => "exec", args => {"text":"HIDDEN"}[/TOOL_CALL]Visible', "Visible"],
  ["Use `<think>literal code</think>` and &lt;think&gt;literal text&lt;/think&gt;.",
    "Use `<think>literal code</think>` and &lt;think&gt;literal text&lt;/think&gt;."],
  ["Before\n```xml\n<think>literal example</think>\n```\nAfter",
    "Before\n```xml\n<think>literal example</think>\n```\nAfter"],
];

export function mockHistoryTextSdk() {
  const source = `
    import assert from "node:assert/strict";
    const cases = new Map(${JSON.stringify(HISTORY_TEXT_CASES)});
    export function sanitizeAssistantVisibleTextWithProfile(text, profile, streaming) {
      assert.equal(profile, "history");
      assert.equal(streaming, true, "stored partial reasoning must not be recovered as visible text");
      return cases.get(text) ?? text;
    }
  `;
  const url = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`;
  return registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === "openclaw/plugin-sdk/text-chunking") {
        assert.ok(context.parentURL.endsWith("/household-family-room/family-history.js"));
        return { url, shortCircuit: true };
      }
      return nextResolve(specifier, context);
    },
  });
}
