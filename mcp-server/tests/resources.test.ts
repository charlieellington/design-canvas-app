// §5.3 — resource read behaviour. Uses a tmp project dir; covers: file exists,
// file missing (→ friendly not-found), symlink refusal.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, symlink, rm, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { __internals } from "../src/resources.js";

const { readIfSafe, findFirst, INTENT_CANDIDATES, SYSTEM_CANDIDATES, INTENT_NOT_FOUND, SYSTEM_NOT_FOUND } =
  __internals;

async function makeProjectDir(): Promise<string> {
  return await mkdtemp(join(tmpdir(), "dc-mcp-test-"));
}

test("readIfSafe returns file contents for a plain file", async () => {
  const dir = await makeProjectDir();
  try {
    const path = join(dir, "note.md");
    await writeFile(path, "# hello\n", "utf-8");
    const content = await readIfSafe(path);
    assert.equal(content, "# hello\n");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("readIfSafe refuses symlinks — security defence", async () => {
  const dir = await makeProjectDir();
  try {
    const realPath = join(dir, "real.md");
    const linkPath = join(dir, "link.md");
    await writeFile(realPath, "secret", "utf-8");
    await symlink(realPath, linkPath);
    const content = await readIfSafe(linkPath);
    assert.equal(content, null, "symlinked path must be refused");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("readIfSafe returns null when file is missing", async () => {
  const dir = await makeProjectDir();
  try {
    const content = await readIfSafe(join(dir, "does-not-exist.md"));
    assert.equal(content, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("findFirst returns first candidate hit", async () => {
  const dir = await makeProjectDir();
  try {
    await writeFile(join(dir, INTENT_CANDIDATES[0]), "# intent", "utf-8");
    const content = await findFirst([dir], INTENT_CANDIDATES);
    assert.equal(content, "# intent");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("findFirst falls back across candidates", async () => {
  const dir = await makeProjectDir();
  try {
    // only the second candidate exists
    await mkdir(join(dir, "docs"), { recursive: true });
    await writeFile(join(dir, SYSTEM_CANDIDATES[1]), "# system", "utf-8");
    const content = await findFirst([dir], SYSTEM_CANDIDATES);
    assert.equal(content, "# system");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("findFirst returns null when no candidates match", async () => {
  const dir = await makeProjectDir();
  try {
    const content = await findFirst([dir], INTENT_CANDIDATES);
    assert.equal(content, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("not-found payloads are non-empty and actionable", () => {
  assert.ok(INTENT_NOT_FOUND.length > 80);
  assert.match(INTENT_NOT_FOUND, /design-intent\.md/);
  assert.ok(SYSTEM_NOT_FOUND.length > 80);
  assert.match(SYSTEM_NOT_FOUND, /design-system\.md/);
});
