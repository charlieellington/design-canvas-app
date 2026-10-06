// MCP Prompts — §5.2 of documentation/mcp-onboarding-update.md.
// Three slash-command-shaped workflows, surfaced by clients that support prompts/list.
// Each prompt returns a single user-role message containing the workflow instruction
// the agent is expected to follow step by step.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

const SETUP_INSTRUCTION = `Bootstrap Design Canvas for this project. Execute in order; stop and ask the user the moment anything is ambiguous.

1. Call list_routes. If it returns "Design Canvas is not running", report that verbatim and ask the user to open the Design Canvas Mac app. Do not continue.
2. Detect the project type from the user's cwd by looking for these files (use read-only ls/glob — never write yet):
   - package.json → Node (inspect scripts.dev / scripts.start; detect npm/pnpm/yarn/bun from lockfile)
   - Cargo.toml → Rust (cargo run)
   - pyproject.toml or requirements.txt → Python (ask for dev command)
   - go.mod → Go (go run .)
   - Gemfile → Ruby (bin/dev or bundle exec rails s)
3. If no project file is found, tell the user: "I'm not in a project directory. cd into your app's folder and ask me again." Stop.
4. Pick the right dev command for the detected type. Before running it, summarise to the user: "I'll run: <command>. OK?" Only proceed on explicit yes.
5. Start the dev server in a non-blocking shell (background it — never hold the foreground).
6. Poll list_routes every 2 seconds for up to 20 seconds. The moment it returns routes, tell the user: "Your routes are live on the canvas."
7. If polling times out, report the specific failure mode verbatim (missing node_modules → offer to run install; port conflict → surface the port and ask; dev command syntax error → surface the error). Never guess; ask.
8. Once routes render, offer three next steps: (a) generate a new page, (b) refactor an existing route, (c) capture the canvas to review.`;

const VERIFY_INSTRUCTION = `Run the Design Canvas capture-and-critique loop.

1. If a targetRoute argument was provided, filter to that route only. Otherwise verify all routes.
2. Read the design-canvas://design-intent.md resource. If the resource reports no design-intent.md exists, ask the user for the target they have in mind (brand, references, vibe) and proceed with their answer as the intent. Never invent intent.
3. Call capture_canvas (pass the targetRoute id if provided).
4. For each returned screenshot, compare against the intent and write a punch list under these headings:
   - Spacing — mismatched scales, inconsistent padding, crowded regions
   - Typography — font-weight drift, size hierarchy breaks, line-height issues
   - Colour — palette drift, contrast failures, brand-adjacent wrong tones
   - Hierarchy — unclear primary action, flat visual weight, focus-state omissions
5. Where possible, pin each punch-list item to a specific file + line pointer in the user's codebase (grep for the component name).
6. End with: "Top 3 fixes I'd apply first: <list>. Want me to apply them?"`;

const START_DESIGN_INSTRUCTION = `Cold-start a new route or page with Design Canvas informing the agent loop.

1. Read design-canvas://design-intent.md and design-canvas://design-system.md. If either is missing, ask the user for the equivalent in one short paragraph. Log their answer as the working intent for this session.
2. Call list_routes to see existing patterns. Note the spacing scale, typography conventions, and colour palette already in use — the new route must honour them.
3. If a reference argument was provided (URL or path), open it (fetch for URL; read for path) and treat its visual cues as targets.
4. Generate the first-pass UI in the user's codebase. Prefer composition of existing components over new ones. Keep your diff minimal.
5. Wait for the dev server to pick up the change (HMR), then call capture_canvas limited to the new route.
6. Self-critique the capture against the intent + references + existing patterns. If any item scores poorly, apply up to two small fixes without asking; anything larger, ask first.
7. Offer the iteration loop: "Want to refine? I can try a different direction, tighten spacing, or change the copy."`;

export function registerPrompts(server: McpServer): void {
  server.registerPrompt(
    "setup",
    {
      title: "Bootstrap Design Canvas",
      description: "Detect project type, start dev server, confirm routes render on the canvas.",
      argsSchema: {},
    },
    async () => ({
      messages: [
        {
          role: "user",
          content: { type: "text", text: SETUP_INSTRUCTION },
        },
      ],
    }),
  );

  server.registerPrompt(
    "verify",
    {
      title: "Capture + critique against design intent",
      description: "Capture the canvas, diff against design-intent.md, return a prioritised punch list.",
      argsSchema: {
        targetRoute: z.string().optional().describe("Route id or path to focus the critique on. Omit for all routes."),
      },
    },
    async (args) => {
      const target = args?.targetRoute ? `\n\nTarget route: ${args.targetRoute}` : "";
      return {
        messages: [
          {
            role: "user",
            content: { type: "text", text: VERIFY_INSTRUCTION + target },
          },
        ],
      };
    },
  );

  server.registerPrompt(
    "start-design",
    {
      title: "Cold-start a new route",
      description: "Generate a first-pass UI honouring the project's intent, design system, and existing routes.",
      argsSchema: {
        prompt: z.string().describe("What you want built — a paragraph is fine."),
        reference: z.string().optional().describe("URL or local path to a visual reference."),
      },
    },
    async (args) => {
      const intent = args?.prompt ? `\n\nUser intent: ${args.prompt}` : "";
      const ref = args?.reference ? `\n\nReference: ${args.reference}` : "";
      return {
        messages: [
          {
            role: "user",
            content: { type: "text", text: START_DESIGN_INSTRUCTION + intent + ref },
          },
        ],
      };
    },
  );
}

// Exported for tests.
export const __internals = {
  SETUP_INSTRUCTION,
  VERIFY_INSTRUCTION,
  START_DESIGN_INSTRUCTION,
};
