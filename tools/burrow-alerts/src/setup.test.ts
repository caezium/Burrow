import { test, expect } from "bun:test";
import { assembleConfig, type SetupParts } from "./setup.ts";

test("assembleConfig builds a delivery+llm config from parts", () => {
  const cfg = assembleConfig({
    recipient: "+8613410272240",
    projectId: "p-1",
    projectSecret: "s-1",
    llm: { provider: "openrouter", apiKey: "sk-or", model: "anthropic/claude-sonnet-5" },
  });
  expect(cfg.recipient).toBe("+8613410272240");
  expect(cfg.projectId).toBe("p-1");
  expect(cfg.projectSecret).toBe("s-1");
  expect(cfg.llm).toEqual({ provider: "openrouter", apiKey: "sk-or", model: "anthropic/claude-sonnet-5" });
});

test("assembleConfig defaults llm to claude-cli when none is given (alerts-only still fine)", () => {
  const cfg = assembleConfig({ recipient: "+8613410272240", projectId: "p", projectSecret: "s" });
  expect(cfg.llm).toEqual({ provider: "claude-cli" });
});

test("assembleConfig rejects a missing recipient", () => {
  expect(() => assembleConfig({ recipient: "", projectId: "p", projectSecret: "s" } as SetupParts)).toThrow(/recipient/i);
});

test("assembleConfig rejects cloud creds that are half-filled", () => {
  expect(() => assembleConfig({ recipient: "+1", projectId: "p" } as SetupParts)).toThrow(/secret/i);
});
