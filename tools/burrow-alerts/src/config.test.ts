import { test, expect } from "bun:test";
import { resolveLLM } from "./config.ts";

test("resolveLLM reads a named provider from env", () => {
  expect(resolveLLM({ BURROW_LLM_PROVIDER: "openrouter", BURROW_LLM_KEY: "k", BURROW_LLM_MODEL: "m" }))
    .toEqual({ provider: "openrouter", apiKey: "k", model: "m" });
});

test("resolveLLM reads openai-compat with a base URL from env", () => {
  expect(resolveLLM({ BURROW_LLM_PROVIDER: "openai-compat", BURROW_LLM_KEY: "k", BURROW_LLM_MODEL: "m", BURROW_LLM_BASEURL: "http://x/v1" }))
    .toEqual({ provider: "openai-compat", baseUrl: "http://x/v1", apiKey: "k", model: "m" });
});

test("resolveLLM falls back to the config value when env is absent", () => {
  expect(resolveLLM({}, { provider: "anthropic", apiKey: "a", model: "c" }))
    .toEqual({ provider: "anthropic", apiKey: "a", model: "c" });
});

test("resolveLLM defaults to the local claude CLI when nothing is set", () => {
  expect(resolveLLM({})).toEqual({ provider: "claude-cli" });
});
