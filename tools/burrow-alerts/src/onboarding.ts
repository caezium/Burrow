/**
 * Onboarding copy for "Burrow over iMessage". Sells the feature with concrete
 * use-cases, then explains the two BYO pieces: a Photon project (free for one
 * user; can be created automatically via device-code) and an LLM API key
 * (OpenRouter / OpenAI-compatible / Anthropic, or your local coding agent).
 */

export const USE_CASES: string[] = [
  "Manage a headless Mac Studio you can't walk over to — it texts you when something's wrong, and you text back to check on it.",
  "Catch a disk before it silently fills: get a text at 90% with the top space hogs and days-until-full, instead of finding out at 0 bytes.",
  "Ask your Mac from your phone — “what's pegging the CPU?”, “how much disk is left?”, “what's listening on port 3000?” — and get a real answer from Burrow's tools.",
  "Watch a remote build/CI box or a home server: a weekly cleanup digest and threshold alerts, delivered to iMessage, no dashboard to check.",
  "Keep tabs on a family member's or a client's Mac (with their say-so) — proactive health nudges without remoting in.",
];

const PROVIDERS = [
  "OpenRouter (one key, many models)",
  "OpenAI or any OpenAI-compatible endpoint",
  "Anthropic (Claude) API",
  "your local coding agent (the `claude` CLI you already log into)",
];

export function onboardingText(): string {
  return [
    "Burrow over iMessage — your Mac texts you, and answers when you text it.",
    "",
    "What it's for:",
    ...USE_CASES.map((u) => `• ${u}`),
    "",
    "Two quick things to set up:",
    "",
    "1) Delivery — a Photon project (this is what sends/receives the iMessages).",
    "   Photon is free for one user. Burrow can create the project for you",
    "   automatically via a device code (you approve once in the browser), or",
    "   paste an existing project's id + secret.",
    "",
    "2) Brain (only for the two-way 'ask your Mac' part) — bring your own API key:",
    ...PROVIDERS.map((p) => `   • ${p}`),
    "",
    "Alerts alone need no API key. The assistant only ever READS your Mac's",
    "health (it can't clean, delete, or change anything), and only answers you.",
  ].join("\n");
}

if (import.meta.main) console.log(onboardingText());
