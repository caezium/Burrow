/**
 * Multi-user safety primitives for the iMessage agent: owner authorization
 * (also the reply-loop guard), reply-length cap, and a rolling-window rate
 * limiter. Pure and injectable so they're testable without the SDK.
 */

export function digits(s: string): string {
  return (s ?? "").replace(/\D/g, "");
}

/** True only for the configured owner's number (suffix match tolerates formatting). */
export function isAuthorized(senderId: string, ownerDigits: string): boolean {
  const d = digits(senderId);
  const o = digits(ownerDigits);
  if (!d || !o) return false;
  return d === o || d.endsWith(o) || o.endsWith(d);
}

export function capReply(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1).trimEnd() + "…";
}

export class RateLimiter {
  private hits: number[] = [];
  constructor(private max: number, private windowMs: number) {}

  /** Record and allow if under the cap for the rolling window; else block. */
  allow(nowMs: number): boolean {
    const cutoff = nowMs - this.windowMs;
    while (this.hits.length && this.hits[0] <= cutoff) this.hits.shift();
    if (this.hits.length >= this.max) return false;
    this.hits.push(nowMs);
    return true;
  }
}
