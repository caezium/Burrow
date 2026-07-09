import { test, expect } from "bun:test";
import { USE_CASES, onboardingText } from "./onboarding.ts";

test("onboarding surfaces concrete use-cases", () => {
  expect(USE_CASES.length).toBeGreaterThanOrEqual(3);
  const joined = USE_CASES.join(" ").toLowerCase();
  expect(joined).toContain("mac studio");   // the remote-machine story the user cares about
  expect(joined).toContain("disk");         // disk-full prevention
});

test("onboarding text notes Photon is free for one user and lists BYO-key providers", () => {
  const t = onboardingText().toLowerCase();
  expect(t).toContain("free");               // Photon: 1 user free
  expect(t).toContain("openrouter");
  expect(t).toContain("openai");
  expect(t).toMatch(/anthropic|claude/);
  expect(t).toContain("device code");        // automated Photon setup path
});
