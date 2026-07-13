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

test("isAuthorized rejects suffix collisions (the old endsWith bypass)", () => {
  const owner = "+15551234567"; // US, +1
  expect(isAuthorized("+1 (555) 123-4567", owner)).toBe(true);  // same number, formatted
  expect(isAuthorized("5551234567", owner)).toBe(true);         // bare 10-digit, +1 dropped
  expect(isAuthorized("1234567", owner)).toBe(false);           // 7-digit suffix — MUST NOT match
  expect(isAuthorized("4567", owner)).toBe(false);              // short suffix — MUST NOT match
  expect(isAuthorized("+8615551234567", owner)).toBe(false);    // owner digits as a suffix of a +86 number
});

test("isAuthorized matches email/handle owners exactly, case-insensitively", () => {
  const owner = "Owner@Example.com";
  expect(isAuthorized("owner@example.com", owner)).toBe(true);
  expect(isAuthorized("someone@example.com", owner)).toBe(false);
  expect(isAuthorized("example.com", owner)).toBe(false); // not a suffix match
});
