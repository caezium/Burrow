/**
 * Bridges the provider brains (llm.ts) to Burrow's MCP server. Exposes the
 * READ-ONLY Burrow tools as LLM tool specs and an executor that calls them.
 * The allowlist is enforced HERE too (defense in depth): even if a model
 * hallucinates `burrow_clean`, the exec refuses it and never touches the tool.
 */

import type { ToolSpec, ToolExec } from "./llm.ts";

// Minimal MCP surface we need — satisfied by BurrowMCP (src/burrow.ts).
type ToolCaller = { toolText(name: string, args?: Record<string, unknown>, timeoutMs?: number): Promise<string> };

// Read-only, fast tools only. burrow_analyze is excluded (60-90s cold walk);
// clean/purge/uninstall/optimize/installer are excluded (destructive/gated).
const SPECS: ToolSpec[] = [
  { name: "burrow_snapshot", description: "Current system snapshot: disk usage %, free bytes, CPU load, memory, top processes, thermals, health score.", schema: { type: "object", properties: {} } },
  { name: "burrow_doctor", description: "Quick health checks (engine, Full Disk Access, memory pressure, disk headroom, backups) as ok/warn/fail.", schema: { type: "object", properties: {} } },
  { name: "burrow_disk_forecast", description: "Days until a volume fills, from free-space history, plus the bytes/day trend.", schema: { type: "object", properties: { days: { type: "integer" }, mount: { type: "string" } } } },
  { name: "burrow_top_processes", description: "Top processes by peak CPU% over the last N minutes.", schema: { type: "object", properties: { minutes: { type: "integer" }, limit: { type: "integer" } } } },
  { name: "burrow_process_usage", description: "Rank processes by cpu_time/peak_cpu/avg_cpu/peak_mem over a window (use for 'what's using my Mac').", schema: { type: "object", properties: { metric: { type: "string" }, minutes: { type: "integer" }, limit: { type: "integer" } } } },
  { name: "burrow_ports", description: "What's listening on which local network ports.", schema: { type: "object", properties: {} } },
  { name: "burrow_list_apps", description: "Installed applications.", schema: { type: "object", properties: {} } },
  { name: "burrow_info", description: "Host/hardware/OS info.", schema: { type: "object", properties: {} } },
  { name: "burrow_history", description: "Recent status history from Burrow's store.", schema: { type: "object", properties: {} } },
  { name: "burrow_report", description: "Weekly digest: cleanup summary, top energy users, disk forecast (Markdown).", schema: { type: "object", properties: { days: { type: "integer" } } } },
];

export const READONLY_TOOL_SPECS: ToolSpec[] = SPECS;
export const READONLY_TOOL_NAMES: string[] = SPECS.map((s) => s.name);
export const READONLY_MCP_TOOL_IDS: string[] = SPECS.map((s) => `mcp__burrow__${s.name}`);

const ALLOWED = new Set(READONLY_TOOL_NAMES);

/** A ToolExec that runs only read-only Burrow tools via the MCP server. */
export function makeBurrowExec(mcp: ToolCaller): ToolExec {
  return async (name, args) => {
    if (!ALLOWED.has(name)) {
      return `Tool "${name}" is not allowed (read-only mode).`;
    }
    try {
      return await mcp.toolText(name, args ?? {}, 30_000);
    } catch (e: any) {
      return `Tool "${name}" failed: ${e?.message ?? e}`;
    }
  };
}
