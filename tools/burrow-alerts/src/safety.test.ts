import { test, expect } from "bun:test";
import { isAuthorized, capReply, RateLimiter } from "./safety.ts";

test("RateLimiter allows up to max per window, blocks beyond, and recovers", () => {
  const rl = new RateLimiter(2, 1000); // 2 per 1000ms; time injected
  expect(rl.allow(0)).toBe(true);
  expect(rl.allow(100)).toBe(true);
  expect(rl.allow(200)).toBe(false);  // 3rd inside window
  expect(rl.allow(1201)).toBe(true);  // first two aged out
});

test("capReply truncates long replies with an ellipsis and leaves short ones", () => {
  expect(capReply("short", 800)).toBe("short");
  const out = capReply("a".repeat(900), 800);
  expect(out.length).toBe(800);
  expect(out.endsWith("…")).toBe(true);
});

test("isAuthorized accepts the owner's number (any formatting) and rejects others", () => {
  const owner = "8613410272240";
  expect(isAuthorized("+8613410272240", owner)).toBe(true);   // E.164
  expect(isAuthorized("8613410272240", owner)).toBe(true);    // bare
  expect(isAuthorized("+1 (555) 000-1111", owner)).toBe(false); // someone else
  expect(isAuthorized("", owner)).toBe(false);                 // empty sender
  expect(isAuthorized("+8613410272240", "")).toBe(false);     // no owner configured
});
