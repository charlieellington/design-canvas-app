// §5.8 — ghost-response audit.
// Point the MCP server at an unreachable URL; every tool handler must return a
// structured error with non-empty text. Never an empty response.

import { test } from "node:test";
import assert from "node:assert/strict";

// Redirect before importing the tools module (module-local constants now read lazily).
process.env.DESIGN_CANVAS_URL = "http://127.0.0.1:1";

const { handleListRoutes, handleAddRoute, handleRemoveRoute, handleCaptureCanvas } = await import(
  "../src/tools.js"
);

function assertStructuredError(result: Awaited<ReturnType<typeof handleListRoutes>>, toolName: string): void {
  assert.equal(result.isError, true, `${toolName}: isError must be true when DC is unreachable`);
  assert.ok(Array.isArray(result.content), `${toolName}: content must be an array`);
  assert.ok(result.content.length >= 1, `${toolName}: content must be non-empty`);
  const first = result.content[0];
  assert.equal(first.type, "text", `${toolName}: first content item must be text`);
  assert.ok(
    "text" in first && typeof first.text === "string" && first.text.length > 20,
    `${toolName}: error text must be a helpful sentence (>20 chars), got: ${JSON.stringify(first)}`,
  );
  assert.ok(
    "text" in first && /Design Canvas/.test(first.text),
    `${toolName}: error text should mention "Design Canvas" to guide the user, got: ${first.text}`,
  );
}

test("list_routes returns a structured error when DC is unreachable", async () => {
  const result = await handleListRoutes();
  assertStructuredError(result, "list_routes");
});

test("add_route returns a structured error when DC is unreachable", async () => {
  const result = await handleAddRoute({ path: "/example" });
  assertStructuredError(result, "add_route");
});

test("remove_route returns a structured error when DC is unreachable", async () => {
  const result = await handleRemoveRoute({ path: "/example" });
  assertStructuredError(result, "remove_route");
});

test("remove_route returns a specific error when no params provided", async () => {
  const result = await handleRemoveRoute({});
  assert.equal(result.isError, true);
  assert.ok(result.content.length >= 1);
  const first = result.content[0];
  assert.ok("text" in first && /[Mm]ust provide either 'id' or 'path'/.test(first.text));
});

test("capture_canvas returns a structured error when DC is unreachable", async () => {
  const result = await handleCaptureCanvas({});
  assertStructuredError(result, "capture_canvas");
});

test("capture_canvas with ids returns a structured error when DC is unreachable", async () => {
  const result = await handleCaptureCanvas({ ids: ["44D9F1FF-0034-4E4A-B9E1-7A59CBD2001D"] });
  assertStructuredError(result, "capture_canvas (ids)");
});
