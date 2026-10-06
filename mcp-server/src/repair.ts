// `design-canvas-mcp repair` — detect stale absolute-path entries in
// ~/.claude.json and ~/.cursor/mcp.json and rewrite them to the safe
// `npx -y design-canvas-mcp@latest` form. Atomic + backup, mirrors install.ts.

import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { __internals, targetPath } from "./install.js";

const { atomicWrite, backupOnce, readJson } = __internals;

type ClientName = "claude-code" | "cursor";

interface McpEntry {
  command: string;
  args: string[];
}

interface RepairResult {
  client: ClientName;
  path: string;
  status: "rewritten" | "healthy" | "missing-config" | "no-entry" | "error";
  message: string;
  backup?: string;
}

const SAFE_ENTRY: McpEntry = {
  command: "npx",
  args: ["-y", "design-canvas-mcp@latest"],
};

function isSafeEntry(entry: McpEntry): boolean {
  return (
    entry.command === "npx" &&
    entry.args.length >= 2 &&
    entry.args[0] === "-y" &&
    entry.args[1].startsWith("design-canvas-mcp")
  );
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

async function repairOne(client: ClientName, path: string): Promise<RepairResult> {
  if (!(await pathExists(path))) {
    return {
      client,
      path,
      status: "missing-config",
      message: `${path} does not exist — nothing to repair.`,
    };
  }

  let parsed: { mcpServers?: Record<string, McpEntry> };
  try {
    parsed = await readJson(path) as { mcpServers?: Record<string, McpEntry> };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { client, path, status: "error", message: `${path}: ${msg}` };
  }

  const entry = parsed.mcpServers?.["design-canvas"];
  if (!entry) {
    return {
      client,
      path,
      status: "no-entry",
      message: `${path}: no design-canvas entry — run 'design-canvas-mcp install' to add one.`,
    };
  }

  if (isSafeEntry(entry)) {
    return {
      client,
      path,
      status: "healthy",
      message: `${path}: already using npx form — no action needed.`,
    };
  }

  // Absolute-path entry. Healthy iff the JS entry (args[0]) still exists on disk.
  const jsEntry = entry.args[0];
  if (jsEntry && (await pathExists(jsEntry))) {
    return {
      client,
      path,
      status: "healthy",
      message: `${path}: absolute path still resolves (${jsEntry}) — no action needed.`,
    };
  }

  // Stale — rewrite.
  const merged = { ...parsed, mcpServers: { ...(parsed.mcpServers ?? {}), "design-canvas": SAFE_ENTRY } };
  const serialised = JSON.stringify(merged, null, 2) + "\n";
  const backup = await backupOnce(path);
  try {
    await atomicWrite(path, serialised);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { client, path, status: "error", message: `${path}: write failed — ${msg}` };
  }

  return {
    client,
    path,
    status: "rewritten",
    message: `${path}: stale entry (${entry.command} ${entry.args.join(" ")}) rewritten to npx form${backup ? ` (backup: ${backup})` : ""}.`,
    backup: backup ?? undefined,
  };
}

export async function runRepair(): Promise<number> {
  const home = homedir();
  const targets: { client: ClientName; path: string }[] = [
    { client: "claude-code", path: targetPath("user", "claude-code", process.cwd(), home) },
    { client: "cursor", path: targetPath("user", "cursor", process.cwd(), home) },
  ];

  const results: RepairResult[] = [];
  for (const { client, path } of targets) {
    results.push(await repairOne(client, path));
  }

  process.stderr.write("\n");
  for (const r of results) {
    const mark =
      r.status === "rewritten" ? "🔧" :
      r.status === "healthy" ? "✅" :
      r.status === "error" ? "❌" :
      "⚪";
    process.stderr.write(`${mark}  ${r.message}\n`);
  }
  process.stderr.write("\n");

  const rewritten = results.filter((r) => r.status === "rewritten");
  const errors = results.filter((r) => r.status === "error");

  if (rewritten.length > 0) {
    process.stderr.write(`Rewrote ${rewritten.length} stale entr${rewritten.length === 1 ? "y" : "ies"}.\n`);
    process.stderr.write(`Next step: QUIT AND REOPEN your agent — MCPs load at agent start.\n`);
  } else if (errors.length === 0) {
    process.stderr.write(`Nothing to repair.\n`);
  }

  if (errors.length > 0) return 1;
  return 0;
}

// Exports for tests.
export const __testInternals = { repairOne, isSafeEntry, SAFE_ENTRY };
