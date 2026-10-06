// `design-canvas-mcp install` — §5.6 of documentation/mcp-onboarding-update.md.
// Writes MCP server config to ~/.claude.json / ~/.cursor/mcp.json (user scope)
// or <cwd>/.claude.json / <cwd>/.cursor/mcp.json (project scope).
//
// Safety: atomic tmp+rename, symlink refusal, project-scope leak warning,
// absolute Node path (fixes the GUI-app PATH issue where npx isn't findable),
// deterministic target paths, conflict protection via --force.
//
// Exit codes:
//   0  success (≥1 target updated or already-installed)
//   1  fatal error (JSON parse, IO, unresolvable Node path)
//   2  project-scope target missing — user must create empty file first
//   3  existing non-matching entry without --force
//   4  symlinked target (security refusal)

import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  access,
  chmod,
  copyFile,
  lstat,
  mkdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
  open as fsOpen,
} from "node:fs/promises";

type ClientName = "claude-code" | "cursor";
type Scope = "user" | "project";

interface InstallArgs {
  scope: Scope;
  client: ClientName | "all";
  force: boolean;
  dryRun: boolean;
  absolute: boolean;
}

interface McpServerEntry {
  command: string;
  args: string[];
}

interface ConfigShape {
  mcpServers?: Record<string, McpServerEntry>;
  [key: string]: unknown;
}

interface ResolvedCommand {
  command: string;
  args: string[];
  resolvedAbsolute: boolean;
  warning?: string;
}

interface TargetResult {
  path: string;
  client: ClientName;
  status: "updated" | "already-installed" | "skipped" | "error";
  message: string;
  backup?: string;
  exitCode?: number;
}

export function parseArgs(argv: string[]): InstallArgs {
  const args: InstallArgs = { scope: "user", client: "all", force: false, dryRun: false, absolute: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--scope") {
      const v = argv[++i];
      if (v !== "user" && v !== "project") throw new Error(`--scope must be user or project, got: ${v}`);
      args.scope = v;
    } else if (a === "--client") {
      const v = argv[++i];
      if (v !== "claude-code" && v !== "cursor" && v !== "all") {
        throw new Error(`--client must be claude-code, cursor, or all, got: ${v}`);
      }
      args.client = v;
    } else if (a === "--force") {
      args.force = true;
    } else if (a === "--dry-run") {
      args.dryRun = true;
    } else if (a === "--absolute") {
      args.absolute = true;
    } else if (a.startsWith("--")) {
      throw new Error(`Unknown flag: ${a}`);
    }
  }
  return args;
}

export function targetPath(scope: Scope, client: ClientName, cwd = process.cwd(), home = homedir()): string {
  if (scope === "user") {
    return client === "claude-code" ? join(home, ".claude.json") : join(home, ".cursor", "mcp.json");
  }
  return client === "claude-code" ? join(cwd, ".claude.json") : join(cwd, ".cursor", "mcp.json");
}

// Default writes the dynamic `npx -y design-canvas-mcp@latest` form. Stable across
// workspace rotation, npm cache cleans, and version bumps. Use `--absolute` only
// when a GUI agent (Claude Desktop, Cursor.app) can't find `npx` on PATH —
// absolute-path entries rot when the resolved location disappears (Conductor
// workspace deletion, npx cache GC), which is the bug this default avoids.
export function resolveCommand(absolute = false): ResolvedCommand {
  if (!absolute) {
    return {
      command: "npx",
      args: ["-y", "design-canvas-mcp@latest"],
      resolvedAbsolute: false,
    };
  }

  try {
    const nodeBin = process.execPath;
    const require = createRequire(import.meta.url);
    const entry = require.resolve("design-canvas-mcp/dist/index.js");
    return { command: nodeBin, args: [entry], resolvedAbsolute: true };
  } catch { /* fall through */ }

  try {
    const nodeBin = process.execPath;
    const require = createRequire(import.meta.url);
    const entry = require.resolve("./index.js");
    return { command: nodeBin, args: [entry], resolvedAbsolute: true };
  } catch { /* fall through */ }

  throw new Error(
    "--absolute requested but could not resolve design-canvas-mcp/dist/index.js. " +
    "Install the package globally first: npm install -g design-canvas-mcp",
  );
}

