// 4 MCP tool definitions wrapping the Design Canvas HTTP API.
// Each handler catches all errors and returns structured isError responses — never throws.

import { z } from "zod";
import { readFile, stat } from "node:fs/promises";
import sharp from "sharp";
import * as api from "./api-client.js";
import { errorResult, textResult, mapFetchError, type McpToolResult } from "./errors.js";

// ---------------------------------------------------------------------------
// Tool definitions (schemas + descriptions)
// ---------------------------------------------------------------------------

export const toolDefinitions = {
  list_routes: {
    description: `List all routes currently displayed on the Design Canvas. Returns each route's ID, path, viewport dimensions (width × height), and canvas position.

USAGE: Call this before removing routes (you need the route ID for precise removal) or before adding routes (to avoid duplicates). Route IDs are stable — use them to reference specific frames.

NOTE: This tool lists routes from the Design Canvas app specifically — not routes from the user's codebase or file system.`,
    inputSchema: z.object({}),
  },

  add_route: {
    description: `Add a web page route to the Design Canvas. The route is loaded from the connected dev server and displayed as a live frame on the infinite canvas. Returns the route ID for future reference.

CONSTRAINTS:
- Path must start with '/' (e.g., '/dashboard', '/settings', '/blog/[slug]')
- Do not pass full URLs — the dev server base URL is configured in the app
- Use standard responsive widths: 1280 desktop (default), 768 tablet, 375 mobile
- Position (x, y) is auto-calculated if omitted — frames stack horizontally

MULTI-SERVER (C0+): when a canvas has more than one dev server plugged in, omitting both 'port' and 'serverId' returns a server_required error listing the available servers. Pass 'port' (preferred, ergonomic) or 'serverId' (precise, from list_servers / list_routes) to disambiguate. Single-server canvases work without either field.

RESPONSIVE COMPARISON: To compare layouts at different viewports, add the same path multiple times with different widths. Example: add '/dashboard' at width 1280, then add '/dashboard' again at width 375.

BULK LOADING WARNING: If adding 8 or more routes at once, explicitly tell the user that loading many routes may take a while before proceeding. Each route spawns a live WebView — bulk-loading is slow and resource-intensive. PREFER add_frames for batches — it lays out the whole group in one collision-free pass instead of 22 independent placements.`,
    inputSchema: z.object({
      path: z.string().describe("The route path, e.g. '/' or '/dashboard'. Must start with '/'."),
      width: z.number().optional().describe("Viewport width in pixels. Use 1280 for desktop (default), 768 for tablet, 375 for mobile."),
      height: z.number().optional().describe("Viewport height in pixels. Default: 800."),
      x: z.number().optional().describe("X position on canvas. Auto-positioned next to existing frames if omitted."),
      y: z.number().optional().describe("Y position on canvas. Auto-positioned if omitted."),
      port: z.number().optional().describe("Which dev-server port the route attaches to. Required only when the canvas has more than one server bound. Use list_servers to discover."),
      serverId: z.string().optional().describe("Stable server-binding id from list_servers / list_routes. Alternative to 'port' for precision when port might churn."),
      placement: z.enum(["right-of-last", "new-row"]).optional().describe("Layout hint when x/y are omitted. 'right-of-last' (default) stacks next to the last route, falling back to a new row if it would collide. 'new-row' always drops to a fresh row below every existing frame — use when starting a new logical group."),
    }),
  },

  list_servers: {
    description: `List dev-server bindings on the active Design Canvas. Each binding records a port + project that the canvas is plugged into. Use this before add_route on a canvas with multiple servers to pick the right target.

Returns each server's serverId, port, projectName, projectDir, status (connected/stale/offline), origin URL, and whether it's the canvas's primary server.`,
    inputSchema: z.object({}),
  },

  remove_route: {
    description: `Remove a route frame from the Design Canvas.

CONSTRAINTS:
- Prefer removal by ID (from list_routes or add_route response) — unambiguous
- Removal by path is supported but removes only the first match — risky when duplicate paths exist (e.g., same route at desktop + mobile widths)
- If you need to remove a specific viewport size, call list_routes first to find the exact route ID`,
    inputSchema: z.object({
      id: z.string().optional().describe("Route ID from list_routes or add_route. Preferred — unambiguous."),
      path: z.string().optional().describe("Route path to remove. Removes first match only. Use id for precision."),
    }),
  },

  update_route: {
    description: `Update an existing route's path. Use this to "pin" a navigated URL — when the user has clicked links inside a frame and arrived at a path they want as the new canonical route. Replaces the route's path; viewport size and canvas position are preserved. The frame reloads at the new path.

CONSTRAINTS:
- newPath must start with '/' (e.g., '/dashboard/orders')
- id must come from list_routes — paths can be ambiguous when duplicated at multiple viewports
- This mutates the saved canvas state and persists across app restarts. There is no undo at the MCP layer; use list_routes before/after to confirm.`,
    inputSchema: z.object({
      id: z.string().describe("Route ID from list_routes. Required — paths may not be unique."),
      newPath: z.string().describe("New route path, e.g. '/dashboard'. Must start with '/'."),
    }),
  },

  capture_canvas: {
    description: `Capture fresh screenshots of routes on the Design Canvas. Triggers a new render (not cached), waits for pages to fully load, and returns screenshots as images. Screenshots use WebKit rendering — use for quick layout verification, not pixel-perfect cross-browser QA.

USAGE: Use after making code changes to visually verify how routes look. This is an expensive operation (several seconds) — do not call speculatively.

CONSTRAINTS:
- Returns 3 images by default. Pass limit for more, or ids for specific routes.
- If the canvas has many routes, pass specific route IDs to capture only what changed — this saves context space and is significantly faster
- Route IDs are returned by list_routes and add_route
- For precise cross-browser verification, use Playwright instead
- NOTE: capture_canvas only covers routes. Document (markdown/HTML) and image frames are not captured — their content is static/interactive and does not need periodic re-capture.`,
    inputSchema: z.object({
      ids: z.array(z.string()).optional().describe("Route IDs to capture. If omitted, captures all routes."),
      limit: z.number().optional().describe("Maximum number of screenshot images to return. Default: 3."),
    }),
  },

  list_documents: {
    description: `List all document frames (markdown or HTML) currently displayed on the Design Canvas. Returns each document's ID, kind ("markdown" or "html"), absolute file path, dimensions, position, and optional display name.

USAGE: Call before remove_document to get the id, or before add_document to avoid adding the same doc twice.`,
    inputSchema: z.object({}),
  },

  add_document: {
    description: `Add a markdown or HTML document to the Design Canvas as a dark-themed "knowledge card" frame. Use for plans (\`plan.html\`), living design systems (\`design-system.html\`), throwaway micro-UIs for editing specs, or markdown PRDs and design references. Displayed alongside live route frames so the spec lives in the same visual context as the product itself.

CONSTRAINTS:
- filePath must be absolute (e.g., '/Users/you/project/docs/plan.html' or '.../spec.md')
- Supported extensions: .md, .markdown, .html, .htm. Markdown is rendered via marked.js; HTML loads as-is.
- File must exist and be readable
- Position (x, y) is auto-calculated if omitted (placed to the right of the last document, falling back to a new row if that would collide with existing content)
- Default dimensions: 700 × 800 (narrower than a route frame, optimised for reading)`,
    inputSchema: z.object({
      filePath: z.string().describe("Absolute path to a .md, .markdown, .html, or .htm file."),
      width: z.number().optional().describe("Frame width in pixels. Default: 700."),
      height: z.number().optional().describe("Frame height in pixels. Default: 800."),
      x: z.number().optional().describe("X position on canvas. Auto-positioned if omitted."),
      y: z.number().optional().describe("Y position on canvas. Auto-positioned if omitted."),
      placement: z.enum(["right-of-last", "new-row"]).optional().describe("Layout hint when x/y are omitted. 'right-of-last' (default) stacks next to the last document. 'new-row' drops to a fresh row below all existing frames."),
    }),
  },

  remove_document: {
    description: `Remove a document frame (markdown or HTML) from the Design Canvas by ID. Get the id from list_documents or the response of add_document.`,
    inputSchema: z.object({
      id: z.string().describe("Document ID from list_documents or add_document response."),
    }),
  },

  list_images: {
    description: `List all image frames currently displayed on the Design Canvas. Returns each image's ID, absolute file path, dimensions, position, and optional display name.`,
    inputSchema: z.object({}),
  },

  add_image: {
    description: `Add an image (PNG, JPG, JPEG, GIF, SVG, HEIC) to the Design Canvas as a dark-themed reference frame. Use for moodboards, reference screenshots of other apps, design inspiration, or any visual context that should sit alongside the live routes.

CONSTRAINTS:
- filePath must be absolute
- File must exist and be readable
- Supported formats: PNG, JPG, JPEG, GIF, SVG, HEIC. SVG requires macOS 14+.
- Position (x, y) is auto-calculated if omitted
- Default dimensions: 600 × 400`,
    inputSchema: z.object({
      filePath: z.string().describe("Absolute path to the image file."),
      width: z.number().optional().describe("Frame width in pixels. Default: 600."),
      height: z.number().optional().describe("Frame height in pixels. Default: 400."),
      x: z.number().optional(),
      y: z.number().optional(),
      placement: z.enum(["right-of-last", "new-row"]).optional().describe("Layout hint when x/y are omitted. 'right-of-last' (default) or 'new-row' to drop to a fresh row below all existing frames."),
    }),
  },

  remove_image: {
    description: `Remove an image frame from the Design Canvas by ID. Get the id from list_images or the response of add_image.`,
    inputSchema: z.object({
      id: z.string().describe("Image ID from list_images or add_image response."),
    }),
  },

  list_sections: {
    description: `List all sections currently on the Design Canvas. A section is a named, labelled rectangle that groups a set of frames together — added via add_section, removed as a unit via remove_section.

Returns each section's ID, title, position, dimensions, and the IDs of the routes/documents/images it contains.`,
    inputSchema: z.object({}),
  },

  add_section: {
    description: `Wrap a batch of frames in a labelled rectangular section. Sections are the right tool when adding 2+ frames that conceptually belong together (a user journey, a feature surface, a comparison set). The section is drawn behind its frames as a soft border + title bar, and removing the section removes every frame inside it in one call.

USE THIS over add_frames when:
- You want a visual label on the group ("Rewards V1 journey", "Settings flow", "Mobile vs desktop")
- You want one-call cleanup (remove_section deletes the section AND every frame inside it)
- The grouping is meaningful to the user, not just a temporary batch

ITEM TYPES (same as add_frames):
- route: { type: "route", path: "/...", width?, height?, port?, serverId? }
- document: { type: "document", filePath: "/absolute/path.md or .html", width?, height? }
- image: { type: "image", filePath: "/absolute/path.png", width?, height? }

LAYOUT:
- "row" (default): items left-to-right inside the section
- "pairs-rows": even items on top row, odd items directly below — perfect for interleaved [route, doc, route, doc, ...] input

POSITIONING: The section auto-places below all existing canvas content with a generous gap. Pass x/y to pin a specific location.`,
    inputSchema: z.object({
      title: z.string().describe("Label shown above the section, e.g. 'Rewards V1 journey'"),
      items: z.array(
        z.discriminatedUnion("type", [
          z.object({
            type: z.literal("route"),
            path: z.string(),
            width: z.number().optional(),
            height: z.number().optional(),
            port: z.number().optional(),
            serverId: z.string().optional(),
          }),
          z.object({
            type: z.literal("document"),
            filePath: z.string(),
            width: z.number().optional(),
            height: z.number().optional(),
          }),
          z.object({
            type: z.literal("image"),
            filePath: z.string(),
            width: z.number().optional(),
            height: z.number().optional(),
          }),
        ])
      ).min(1).describe("Frames to add inside the section. At least one item required."),
      layout: z.enum(["row", "pairs-rows"]).optional().describe("How to arrange items inside the section. Default 'row'."),
      x: z.number().optional().describe("Pin the section's top-left x. Auto-positioned below existing content if omitted."),
      y: z.number().optional().describe("Pin the section's top-left y. Auto-positioned below existing content if omitted."),
    }),
  },

  remove_section: {
    description: `Remove a section AND every frame it contains in a single call. Use the section ID from list_sections or the response of add_section. Frames' screenshots are cleaned up via the normal remove_route path.`,
    inputSchema: z.object({
      id: z.string().describe("Section ID from list_sections or add_section response."),
    }),
  },

  add_frames: {
    description: `Add a batch of frames (routes, documents, and/or images) to the Design Canvas in a single atomic call. The whole batch is laid out as one unit with a single collision-free placement decision — this is the right tool for adding more than 2 frames at once.

WHY USE THIS over individual add_route/add_document/add_image calls:
- One layout decision for the entire batch — items can't overlap each other or existing content
- One round trip instead of N — adding 22 frames is 1 call, not 22
- Atomic: if any item fails validation (bad path, missing file), nothing is added
- One recovery call: pair with add_section if you want to remove the whole group later in one shot

ITEM TYPES (discriminated by 'type'):
- route: { type: "route", path: "/...", width?, height?, port?, serverId? }
- document: { type: "document", filePath: "/absolute/path.md or .html", width?, height? }
- image: { type: "image", filePath: "/absolute/path.png", width?, height? }

LAYOUT:
- "row" (default): items left-to-right in a single row
- "pairs-rows": even-indexed items on the top row, odd-indexed items directly below — pass [route1, doc1, route2, doc2, ...] to get a clean route-on-top, doc-underneath grid

PLACEMENT:
- Default behaviour drops the batch into a fresh row below all existing content (always safe)
- Pass placement: "right-of-last" only if you want the batch to continue an existing row

BULK LOADING WARNING: 8+ routes spawns 8+ live WebViews. Tell the user the canvas may take a moment to settle.`,
    inputSchema: z.object({
      items: z.array(
        z.discriminatedUnion("type", [
          z.object({
            type: z.literal("route"),
            path: z.string().describe("Route path starting with '/'"),
            width: z.number().optional(),
            height: z.number().optional(),
            port: z.number().optional().describe("Dev-server port (required on multi-server canvases)"),
            serverId: z.string().optional().describe("Stable server binding id (alternative to port)"),
          }),
          z.object({
            type: z.literal("document"),
            filePath: z.string().describe("Absolute path to a .md, .markdown, .html, or .htm file"),
            width: z.number().optional(),
            height: z.number().optional(),
          }),
          z.object({
            type: z.literal("image"),
            filePath: z.string().describe("Absolute path to an image file"),
            width: z.number().optional(),
            height: z.number().optional(),
          }),
        ])
      ).min(1).describe("Mixed list of frames to add. At least one item required."),
      layout: z.enum(["row", "pairs-rows"]).optional().describe("How to arrange items. Default 'row'."),
      placement: z.enum(["right-of-last", "new-row"]).optional().describe("Where to anchor the batch. Default 'new-row' (safe — drops below all existing content)."),
    }),
  },
} as const;

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

