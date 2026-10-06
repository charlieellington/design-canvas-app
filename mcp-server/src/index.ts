#!/usr/bin/env node

// Design Canvas MCP Server — enables AI coding agents to control the Design Canvas Mac app.
// stdio transport, spawned as a child process by Claude Code or Cursor.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  toolDefinitions,
  handleListRoutes,
  handleAddRoute,
  handleRemoveRoute,
  handleUpdateRoute,
  handleCaptureCanvas,
  handleListServers,
  handleListDocuments,
  handleAddDocument,
  handleRemoveDocument,
  handleListImages,
  handleAddImage,
  handleRemoveImage,
  handleAddFrames,
  handleListSections,
  handleAddSection,
  handleRemoveSection,
} from "./tools.js";
import { getSetupHint } from "./setup-hint.js";
import { registerPrompts } from "./prompts.js";
import { registerResources } from "./resources.js";
import { errorResult, type McpToolResult } from "./errors.js";

const SERVER_INSTRUCTIONS = `Design Canvas shows every route from the user's running dev server on an infinite canvas (localhost:7420).

TOOLS:
- list_routes — what's on the canvas now. Call BEFORE modifying UI (see existing patterns) and AFTER shipping (confirm routes present).
- add_route / remove_route / update_route — adjust canvas layout (single frame). remove_route hides a frame; it does NOT delete source files. update_route mutates an existing route's path — use after the user has navigated inside a frame and wants to pin the new URL.
- add_frames — atomic batch add of mixed routes/documents/images. PREFER this over multiple add_route/add_document calls when adding 2+ frames at once: one layout pass, no overlaps, one round trip.
- add_section / list_sections / remove_section — wrap a batch of frames in a named labelled group that can be removed as a unit. Use when the grouping is meaningful to the user (a user journey, a comparison set). remove_section deletes the section AND every frame inside it in one call.
- capture_canvas — screenshots for visual verification. Expensive; use after changes, not for browsing.

RESOURCES (read without a tool call via resources/read):
- design-canvas://design-intent.md — the user's design brief, if they've written one in their project root.
- design-canvas://design-system.md — brand / design system notes extracted from the project.
- design-canvas://routes.json — machine-readable current route list (cheaper than list_routes for bulk reads).

PROMPTS (invoke as slash-commands in supporting clients):
- design-canvas:setup — one-shot project bootstrap (detect project type, start dev server, confirm routes).
- design-canvas:verify — capture-and-critique loop against design-intent.md.
- design-canvas:start-design — cold-start composition workflow.

CONVENTIONS:
1. Before generating or modifying UI, call list_routes and read design-intent.md to ground output in existing patterns.
2. After shipping UI changes, capture_canvas and self-critique against design intent.
3. If no dev server is running and UI work is requested, ASK the user for the dev command (npm run dev, pnpm dev, etc.) — never guess.
4. If any tool returns "Design Canvas is not running" or an empty/malformed response, tell the user to open the Design Canvas Mac app. Do not retry silently.`;

// Route by argv: default = stdio server; `install` / `doctor` = CLI subcommands.
const subcommand = process.argv[2];

if (subcommand === "install") {
  const { runInstall } = await import("./install.js");
  const code = await runInstall(process.argv.slice(3));
  process.exit(code);
}

if (subcommand === "doctor") {
  const { runDoctor } = await import("./doctor.js");
  const code = await runDoctor();
  process.exit(code);
}

if (subcommand === "repair") {
  const { runRepair } = await import("./repair.js");
  const code = await runRepair();
  process.exit(code);
}

if (subcommand === "--help" || subcommand === "-h" || subcommand === "help") {
  process.stderr.write(`design-canvas-mcp — MCP server for Design Canvas.\n\n`);
  process.stderr.write(`Usage:\n`);
  process.stderr.write(`  design-canvas-mcp                      Start MCP stdio server (what clients spawn).\n`);
  process.stderr.write(`  design-canvas-mcp install [options]    Write MCP config for Claude Code / Cursor.\n`);
  process.stderr.write(`  design-canvas-mcp doctor               Health check.\n`);
  process.stderr.write(`  design-canvas-mcp repair               Rewrite stale absolute-path entries to npx form.\n\n`);
  process.stderr.write(`Install options:\n`);
  process.stderr.write(`  --scope user|project     Target scope (default: user)\n`);
  process.stderr.write(`  --client claude-code|cursor|all   Target client (default: all)\n`);
  process.stderr.write(`  --force                  Overwrite existing design-canvas entry\n`);
  process.stderr.write(`  --dry-run                Print diff; write nothing\n`);
  process.stderr.write(`  --absolute               Write absolute Node + dist path instead of npx (advanced)\n`);
  process.exit(0);
}

const server = new McpServer(
  { name: "design-canvas", version: "0.6.0" },
  { instructions: SERVER_INSTRUCTIONS },
);

// On the first successful tool call, check if the project's CLAUDE.md mentions
// Design Canvas. If not, append a one-time setup hint to the response.
let hintChecked = false;

async function withSetupHint(result: McpToolResult): Promise<McpToolResult> {
  if (hintChecked || result.isError) return result;
  hintChecked = true; // set synchronously — no race in single-threaded Node
  try {
    const hint = await getSetupHint(server.server);
    if (hint) result.content.push({ type: "text", text: hint });
  } catch { /* never block the tool response */ }
  return result;
}

