// `design-canvas-mcp doctor` — §5.7 of documentation/mcp-onboarding-update.md.
// One-page health check. Exits 0 if all pass, 1 otherwise.

import { access, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import * as api from "./api-client.js";

interface Check {
  label: string;
  ok: boolean;
  detail: string;
}

const home = homedir();

async function checkDcApp(): Promise<Check> {
  try {
    await api.listRoutes();
    return { label: "Design Canvas Mac app reachable", ok: true, detail: `${api.getBaseUrl()} responded` };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      label: "Design Canvas Mac app reachable",
      ok: false,
      detail: `Could not reach ${api.getBaseUrl()} (${msg.slice(0, 80)}). Open the Design Canvas Mac app.`,
    };
  }
}

async function checkAuthToken(): Promise<Check> {
  const path = api.getTokenPath();
  try {
    await access(path);
    return { label: "API auth token present", ok: true, detail: path };
  } catch {
    return {
      label: "API auth token present",
      ok: false,
      detail: `Missing ${path}. Launch the Design Canvas Mac app once — it will generate the token.`,
    };
  }
}

async function checkConfig(label: string, path: string): Promise<Check> {
  try {
    await access(path);
    const raw = await readFile(path, "utf-8");
    if (raw.trim() === "") {
      return { label, ok: false, detail: `${path} exists but is empty.` };
    }
    const parsed = JSON.parse(raw) as { mcpServers?: Record<string, { command?: string; args?: string[] }> };
    const dc = parsed.mcpServers?.["design-canvas"];
    if (!dc) {
      return { label, ok: false, detail: `${path} exists but has no design-canvas entry. Run: design-canvas-mcp install` };
    }

    // Validate that the configured entry can actually spawn. npx invocations
    // are valid by definition; absolute-path entries must still exist on disk.
    const command = dc.command ?? "";
    const args = dc.args ?? [];
    if (command !== "npx") {
      // Validate command itself if absolute.
      if (command.startsWith("/") && !(await pathExists(command))) {
        return {
          label,
          ok: false,
          detail: `design-canvas entry in ${path} points at ${command} which does not exist. Run: design-canvas-mcp repair`,
        };
      }
      // Validate JS entry (first absolute arg).
      const jsEntry = args.find((a) => a.startsWith("/"));
      if (jsEntry && !(await pathExists(jsEntry))) {
        return {
          label,
          ok: false,
          detail: `design-canvas entry in ${path} points at ${jsEntry} which does not exist. Run: design-canvas-mcp repair`,
        };
      }
    }

    return { label, ok: true, detail: `design-canvas entry valid in ${path}` };
  } catch {
    return { label, ok: false, detail: `${path} not found or unreadable. Run: design-canvas-mcp install` };
  }
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

function checkNodeVersion(): Check {
  const raw = process.versions.node;
  const major = parseInt(raw.split(".")[0] ?? "0", 10);
  if (major >= 20) {
    return { label: "Node ≥ 20", ok: true, detail: `v${raw}` };
  }
  return { label: "Node ≥ 20", ok: false, detail: `v${raw} is too old. Upgrade to Node 20 or newer.` };
}

export async function runDoctor(): Promise<number> {
  const checks: Check[] = [
    checkNodeVersion(),
    await checkDcApp(),
    await checkAuthToken(),
    await checkConfig("Claude Code config has design-canvas", join(home, ".claude.json")),
    await checkConfig("Cursor config has design-canvas", join(home, ".cursor", "mcp.json")),
  ];

  const maxLabel = Math.max(...checks.map((c) => c.label.length));
  for (const c of checks) {
    const mark = c.ok ? "✅" : "❌";
    process.stderr.write(`${mark}  ${c.label.padEnd(maxLabel)}  ${c.detail}\n`);
  }
  process.stderr.write("\n");

  const failed = checks.filter((c) => !c.ok);
  if (failed.length === 0) {
    process.stderr.write("All checks passed. Design Canvas is ready.\n");
    return 0;
  }
  process.stderr.write(`${failed.length} check(s) failed. See the messages above for next steps.\n`);
  return 1;
}
