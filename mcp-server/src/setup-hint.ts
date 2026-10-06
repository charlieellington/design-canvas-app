// One-time CLAUDE.md / .cursorrules detection. On the first successful tool call,
// checks if the project already mentions Design Canvas MCP. If not, returns a hint
// the agent can relay to the user. Never throws — returns null on any failure.

import { access, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Server } from "@modelcontextprotocol/sdk/server/index.js";

const MARKER = "Design Canvas MCP";

const CONFIG_FILES = ["CLAUDE.md", ".cursorrules"] as const;

const SNIPPET = `## Design Canvas MCP — Use It

This project uses an MCP server that controls the Design Canvas Mac app. You have 4 tools available: \`list_routes\`, \`add_route\`, \`remove_route\`, \`capture_canvas\`.

**You MUST use these tools instead of manual workarounds:**
- To see what's on the canvas → \`list_routes\` (not curl or browser)
- To add/remove routes from the canvas → \`add_route\` / \`remove_route\` (NEVER delete source files to remove a canvas frame)
- To verify visual changes → \`capture_canvas\` (not Playwright unless cross-browser QA is needed)
- To reorganise the canvas layout → \`list_routes\` → \`remove_route\` unwanted → \`add_route\` with positions

The MCP controls what's DISPLAYED, not what EXISTS in the codebase. It's like Figma frames — adding/removing a frame doesn't create/delete the underlying design.`;

const HINT_APPEND = `\n---\nTIP: Your project has a CLAUDE.md but it doesn't mention Design Canvas.\nTo ensure AI agents reliably use these canvas tools, add this section to your CLAUDE.md:\n\n${SNIPPET}\n---`;

const HINT_CREATE = `\nTIP: Add a CLAUDE.md file to your project root with a "Design Canvas MCP" section to ensure AI agents reliably use these canvas tools. See https://github.com/charlieellington/design-canvas-app/blob/main/docs/MCP.md for the recommended snippet.`;

/** Resolve root directories from the MCP client, with a timeout. */
async function getRootPaths(server: Server): Promise<string[]> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 3_000);
  try {
    const { roots } = await server.listRoots();
    return roots
      .map((r) => {
        try { return fileURLToPath(r.uri); } catch { return null; }
      })
      .filter((p): p is string => p !== null);
  } catch {
    return [];
  } finally {
    clearTimeout(timer);
  }
}

/** Check if a file exists and optionally read its contents. */
async function readIfExists(path: string): Promise<string | null> {
  try {
    await access(path);
    return await readFile(path, "utf-8");
  } catch {
    return null;
  }
}

/**
 * Returns a setup hint string if the project's config files don't mention
 * Design Canvas MCP, or null if already configured (or detection fails).
 */
export async function getSetupHint(server: Server): Promise<string | null> {
  try {
    const roots = await getRootPaths(server);
    if (roots.length === 0) return null;

    let foundAnyConfig = false;

    for (const root of roots) {
      for (const file of CONFIG_FILES) {
        const content = await readIfExists(join(root, file));
        if (content === null) continue;
        foundAnyConfig = true;
        if (content.includes(MARKER)) return null; // already configured
      }
    }

    return foundAnyConfig ? HINT_APPEND : HINT_CREATE;
  } catch {
    return null;
  }
}