// Ghost-response safety net — §5.8. Every tool invocation runs through this so
// empty content, thrown errors, and unexpected return shapes all become
// structured errors the agent can surface verbatim. Never a ghost response.
async function safeHandler(
  toolName: string,
  fn: () => Promise<McpToolResult>,
): Promise<McpToolResult> {
  try {
    const result = await fn();
    if (!result || !Array.isArray(result.content) || result.content.length === 0) {
      return errorResult(
        `Internal error in ${toolName}: empty response. Please restart the Design Canvas Mac app and retry. If this persists, file a bug at https://github.com/charlieellington/design-canvas-app/issues`,
      );
    }
    return result;
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    return errorResult(
      `Internal error in ${toolName}: ${msg.slice(0, 400)}. If this persists, make sure the Design Canvas Mac app is running and restart your agent.`,
    );
  }
}

// Register all 4 tools using the non-deprecated registerTool API

server.registerTool("list_routes", {
  description: toolDefinitions.list_routes.description,
  inputSchema: toolDefinitions.list_routes.inputSchema,
}, async () => {
  return safeHandler("list_routes", async () => withSetupHint(await handleListRoutes()));
});

server.registerTool("add_route", {
  description: toolDefinitions.add_route.description,
  inputSchema: toolDefinitions.add_route.inputSchema,
}, async (args) => {
  return safeHandler("add_route", async () => withSetupHint(await handleAddRoute(args)));
});

server.registerTool("remove_route", {
  description: toolDefinitions.remove_route.description,
  inputSchema: toolDefinitions.remove_route.inputSchema,
}, async (args) => {
  return safeHandler("remove_route", async () => withSetupHint(await handleRemoveRoute(args)));
});

server.registerTool("update_route", {
  description: toolDefinitions.update_route.description,
  inputSchema: toolDefinitions.update_route.inputSchema,
}, async (args) => {
  return safeHandler("update_route", async () => withSetupHint(await handleUpdateRoute(args)));
});

server.registerTool("capture_canvas", {
  description: toolDefinitions.capture_canvas.description,
  inputSchema: toolDefinitions.capture_canvas.inputSchema,
}, async (args) => {
  return safeHandler("capture_canvas", async () => withSetupHint(await handleCaptureCanvas(args)));
});

server.registerTool("list_servers", {
  description: toolDefinitions.list_servers.description,
  inputSchema: toolDefinitions.list_servers.inputSchema,
}, async () => {
  return safeHandler("list_servers", async () => withSetupHint(await handleListServers()));
});

// Markdown documents

server.registerTool("list_documents", {
  description: toolDefinitions.list_documents.description,
  inputSchema: toolDefinitions.list_documents.inputSchema,
}, async () => {
  return safeHandler("list_documents", async () => withSetupHint(await handleListDocuments()));
});

server.registerTool("add_document", {
  description: toolDefinitions.add_document.description,
  inputSchema: toolDefinitions.add_document.inputSchema,
}, async (args) => {
  return safeHandler("add_document", async () => withSetupHint(await handleAddDocument(args)));
});

server.registerTool("remove_document", {
  description: toolDefinitions.remove_document.description,
  inputSchema: toolDefinitions.remove_document.inputSchema,
}, async (args) => {
  return safeHandler("remove_document", async () => withSetupHint(await handleRemoveDocument(args)));
});

// Images

server.registerTool("list_images", {
  description: toolDefinitions.list_images.description,
  inputSchema: toolDefinitions.list_images.inputSchema,
}, async () => {
  return safeHandler("list_images", async () => withSetupHint(await handleListImages()));
});

server.registerTool("add_image", {
  description: toolDefinitions.add_image.description,
  inputSchema: toolDefinitions.add_image.inputSchema,
}, async (args) => {
  return safeHandler("add_image", async () => withSetupHint(await handleAddImage(args)));
});

server.registerTool("remove_image", {
  description: toolDefinitions.remove_image.description,
  inputSchema: toolDefinitions.remove_image.inputSchema,
}, async (args) => {
  return safeHandler("remove_image", async () => withSetupHint(await handleRemoveImage(args)));
});

// Batch add — mixed frames in one atomic call

server.registerTool("add_frames", {
  description: toolDefinitions.add_frames.description,
  inputSchema: toolDefinitions.add_frames.inputSchema,
}, async (args) => {
  return safeHandler("add_frames", async () => withSetupHint(await handleAddFrames(args as any)));
});

// Sections — named groups of frames, removable as a unit

server.registerTool("list_sections", {
  description: toolDefinitions.list_sections.description,
  inputSchema: toolDefinitions.list_sections.inputSchema,
}, async () => {
  return safeHandler("list_sections", async () => withSetupHint(await handleListSections()));
});

server.registerTool("add_section", {
  description: toolDefinitions.add_section.description,
  inputSchema: toolDefinitions.add_section.inputSchema,
}, async (args) => {
  return safeHandler("add_section", async () => withSetupHint(await handleAddSection(args as any)));
});

server.registerTool("remove_section", {
  description: toolDefinitions.remove_section.description,
  inputSchema: toolDefinitions.remove_section.inputSchema,
}, async (args) => {
  return safeHandler("remove_section", async () => withSetupHint(await handleRemoveSection(args)));
});

// Register MCP prompts and resources (§5.2, §5.3)
registerPrompts(server);
registerResources(server);

// Connect via stdio
const transport = new StdioServerTransport();
await server.connect(transport);

console.error("[design-canvas-mcp] Server started");