function entriesEqual(a: McpServerEntry | undefined, b: McpServerEntry): boolean {
  if (!a) return false;
  if (a.command !== b.command) return false;
  if (a.args.length !== b.args.length) return false;
  return a.args.every((arg, i) => arg === b.args[i]);
}

async function safeStat(path: string) {
  try { return await lstat(path); } catch { return null; }
}

async function readJson(path: string): Promise<ConfigShape> {
  const raw = await readFile(path, "utf-8");
  if (raw.trim() === "") return {};
  try {
    return JSON.parse(raw) as ConfigShape;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Cannot parse ${path}: ${msg}. If the file contains comments, remove them — JSON doesn't support comments.`);
  }
}

async function atomicWrite(target: string, content: string, mode?: number): Promise<void> {
  const dir = dirname(target);
  await mkdir(dir, { recursive: true });
  const tmp = `${target}.tmp.${process.pid}.${Date.now()}`;
  let fh: Awaited<ReturnType<typeof fsOpen>> | null = null;
  try {
    fh = await fsOpen(tmp, "w", mode ?? 0o600);
    await fh.writeFile(content, "utf-8");
    await fh.sync();
    await fh.close();
    fh = null;
    if (mode !== undefined) await chmod(tmp, mode);
    await rename(tmp, target);
    // fsync containing dir so the rename is durable.
    try {
      const dfh = await fsOpen(dir, "r");
      try { await dfh.sync(); } finally { await dfh.close(); }
    } catch { /* some filesystems don't allow dir fsync; ignore */ }
  } catch (err) {
    if (fh) { try { await fh.close(); } catch { /* ignore */ } }
    try { await rm(tmp, { force: true }); } catch { /* ignore */ }
    throw err;
  }
}

async function backupOnce(target: string): Promise<string | null> {
  const ts = new Date().toISOString().replace(/:/g, "-").replace(/\..+/, "");
  const backup = `${target}.bak.${ts}`;
  try {
    await access(backup);
    return null; // already exists — skip duplicate backup
  } catch { /* good — doesn't exist */ }
  try {
    await copyFile(target, backup);
    return backup;
  } catch {
    return null;
  }
}

function formatWarnLeakMessage(targetPath: string, otherEntries: string[]): string {
  return (
    `WARNING: ${targetPath} already contains these MCP servers: ${otherEntries.join(", ")}.\n` +
    `  If you commit this file, your teammates will see them too.\n` +
    `  Review the file and remove anything personal before \`git commit\`.`
  );
}

