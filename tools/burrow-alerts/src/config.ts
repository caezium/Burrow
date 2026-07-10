/**
 * LLM provider resolution. Precedence: env (how the Swift app passes config to
 * the bundled sidecar) → config.local.json value → local `claude` CLI default.
 */

import type { LLMConfig } from "./llm.ts";

type Env = Record<string, string | undefined>;

export function resolveLLM(env: Env, fromConfig?: LLMConfig): LLMConfig {
  const p = env.BURROW_LLM_PROVIDER;
  if (p) {
    const apiKey = env.BURROW_LLM_KEY ?? "";
    const model = env.BURROW_LLM_MODEL ?? "";
    switch (p) {
      case "openrouter":
      case "openai":
        return { provider: p, apiKey, model };
      case "openai-compat":
        return { provider: p, baseUrl: env.BURROW_LLM_BASEURL ?? "", apiKey, model };
      case "anthropic":
        return { provider: p, apiKey, model };
      case "claude-cli":
        return { provider: "claude-cli", ...(env.BURROW_LLM_MODEL ? { model } : {}) };
    }
  }
  return fromConfig ?? { provider: "claude-cli" };
}
