/**
 * BurrowMCP lifecycle: a missing Burrow.app must surface as a normal rejection, NOT an uncaught
 * 'error' that bypasses every .catch and (in the long-lived agent) becomes a crash loop.
 */
import { test, expect } from "bun:test";

// Point at a path that cannot exist BEFORE importing the module (BURROW_BIN is read at load).
process.env.BURROW_BIN = "/definitely/not/real/burrow-binary-xyz-does-not-exist";
const { BurrowMCP } = await import("./burrow.ts");

test("a missing burrow binary rejects the call instead of throwing uncaught", async () => {
  const mcp = new BurrowMCP();
  // Spawn ENOENT fires 'error' async → die() rejects `ready` and all pending calls.
  await expect(mcp.toolText("burrow_snapshot")).rejects.toThrow();
  await mcp.close();
});

test("further calls after death reject fast and don't hang", async () => {
  const mcp = new BurrowMCP();
  await expect(mcp.toolText("burrow_snapshot")).rejects.toThrow();
  // Second call after the child is dead: immediate rejection, no 15s timeout wait.
  const t0 = Date.now();
  await expect(mcp.toolText("burrow_disk_forecast")).rejects.toThrow();
  expect(Date.now() - t0).toBeLessThan(1_000);
  await mcp.close();
});
