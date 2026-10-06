// §5.6 — install subcommand matrix.
// Empty file, existing other MCPs preserved, existing design-canvas entry
// (matching vs differing), malformed JSON, project-scope missing file, symlinked target.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile, symlink, rm, mkdir, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  parseArgs,
  resolveCommand,
  targetPath,
  __internals,
} from "../src/install.js";

const { entriesEqual, readJson, atomicWrite, installOne } = __internals;

async function makeTmp(): Promise<string> {
  return await mkdtemp(join(tmpdir(), "dc-install-test-"));
}

// ---------- parseArgs ----------

test("parseArgs defaults", () => {
  const a = parseArgs([]);
  assert.equal(a.scope, "user");
  assert.equal(a.client, "all");
  assert.equal(a.force, false);
  assert.equal(a.dryRun, false);
  assert.equal(a.absolute, false);
});

test("parseArgs respects all flags", () => {
  const a = parseArgs(["--scope", "project", "--client", "cursor", "--force", "--dry-run", "--absolute"]);
  assert.deepEqual(a, { scope: "project", client: "cursor", force: true, dryRun: true, absolute: true });
});

test("parseArgs rejects unknown values", () => {
  assert.throws(() => parseArgs(["--scope", "global"]), /--scope must be/);
  assert.throws(() => parseArgs(["--client", "windsurf"]), /--client must be/);
  assert.throws(() => parseArgs(["--nope"]), /Unknown flag/);
});

// ---------- resolveCommand ----------

test("resolveCommand defaults to npx form (stable across workspace rotation)", () => {
  const cmd = resolveCommand();
  assert.equal(cmd.command, "npx");
  assert.deepEqual(cmd.args, ["-y", "design-canvas-mcp@latest"]);
  assert.equal(cmd.resolvedAbsolute, false);
  assert.equal(cmd.warning, undefined);
});

test("resolveCommand(false) explicit is identical to default", () => {
  assert.deepEqual(resolveCommand(false), resolveCommand());
});

