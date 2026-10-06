// §5.2 — verify prompt payloads carry the expected workflow keywords and shape.
// We assert against the exported __internals rather than spawning a full MCP
// server, which would be integration-heavy for this unit-level contract.

import { test } from "node:test";
import assert from "node:assert/strict";
import { __internals } from "../src/prompts.js";

const { SETUP_INSTRUCTION, VERIFY_INSTRUCTION, START_DESIGN_INSTRUCTION } = __internals;

test("setup instruction mentions the load-bearing steps", () => {
  assert.match(SETUP_INSTRUCTION, /list_routes/);
  assert.match(SETUP_INSTRUCTION, /package\.json/);
  assert.match(SETUP_INSTRUCTION, /dev server/);
  assert.match(SETUP_INSTRUCTION, /never guess|never run|never invent|Never guess/);
});

test("verify instruction references the critique inputs", () => {
  assert.match(VERIFY_INSTRUCTION, /capture_canvas/);
  assert.match(VERIFY_INSTRUCTION, /design-intent\.md/);
  assert.match(VERIFY_INSTRUCTION, /Spacing|spacing/);
  assert.match(VERIFY_INSTRUCTION, /Typography|typography/);
  assert.match(VERIFY_INSTRUCTION, /Colour|colour|Color|color/);
});

test("start-design instruction chains intent → patterns → generate → capture → critique", () => {
  assert.match(START_DESIGN_INSTRUCTION, /design-intent\.md/);
  assert.match(START_DESIGN_INSTRUCTION, /design-system\.md/);
  assert.match(START_DESIGN_INSTRUCTION, /list_routes/);
  assert.match(START_DESIGN_INSTRUCTION, /capture_canvas/);
});

test("no instruction is empty or suspiciously short", () => {
  assert.ok(SETUP_INSTRUCTION.length > 400);
  assert.ok(VERIFY_INSTRUCTION.length > 400);
  assert.ok(START_DESIGN_INSTRUCTION.length > 400);
});