const MAX_IMAGE_WIDTH = 1200;
const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB
const DEFAULT_LIMIT = 3;

export async function handleListRoutes(): Promise<McpToolResult> {
  try {
    const routes = await api.listRoutes();
    if (routes.length === 0) {
      return textResult("No routes on the canvas. Use add_route to add some.");
    }
    const lines = routes.map((r) => {
      const tag = r.status === "removed" ? " [REMOVED]" : "";
      return `  [${r.id}] ${r.path}${tag} — ${r.width}×${r.height} at (${Math.round(r.x)}, ${Math.round(r.y)})`;
    });
    return textResult(`${routes.length} routes on canvas:\n${lines.join("\n")}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleAddRoute(params: {
  path: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  port?: number;
  serverId?: string;
  placement?: api.Placement;
}): Promise<McpToolResult> {
  try {
    const result = await api.addRoute(params);
    // 409 path: the canvas has multiple servers and the caller didn't disambiguate.
    if ("error" in result) {
      const lines = result.availableServers.map((s) => {
        const tail = s.projectDir ? ` (${s.projectDir})` : "";
        const portHint = typeof s.port === "number" ? `:${s.port}` : "?";
        return `  • serverId=${s.serverId} port=${portHint} project=${s.projectName}${tail}`;
      });
      return errorResult(
        `Canvas has multiple servers — pass 'port' or 'serverId' to disambiguate.\nAvailable servers:\n${lines.join("\n")}`
      );
    }
    const w = params.width ?? 1280;
    const h = params.height ?? 800;
    const targetNote = params.port ? ` on :${params.port}` : params.serverId ? ` on server ${params.serverId.slice(0, 8)}` : "";
    return textResult(`Added ${params.path} (${w}×${h})${targetNote}. Route ID: ${result.id}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleListServers(): Promise<McpToolResult> {
  try {
    const servers = await api.listServers();
    if (servers.length === 0) {
      return textResult("No dev servers plugged into the canvas. Connect one via the pill in the app.");
    }
    const lines = servers.map((s) => {
      const tail = s.projectDir ? ` (${s.projectDir})` : "";
      const portStr = typeof s.port === "number" ? `:${s.port}` : "—";
      const primary = s.isPrimary ? " [primary]" : "";
      return `  • [${s.serverId}] ${portStr} · ${s.projectName} · ${s.status}${primary}${tail}`;
    });
    return textResult(`${servers.length} server${servers.length !== 1 ? "s" : ""} on canvas:\n${lines.join("\n")}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleRemoveRoute(params: {
  id?: string;
  path?: string;
}): Promise<McpToolResult> {
  if (!params.id && !params.path) {
    return errorResult("Must provide either 'id' or 'path' to remove a route.");
  }
  try {
    await api.removeRoute(params);
    const target = params.id ? `route ${params.id.slice(0, 8)}` : params.path;
    return textResult(`Removed ${target} from the canvas.`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleUpdateRoute(params: {
  id: string;
  newPath: string;
}): Promise<McpToolResult> {
  if (!params.id) {
    return errorResult("Must provide 'id' to update a route. Get it from list_routes.");
  }
  if (!params.newPath || !params.newPath.startsWith("/")) {
    return errorResult("newPath must start with '/' (e.g. '/dashboard').");
  }
  try {
    await api.updateRoute(params);
    return textResult(`Updated route ${params.id.slice(0, 8)} → ${params.newPath}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleCaptureCanvas(params: {
  ids?: string[];
  limit?: number;
}): Promise<McpToolResult> {
  try {
    const result = await api.captureCanvas(params.ids);
    const screenshots = result.screenshots;
    // PR 2: when the server hits its 180s budget it returns 504 with whatever finished
    // plus an `error` field. We render the partial images so the agent isn't empty-handed.
    const isPartial = typeof result.error === "string";

    if (screenshots.length === 0 && !isPartial) {
      return textResult("No screenshots captured. The canvas may be empty or the requested routes were not found.");
    }

    const limit = params.limit ?? DEFAULT_LIMIT;
    const total = screenshots.length;
    const toReturn = screenshots.slice(0, limit);
    const content: McpToolResult["content"] = [];

    if (isPartial) {
      const captured = result.captured ?? total;
      const totalRoutes = result.total ?? total;
      const unsettled = result.unsettled ?? [];
      const head = unsettled.slice(0, 3).join(", ");
      const more = unsettled.length > 3 ? ", …" : "";
      content.push({
        type: "text",
        text: `⚠ Capture timed out (Design Canvas 180s budget). ${captured}/${totalRoutes} routes captured; ${unsettled.length} did not finish loading${unsettled.length > 0 ? `: ${head}${more}` : ""}. Try a smaller subset via \`ids\`, or check that those routes don't require auth.`,
      });
    }

    // Text summary with WebKit rendering note
    const summaryParts = [`Captured ${total} route${total !== 1 ? "s" : ""}`];
    if (total > limit) {
      summaryParts.push(`showing ${limit} of ${total}`);
    }
    summaryParts.push("(WebKit rendering — use for layout verification, not pixel-perfect browser QA):");
    content.push({ type: "text", text: summaryParts.join(", ") });

    // Read and encode each screenshot
    for (const screenshot of toReturn) {
      try {
        const fileStat = await stat(screenshot.filePath).catch(() => null);
        if (!fileStat) {
          content.push({ type: "text", text: `  ⚠ ${screenshot.path}: screenshot file not found` });
          continue;
        }
        if (fileStat.size > MAX_FILE_SIZE) {
          content.push({ type: "text", text: `  ⚠ ${screenshot.path}: screenshot too large (${Math.round(fileStat.size / 1024 / 1024)}MB), skipped` });
          continue;
        }
        if (!screenshot.filePath.endsWith(".jpg") && !screenshot.filePath.endsWith(".jpeg")) {
          content.push({ type: "text", text: `  ⚠ ${screenshot.path}: unexpected file format, skipped` });
          continue;
        }

        // Read and resize to max width for context window efficiency
        const buffer = await readFile(screenshot.filePath);
        const resized = await sharp(buffer)
          .resize({ width: MAX_IMAGE_WIDTH, withoutEnlargement: true })
          .jpeg({ quality: 80 })
          .toBuffer();

        content.push({
          type: "image",
          data: resized.toString("base64"),
          mimeType: "image/jpeg",
        });
        content.push({ type: "text", text: `  ${screenshot.path}` });
      } catch {
        content.push({ type: "text", text: `  ⚠ ${screenshot.path}: failed to read screenshot` });
      }
    }

    if (total > limit) {
      content.push({
        type: "text",
        text: `\nShowing ${limit} of ${total} captured routes. Increase limit or pass specific ids to see more.`,
      });
    }

    return isPartial ? { content, isError: true } : { content };
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

// ---------------------------------------------------------------------------
// Document (markdown / HTML) handlers
// ---------------------------------------------------------------------------

export async function handleListDocuments(): Promise<McpToolResult> {
  try {
    const docs = await api.listDocuments();
    if (docs.length === 0) {
      return textResult("No documents on the canvas. Use add_document to add a .md or .html file.");
    }
    const lines = docs.map((d) => {
      const name = d.displayName ?? d.filePath.split("/").pop() ?? d.filePath;
      return `  [${d.id}] ${d.kind} ${name} — ${d.width}×${d.height} at (${Math.round(d.x)}, ${Math.round(d.y)})`;
    });
    return textResult(`${docs.length} document${docs.length !== 1 ? "s" : ""} on canvas:\n${lines.join("\n")}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleAddDocument(params: {
  filePath: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  placement?: api.Placement;
}): Promise<McpToolResult> {
  try {
    const result = await api.addDocument(params);
    return textResult(`Added ${params.filePath} to canvas. Document ID: ${result.id}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleRemoveDocument(params: { id: string }): Promise<McpToolResult> {
  if (!params.id) {
    return errorResult("Must provide 'id' to remove a document.");
  }
  try {
    await api.removeDocument(params);
    return textResult(`Removed document ${params.id.slice(0, 8)} from the canvas.`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

// ---------------------------------------------------------------------------
// Image handlers
// ---------------------------------------------------------------------------

export async function handleListImages(): Promise<McpToolResult> {
  try {
    const imgs = await api.listImages();
    if (imgs.length === 0) {
      return textResult("No images on the canvas. Use add_image to add one.");
    }
    const lines = imgs.map((i) => {
      const name = i.displayName ?? i.filePath.split("/").pop() ?? i.filePath;
      return `  [${i.id}] ${name} — ${i.width}×${i.height} at (${Math.round(i.x)}, ${Math.round(i.y)})`;
    });
    return textResult(`${imgs.length} image${imgs.length !== 1 ? "s" : ""} on canvas:\n${lines.join("\n")}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleAddImage(params: {
  filePath: string;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  placement?: api.Placement;
}): Promise<McpToolResult> {
  try {
    const result = await api.addImage(params);
    return textResult(`Added ${params.filePath} to canvas. Image ID: ${result.id}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleRemoveImage(params: { id: string }): Promise<McpToolResult> {
  if (!params.id) {
    return errorResult("Must provide 'id' to remove an image.");
  }
  try {
    await api.removeImage(params);
    return textResult(`Removed image ${params.id.slice(0, 8)} from the canvas.`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

// ---------------------------------------------------------------------------
// Batch handler
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Section handlers
// ---------------------------------------------------------------------------

export async function handleListSections(): Promise<McpToolResult> {
  try {
    const sections = await api.listSections();
    if (sections.length === 0) {
      return textResult("No sections on the canvas. Use add_section to group frames together.");
    }
    const lines = sections.map((s) => {
      const counts = `${s.routeIds.length}r/${s.documentIds.length}d/${s.imageIds.length}i`;
      return `  [${s.id}] "${s.title}" — ${counts} at (${Math.round(s.x)}, ${Math.round(s.y)}), ${Math.round(s.width)}×${Math.round(s.height)}`;
    });
    return textResult(`${sections.length} section${sections.length === 1 ? "" : "s"} on canvas:\n${lines.join("\n")}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleAddSection(params: {
  title: string;
  items: api.BatchItem[];
  layout?: api.BatchLayout;
  x?: number;
  y?: number;
}): Promise<McpToolResult> {
  try {
    const result = await api.addSection(params);
    if ("error" in result) {
      const lines = result.availableServers.map((s) => {
        const tail = s.projectDir ? ` (${s.projectDir})` : "";
        const portHint = typeof s.port === "number" ? `:${s.port}` : "?";
        return `  • serverId=${s.serverId} port=${portHint} project=${s.projectName}${tail}`;
      });
      return errorResult(
        `Section contains a route on an ambiguous server — pass 'port' or 'serverId' on that item.\nAvailable servers:\n${lines.join("\n")}`
      );
    }
    const lines = result.added.map((f) => {
      const label = f.path ?? f.filePath ?? "(unknown)";
      return `  [${f.id}] ${f.type} ${label}`;
    });
    return textResult(`Added section "${params.title}" with ${result.added.length} frame${result.added.length === 1 ? "" : "s"}.\nSection ID: ${result.sectionId}\nContents:\n${lines.join("\n")}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleRemoveSection(params: { id: string }): Promise<McpToolResult> {
  if (!params.id) {
    return errorResult("Must provide 'id' to remove a section.");
  }
  try {
    await api.removeSection(params);
    return textResult(`Removed section ${params.id.slice(0, 8)} (and every frame it contained) from the canvas.`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

export async function handleAddFrames(params: {
  items: api.BatchItem[];
  layout?: api.BatchLayout;
  placement?: api.Placement;
}): Promise<McpToolResult> {
  try {
    const result = await api.addFrames(params);
    if ("error" in result) {
      const lines = result.availableServers.map((s) => {
        const tail = s.projectDir ? ` (${s.projectDir})` : "";
        const portHint = typeof s.port === "number" ? `:${s.port}` : "?";
        return `  • serverId=${s.serverId} port=${portHint} project=${s.projectName}${tail}`;
      });
      return errorResult(
        `Batch contains a route on an ambiguous server — pass 'port' or 'serverId' on that item.\nAvailable servers:\n${lines.join("\n")}`
      );
    }
    const lines = result.added.map((f) => {
      const label = f.path ?? f.filePath ?? "(unknown)";
      return `  [${f.id}] ${f.type} ${label} at (${Math.round(f.x)}, ${Math.round(f.y)}) — ${Math.round(f.width)}×${Math.round(f.height)}`;
    });
    return textResult(`Added ${result.added.length} frame${result.added.length === 1 ? "" : "s"} in one batch:\n${lines.join("\n")}`);
  } catch (error) {
    if (hasMcpResult(error)) return error.mcpResult;
    return mapFetchError(error);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function hasMcpResult(error: unknown): error is { mcpResult: McpToolResult } {
  return (
    typeof error === "object" &&
    error !== null &&
    "mcpResult" in error &&
    typeof (error as { mcpResult: unknown }).mcpResult === "object"
  );
}
