// repair subcommand — covers the main bug class: stale absolute-path entries
// pointing at deleted Conductor workspaces or GC'd npx caches.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { __testInternals } from "../src/repair.js";

const { repairOne, isSafeEntry, SAFE_ENTRY } = __testInternals;

async function makeTmp(): Promise<string> {
  return await mkdtemp(join(tmpdir(), "dc-repair-test-"));
}

test("isSafeEntry recognises npx -y design-canvas-mcp form", () => {
  assert.equal(isSafeEntry({ command: "npx", args: ["-y", "design-canvas-mcp"] }), true);
  assert.equal(isSafeEntry({ command: "npx", args: ["-y", "design-canvas-mcp@latest"] }), true);
  assert.equal(isSafeEntry({ command: "npx", args: ["-y", "design-canvas-mcp@0.4.0"] }), true);
});

test("isSafeEntry rejects absolute-path entries", () => {
  assert.equal(isSafeEntry({ command: "/usr/bin/node", args: ["/foo/dist/index.js"] }), false);
  assert.equal(isSafeEntry({ command: "node", args: ["dist/index.js"] }), false);
  assert.equal(isSafeEntry({ command: "npx", args: ["other-pkg"] }), false);
});

test("repairOne rewrites stale absolute-path entry", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    const stalePath = "/Users/nobody/deleted-workspace/mcp-server/dist/index.js";
    await writeFile(
      path,
      JSON.stringify({
        mcpServers: {
          "design-canvas": { command: "/abs/node", args: [stalePath] },
          other: { command: "/x", args: [] },
        },
      }, null, 2),
      "utf-8",
    );

    const result = await repairOne("claude-code", path);
    assert.equal(result.status, "rewritten");
    assert.ok(result.backup, "backup should be created");

    const after = JSON.parse(await readFile(path, "utf-8"));
    assert.deepEqual(after.mcpServers["design-canvas"], SAFE_ENTRY);
    // Other entries preserved.
    assert.deepEqual(after.mcpServers.other, { command: "/x", args: [] });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("repairOne leaves healthy npx entry alone", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(
      path,
      JSON.stringify({
        mcpServers: {
          "design-canvas": { command: "npx", args: ["-y", "design-canvas-mcp@latest"] },
        },
      }, null, 2),
      "utf-8",
    );

    const result = await repairOne("claude-code", path);
    assert.equal(result.status, "healthy");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("repairOne leaves healthy absolute-path entry alone (path still exists)", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    // Use a real path that exists — the test file itself.
    const realEntry = join(dir, "fake-dist.js");
    await writeFile(realEntry, "// fake mcp entry", "utf-8");
    await writeFile(
      path,
      JSON.stringify({
        mcpServers: {
          "design-canvas": { command: "/abs/node", args: [realEntry] },
        },
      }, null, 2),
      "utf-8",
    );

    const result = await repairOne("claude-code", path);
    assert.equal(result.status, "healthy");

    const after = JSON.parse(await readFile(path, "utf-8"));
    assert.equal(after.mcpServers["design-canvas"].args[0], realEntry, "should not have rewritten");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("repairOne reports missing config gracefully", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, "does-not-exist.json");
    const result = await repairOne("claude-code", path);
    assert.equal(result.status, "missing-config");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("repairOne reports no-entry when config has no design-canvas key", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(path, JSON.stringify({ mcpServers: { other: { command: "x", args: [] } } }), "utf-8");
    const result = await repairOne("claude-code", path);
    assert.equal(result.status, "no-entry");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("repairOne preserves sibling top-level keys", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(
      path,
      JSON.stringify({
        userSettings: { theme: "dark" },
        mcpServers: {
          "design-canvas": { command: "/abs/node", args: ["/nope/dist/index.js"] },
        },
      }, null, 2),
      "utf-8",
    );
    await repairOne("claude-code", path);
    const after = JSON.parse(await readFile(path, "utf-8"));
    assert.deepEqual(after.userSettings, { theme: "dark" });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("repairOne creates backup with .bak. suffix", async () => {
  const dir = await makeTmp();
  try {
    const path = join(dir, ".claude.json");
    await writeFile(
      path,
      JSON.stringify({
        mcpServers: {
          "design-canvas": { command: "/abs/node", args: ["/nope/dist/index.js"] },
        },
      }),
      "utf-8",
    );
    const result = await repairOne("claude-code", path);
    assert.match(result.backup ?? "", /\.bak\./);
    // Backup file actually exists.
    await stat(result.backup!);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
