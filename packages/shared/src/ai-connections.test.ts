import { describe, expect, it } from "vitest";
import { aiOpencodeProviderId, isAiConnectionCompatible } from "./ai-connections.js";

describe("AI connection compatibility", () => {
  it("names the OpenCode provider each provider is reached through", () => {
    // OpenRouter has its own OpenCode integration; a gateway arrives through the
    // provider the adapters synthesize from a base URL.
    expect(aiOpencodeProviderId("openrouter")).toBe("openrouter");
    expect(aiOpencodeProviderId("vilao")).toBe("openai_custom");
  });
  it("accepts a gateway on the harnesses that speak its protocol", () => {
    expect(isAiConnectionCompatible({ provider: "vilao", method: "api_key" }, "codex_local")).toBe(true);
    expect(isAiConnectionCompatible({ provider: "vilao", method: "api_key" }, "claude_local")).toBe(false);
  });
  it("requires an OpenCode model to sit in the provider's own namespace", () => {
    expect(isAiConnectionCompatible({ provider: "openrouter", method: "api_key" }, "opencode_local", "openrouter/some/model")).toBe(true);
    expect(isAiConnectionCompatible({ provider: "openrouter", method: "api_key" }, "opencode_local", "anthropic/model")).toBe(false);
    expect(isAiConnectionCompatible({ provider: "vilao", method: "api_key" }, "opencode_local", "openai_custom/gpt-4o-mini")).toBe(true);
    expect(isAiConnectionCompatible({ provider: "vilao", method: "api_key" }, "opencode_local", "vilao/gpt-4o-mini")).toBe(false);
  });
  it("keeps resolving a Paperclip Runner provider to the harness it runs", () => {
    const binding = { provider: "anthropic", method: "api_key", mode: "responsible_user" } as const;
    expect(isAiConnectionCompatible(binding, "paperclip_runner", "same-model", "acpx", "claude")).toBe(true);
    expect(isAiConnectionCompatible(binding, "paperclip_runner", "same-model", "acpx", "codex")).toBe(false);
  });
});
