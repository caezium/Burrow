/**
 * Formatting only — turns Burrow's computed signals into short iMessage bodies.
 * No measurement happens here.
 */

import type { Disk, Forecast, Hog, TopProc } from "./burrow.ts";

export function gb(bytes: number): string {
  const g = bytes / 1e9;
  return g >= 10 ? `${Math.round(g)} GB` : `${g.toFixed(1)} GB`;
}

export function formatDiskAlert(root: Disk, forecast: Forecast | null, hogs: Hog[]): string {
  const freeBytes = root.total - root.used;
  const lines = [`⚠️ Burrow: disk ${root.used_percent.toFixed(0)}% full — ${gb(freeBytes)} free on ${root.mount}`];

  if (forecast && forecast.days_until_full != null) {
    const perDay = Math.abs(forecast.slope_bytes_per_day);
    lines.push(`📉 Filling ~${gb(perDay)}/day → full in ~${Math.round(forecast.days_until_full)} days`);
  }

  if (hogs.length) {
    lines.push(`💾 Top hogs (~/): ${hogs.map((h) => `${h.name} ${gb(h.size)}`).join(" · ")}`);
  } else {
    lines.push(`💾 (space-hog scan pending — open Burrow for the treemap)`);
  }
  return lines.join("\n");
}

export function formatCpuAlert(proc: TopProc, windowMinutes: number): string {
  return `🔥 Burrow: "${proc.name}" pegged CPU — peak ${proc.peak_cpu.toFixed(0)}% sustained over ${windowMinutes}m. Open Burrow to inspect or quit it.`;
}

/**
 * Weekly digest. Strips Markdown from Burrow's own report so it reads clean in
 * an iMessage bubble, and prepends a one-line forecast headline.
 */
export function formatDigest(report: string, forecast: Forecast | null): string {
  const clean = stripMarkdown(report);
  let head = "📊 Burrow weekly digest";
  if (forecast && forecast.days_until_full != null) {
    head += `\n📉 Disk trend: full in ~${Math.round(forecast.days_until_full)} days at current rate`;
  }
  return `${head}\n\n${clean}`.trim();
}

function stripMarkdown(md: string): string {
  return md
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/\*(.+?)\*/g, "$1")
    .replace(/^_(.*?)_$/gm, "$1")
    .replace(/^[-*+]\s+/gm, "• ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