test("resolveCommand(true) returns absolute path or throws clearly", () => {
  // From the test runtime, design-canvas-mcp may not be installable as a package
  // (we're inside the source tree). Either resolution succeeds (returns absolute
  // node + dist path) or it throws with a clear message — never silently falls
  // back to npx, which would mask user intent.
  try {
    const cmd = resolveCommand(true);
    assert.equal(cmd.resolvedAbsolute, true);
    assert.ok(cmd.command.length > 0 && cmd.command.startsWith("/"), `command should be absolute, got: ${cmd.command}`);
    assert.equal(cmd.args.length, 1);
    assert.ok(cmd.args[0].startsWith("/"), `entry path should be absolute, got: ${cmd.args[0]}`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    assert.match(msg, /--absolute requested but could not resolve/);
  }
});

// ---------- targetPath ----------

test("targetPath maps scope × client deterministically", () => {
  const home = "/home/test";
  const cwd = "/work/proj";
  assert.equal(targetPath("user", "claude-code", cwd, home), "/home/test/.claude.json");
  assert.equal(targetPath("user", "cursor", cwd, home), "/home/test/.cursor/mcp.json");
  assert.equal(targetPath("project", "claude-code", cwd, home), "/work/proj/.claude.json");
  assert.equal(targetPath("project", "cursor", cwd, home), "/work/proj/.cursor/mcp.json");
});

// ---------- entriesEqual ----------

test("entriesEqual handles undefined, match, and divergence", () => {
  const desired = { command: "/usr/bin/node", args: ["/foo/index.js"] };
  assert.equal(entriesEqual(undefined, desired), false);
  assert.equal(entriesEqual({ command: "/usr/bin/node", args: ["/foo/index.js"] }, desired), true);
  assert.equal(entriesEqual({ command: "/other/node", args: ["/foo/index.js"] }, desired), false);
  assert.equal(entriesEqual({ command: "/usr/bin/node", args: ["/other.js"] }, desired), false);
  assert.equal(entriesEqual({ command: "/usr/bin/node", args: [] }, desired), false);
});

// ---------- readJson ----------

test("readJson parses well-formed JSON", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, "config.json");
    await writeFile(path, '{"a":1,"mcpServers":{"foo":{}}}', "utf-8");
    const parsed = await readJson(path);
    assert.deepEqual(parsed, { a: 1, mcpServers: { foo: {} } });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("readJson returns {} for empty file", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, "empty.json");
    await writeFile(path, "", "utf-8");
    const parsed = await readJson(path);
    assert.deepEqual(parsed, {});
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("readJson throws with guidance for malformed JSON", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, "broken.json");
    await writeFile(path, "// comment\n{}", "utf-8");
    await assert.rejects(() => readJson(path), /Cannot parse/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// ---------- atomicWrite ----------

test("atomicWrite creates file with exact content and leaves no tmp", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, "out.json");
    await atomicWrite(path, '{"hello":1}\n', 0o600);
    const content = await readFile(path, "utf-8");
    assert.equal(content, '{"hello":1}\n');
    const s = await stat(path);
    assert.equal(s.mode & 0o777, 0o600);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// ---------- installOne (the heart) ----------

const desiredCmd = { command: "/abs/node", args: ["/abs/design-canvas-mcp/dist/index.js"], resolvedAbsolute: true };

test("installOne creates new user-scope file when missing", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    const result = await installOne(path, "claude-code", "user", desiredCmd, false, false);
    assert.equal(result.status, "updated");
    const content = JSON.parse(await readFile(path, "utf-8"));
    assert.deepEqual(content.mcpServers["design-canvas"], {
      command: "/abs/node",
      args: ["/abs/design-canvas-mcp/dist/index.js"],
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne preserves existing mcpServers entries", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(
      path,
      JSON.stringify({
        userSettings: { theme: "dark" },
        mcpServers: { other: { command: "/x", args: [] } },
      }, null, 2),
      "utf-8",
    );
    const result = await installOne(path, "claude-code", "user", desiredCmd, false, false);
    assert.equal(result.status, "updated");
    const content = JSON.parse(await readFile(path, "utf-8"));
    assert.deepEqual(content.userSettings, { theme: "dark" });
    assert.ok(content.mcpServers.other);
    assert.ok(content.mcpServers["design-canvas"]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne skips when entry already matches", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(
      path,
      JSON.stringify({ mcpServers: { "design-canvas": desiredCmd } }),
      "utf-8",
    );
    const result = await installOne(path, "claude-code", "user", desiredCmd, false, false);
    assert.equal(result.status, "already-installed");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne refuses overwrite without --force", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(
      path,
      JSON.stringify({
        mcpServers: { "design-canvas": { command: "/old", args: ["--legacy"] } },
      }),
      "utf-8",
    );
    const result = await installOne(path, "claude-code", "user", desiredCmd, false, false);
    assert.equal(result.status, "error");
    assert.equal(result.exitCode, 3);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne overwrites with --force", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(
      path,
      JSON.stringify({
        mcpServers: { "design-canvas": { command: "/old", args: ["--legacy"] } },
      }),
      "utf-8",
    );
    const result = await installOne(path, "claude-code", "user", desiredCmd, true, false);
    assert.equal(result.status, "updated");
    const content = JSON.parse(await readFile(path, "utf-8"));
    assert.equal(content.mcpServers["design-canvas"].command, desiredCmd.command);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne refuses project-scope when file is missing (exit 2)", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    const result = await installOne(path, "claude-code", "project", desiredCmd, false, false);
    assert.equal(result.status, "error");
    assert.equal(result.exitCode, 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne refuses symlinked target (exit 4)", async () => {
  const dir = await makeTmp();
  try {
    const real = join(dir, "real.json");
    const link = join(dir, ".claude.json");
    await writeFile(real, "{}", "utf-8");
    await symlink(real, link);
    const result = await installOne(link, "claude-code", "user", desiredCmd, false, false);
    assert.equal(result.status, "error");
    assert.equal(result.exitCode, 4);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne dry-run writes nothing", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    const result = await installOne(path, "claude-code", "user", desiredCmd, false, true);
    assert.equal(result.status, "updated");
    await assert.rejects(() => stat(path));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne reports parse errors clearly (exit 1)", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(path, "// comment\n{broken", "utf-8");
    const result = await installOne(path, "claude-code", "user", desiredCmd, false, false);
    assert.equal(result.status, "error");
    assert.equal(result.exitCode, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne backs up an existing file before first write", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(path, JSON.stringify({ mcpServers: {} }), "utf-8");
    const result = await installOne(path, "claude-code", "user", desiredCmd, false, false);
    assert.equal(result.status, "updated");
    assert.ok(result.backup, "a backup path should be recorded");
    assert.match(result.backup!, /\.bak\./);
    // Main file has new content
    const content = JSON.parse(await readFile(path, "utf-8"));
    assert.ok(content.mcpServers["design-canvas"]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("installOne preserves file mode", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(path, "{}", { encoding: "utf-8", mode: 0o644 });
    await installOne(path, "claude-code", "user", desiredCmd, false, false);
    const s = await stat(path);
    assert.equal(s.mode & 0o777, 0o644);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
