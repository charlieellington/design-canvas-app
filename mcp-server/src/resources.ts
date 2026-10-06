// MCP Resources — §5.3 of documentation/mcp-onboarding-update.md.
// Three v1 resources the agent can read without a tool call.
// Security: every file-system read refuses symlinks (lstat check) and resolves
// only under the MCP client's declared roots — no directory traversal.

import { lstat, readFile, access } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Server } from "@modelcontextprotocol/sdk/server/index.js";
import * as api from "./api-client.js";

const INTENT_CANDIDATES = ["design-intent.md", ".design-intent.md"] as const;
const SYSTEM_CANDIDATES = ["design-system.md", "docs/design-system.md"] as const;

const INTENT_NOT_FOUND = `# No design-intent.md found

Create a file called \`design-intent.md\` at your project root describing your design intent. Suggested sections:

- **Brand** — voice, personality, mood
- **References** — URLs or paths to visuals you want to match
- **Vibe** — one sentence
- **Typography** — families, scale, weights
- **Colour** — palette, usage rules
- **Spacing** — scale, rhythm`;

const SYSTEM_NOT_FOUND = `# No design-system.md found

Create \`design-system.md\` at your project root (or \`docs/design-system.md\`) summarising your brand / design system. Keep it short — the agent uses this to ground output in your existing patterns.`;

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

async function readIfSafe(path: string): Promise<string | null> {
  try {
    // Symlink refusal — never follow; arbitrary-file-read defence.
    const stats = await lstat(path);
    if (stats.isSymbolicLink()) return null;
    if (!stats.isFile()) return null;
    await access(path);
    return await readFile(path, "utf-8");
  } catch {
    return null;
  }
}

async function findFirst(roots: string[], candidates: readonly string[]): Promise<string | null> {
  for (const root of roots) {
    for (const candidate of candidates) {
      const content = await readIfSafe(join(root, candidate));
      if (content !== null) return content;
    }
  }
  return null;
}

export function registerResources(server: McpServer): void {
  const underlying = server.server;

  // design-canvas://design-intent.md
  server.registerResource(
    "design-intent",
    "design-canvas://design-intent.md",
    {
      title: "Design intent",
      description: "The user's design brief / intent file for this project. Falls back to a template when missing.",
      mimeType: "text/markdown",
    },
    async (uri) => {
      const roots = await getRootPaths(underlying);
      const content = await findFirst(roots, INTENT_CANDIDATES);
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: "text/markdown",
            text: content ?? INTENT_NOT_FOUND,
          },
        ],
      };
    },
  );

  // design-canvas://design-system.md
  server.registerResource(
    "design-system",
    "design-canvas://design-system.md",
    {
      title: "Design system",
      description: "Brand / design-system notes extracted from the project. Falls back to a template when missing.",
      mimeType: "text/markdown",
    },
    async (uri) => {
      const roots = await getRootPaths(underlying);
      const content = await findFirst(roots, SYSTEM_CANDIDATES);
      return {
        contents: [
          {
            uri: uri.href,
            mimeType: "text/markdown",
            text: content ?? SYSTEM_NOT_FOUND,
          },
        ],
      };
    },
  );

  // design-canvas://routes.json
  server.registerResource(
    "routes",
    "design-canvas://routes.json",
    {
      title: "Current canvas routes",
      description: "Machine-readable list of routes currently displayed on the Design Canvas.",
      mimeType: "application/json",
    },
    async (uri) => {
      try {
        const routes = await api.listRoutes();
        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "application/json",
              text: JSON.stringify(routes, null, 2),
            },
          ],
        };
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "application/json",
              text: JSON.stringify({
                error: "Could not read routes from Design Canvas.",
                reason: msg,
                hint: "Is the Design Canvas Mac app running?",
              }, null, 2),
            },
          ],
        };
      }
    },
  );
}

// Exported for tests.
export const __internals = {
  INTENT_CANDIDATES,
  SYSTEM_CANDIDATES,
  INTENT_NOT_FOUND,
  SYSTEM_NOT_FOUND,
  readIfSafe,
  findFirst,
};
