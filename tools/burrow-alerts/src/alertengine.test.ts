import { test, expect } from "bun:test";
import { step, type ThresholdRule, type AlertState } from "./alertengine.ts";

const rule: ThresholdRule = { id: "disk", high: 90, low: 85, cooldownSeconds: 100 };

test("fires once per episode: hysteresis (high/low) + cooldown", () => {
  let s: AlertState = { firing: false, lastFiredTS: null };
  const at = (value: number, ts: number) => { const r = step(rule, value, ts, s); s = r.state; return r.fired; };

  expect(at(80, 0)).toBe(false);   // below high — quiet
  expect(at(92, 10)).toBe(true);   // cross high — fire
  expect(s.firing).toBe(true);
  expect(at(95, 20)).toBe(false);  // still high — no re-fire (same episode)
  expect(at(88, 30)).toBe(false);  // dip but above low — still firing, no re-arm
  expect(s.firing).toBe(true);

  expect(at(80, 40)).toBe(false);  // recover below low — episode ends (re-arm)
  expect(s.firing).toBe(false);

  expect(at(91, 50)).toBe(false);  // re-cross but within cooldown (50-10<100) — armed, silent
  expect(s.firing).toBe(true);
  at(80, 60);                       // recover again
  expect(at(91, 200)).toBe(true);  // re-cross after cooldown (200-10>100) — fire again
});
