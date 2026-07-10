import { test, expect } from "bun:test";
import { READONLY_TOOL_NAMES, READONLY_TOOL_SPECS, makeBurrowExec } from "./burrow-tools.ts";

test("read-only tool specs exclude destructive and slow tools", () => {
  expect(READONLY_TOOL_NAMES).toContain("burrow_snapshot");
  expect(READONLY_TOOL_NAMES).not.toContain("burrow_clean");     // destructive
  expect(READONLY_TOOL_NAMES).not.toContain("burrow_uninstall"); // destructive
  expect(READONLY_TOOL_NAMES).not.toContain("burrow_analyze");   // 60-90s, blows budget
  // every spec is well-formed for an LLM tool definition
  for (const s of READONLY_TOOL_SPECS) {
    expect(typeof s.name).toBe("string");
    expect(typeof s.description).toBe("string");
    expect(typeof s.schema).toBe("object");
  }
});

test("burrow exec runs allowlisted tools and refuses everything else", async () => {
  const calls: any[] = [];
  const fakeMcp = { toolText: async (n: string, a: any) => { calls.push([n, a]); return '{"ok":true}'; } };
  const exec = makeBurrowExec(fakeMcp as any);

  expect(await exec("burrow_snapshot", {})).toBe('{"ok":true}');
  expect(calls).toEqual([["burrow_snapshot", {}]]);

  const refused = await exec("burrow_clean", {}); // destructive — must never run
  expect(refused).toMatch(/not allowed|read-only/i);
  expect(calls.length).toBe(1); // the destructive tool was NOT invoked
});