async function installOne(
  path: string,
  client: ClientName,
  scope: Scope,
  cmd: ResolvedCommand,
  force: boolean,
  dryRun: boolean,
): Promise<TargetResult> {
  const desired: McpServerEntry = { command: cmd.command, args: cmd.args };

  // 1. symlink / lstat check
  const info = await safeStat(path);
  if (info?.isSymbolicLink()) {
    return { path, client, status: "error", message: `Refused: ${path} is a symlink.`, exitCode: 4 };
  }

  let existing: ConfigShape = {};
  let originalMode: number | undefined;
  let fileExists = false;

  if (info) {
    fileExists = true;
    const s = await stat(path);
    originalMode = s.mode & 0o777;
    try {
      existing = await readJson(path);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return { path, client, status: "error", message: msg, exitCode: 1 };
    }
  } else {
    if (scope === "project") {
      return {
        path,
        client,
        status: "error",
        message:
          `Refused: ${path} does not exist.\n` +
          `  For project scope, create an empty ${path} at your project root first.\n` +
          `  This prevents accidentally committing personal MCP configs.`,
        exitCode: 2,
      };
    }
  }

  const mcpServers = { ...(existing.mcpServers ?? {}) };
  const existingEntry = mcpServers["design-canvas"];

  if (existingEntry && entriesEqual(existingEntry, desired)) {
    return { path, client, status: "already-installed", message: `Already installed for ${client}: ${path}` };
  }

  if (existingEntry && !force) {
    return {
      path,
      client,
      status: "error",
      message:
        `Existing design-canvas entry differs in ${path}:\n` +
        `  current:  ${JSON.stringify(existingEntry)}\n` +
        `  proposed: ${JSON.stringify(desired)}\n` +
        `  Pass --force to overwrite, or remove the existing entry and rerun.`,
      exitCode: 3,
    };
  }

  mcpServers["design-canvas"] = desired;
  const merged: ConfigShape = { ...existing, mcpServers };
  const serialised = JSON.stringify(merged, null, 2) + "\n";

  // Project-scope leak warning.
  const otherEntries = Object.keys(mcpServers).filter((k) => k !== "design-canvas");
  if (scope === "project" && otherEntries.length > 0) {
    process.stderr.write(formatWarnLeakMessage(path, otherEntries) + "\n");
  }

  if (dryRun) {
    process.stderr.write(`--- DRY RUN diff for ${path} ---\n`);
    process.stderr.write(serialised);
    process.stderr.write(`--- end DRY RUN ---\n`);
    return { path, client, status: "updated", message: `Would update ${path}` };
  }

  // Backup once (only if file existed before this run)
  let backup: string | null = null;
  if (fileExists) {
    backup = await backupOnce(path);
  }

  try {
    await atomicWrite(path, serialised, originalMode);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { path, client, status: "error", message: `Write failed for ${path}: ${msg}`, exitCode: 1 };
  }

  const suffix = backup ? ` (backed up to ${backup})` : fileExists ? "" : " (new file)";
  return { path, client, status: "updated", message: `Updated ${path}${suffix}`, backup: backup ?? undefined };
}

export async function runInstall(argv: string[]): Promise<number> {
  let args: InstallArgs;
  try {
    args = parseArgs(argv);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    process.stderr.write(`Argument error: ${msg}\n`);
    return 1;
  }

  let cmd: ResolvedCommand;
  try {
    cmd = resolveCommand(args.absolute);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    process.stderr.write(`${msg}\n`);
    return 1;
  }
  if (cmd.warning) process.stderr.write(`${cmd.warning}\n`);

  const clients: ClientName[] =
    args.client === "all" ? ["claude-code", "cursor"] : [args.client];

  const targets = clients.map((c) => ({ client: c, path: targetPath(args.scope, c) }));

  const results: TargetResult[] = [];
  for (const { client, path } of targets) {
    const r = await installOne(path, client, args.scope, cmd, args.force, args.dryRun);
    results.push(r);
  }

  const updated = results.filter((r) => r.status === "updated");
  const already = results.filter((r) => r.status === "already-installed");
  const errors = results.filter((r) => r.status === "error");

  process.stderr.write("\n");
  for (const r of results) process.stderr.write(`${r.message}\n`);
  process.stderr.write("\n");

  if (updated.length > 0 || already.length > 0) {
    process.stderr.write(`Installed Design Canvas MCP for: ${[...updated, ...already].map((r) => r.client).join(", ")}\n`);
    process.stderr.write(`Next step: QUIT AND REOPEN your agent — MCPs load at agent start\n`);
    process.stderr.write(`After restart, just say: "Show me what's on my Design Canvas"\n`);
    process.stderr.write(`Verify command: npx design-canvas-mcp doctor\n`);
  }

  if (errors.length > 0) {
    process.stderr.write(`\n${errors.length} target(s) could not be updated.\n`);
  }

  // Aggregate exit code: prefer success if anything worked, else the first error's exit code.
  if (updated.length > 0 || already.length > 0) return 0;
  const firstError = errors[0];
  return firstError?.exitCode ?? 1;
}

// Exports for tests.
export const __internals = {
  entriesEqual,
  readJson,
  atomicWrite,
  backupOnce,
  formatWarnLeakMessage,
  installOne,
};
