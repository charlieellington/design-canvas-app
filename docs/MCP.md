# MCP server

The npm identity remains **`design-canvas-mcp`**. The current published version is **0.6.0**; moving source into this repository does not rename the package or publish a new version. Repository metadata and issue links in this source point here. The npm registry's existing metadata changes only with a future package release.

## Official download

With the official Mac app running, configure your MCP client to execute:

```json
{
  "mcpServers": {
    "design-canvas": {
      "command": "npx",
      "args": ["-y", "design-canvas-mcp"]
    }
  }
}
```

The existing package uses port 7420 and `~/.designcanvas/api_token`. It requires Node.js 20.9+. The app must be running; routes need a running local dev server. Markdown and image frames do not require a dev server.

## Current source / local builds

Build this adapter before configuring a client:

```sh
cd mcp-server
npm ci
npm run build
npm test
```

Use an absolute path to your clone's `mcp-server/dist/index.js` with the local profile:

```json
{
  "mcpServers": {
    "design-canvas": {
      "command": "node",
      "args": ["/absolute/path/to/design-canvas-app/mcp-server/dist/index.js"],
      "env": { "DESIGN_CANVAS_PROFILE": "local" }
    }
  }
}
```

The local app creates `~/.designcanvas-local/api_token`. `DESIGN_CANVAS_PROFILE=local` selects that file. This profile option belongs to the source exported here and is not promised in the older published npm package. Keep the clone path stable or update your client's entry when you move it. For clients without Node on PATH, use the absolute Node executable path.

`DESIGN_CANVAS_TOKEN_FILE` can choose another token file. `DESIGN_CANVAS_TOKEN` overrides the file; keep tokens in local environment/configuration, never in a repository. `DESIGN_CANVAS_URL` may choose another loopback HTTP(S) origin; remote hosts are rejected. Tokens are reread per request so an app restart or token rotation does not require restarting the source adapter.

## Tools

| Tools | Behavior |
| --- | --- |
| `list_servers` | Inspect connected dev-server bindings |
| `list_routes`, `add_route`, `remove_route`, `update_route` | Inspect and arrange live route frames; update a frame's saved path |
| `list_documents`, `add_document`, `remove_document` | Manage local Markdown or HTML frames |
| `list_images`, `add_image`, `remove_image` | Manage reference image frames |
| `add_frames` | Add a mixed batch of frames with a single layout pass |
| `list_sections`, `add_section`, `remove_section` | Manage named frame groups; removing a section also removes its frames |
| `capture_canvas` | Capture rendered routes and return images to the agent |

The adapter also exposes `design-canvas://design-intent.md`, `design-canvas://design-system.md` and `design-canvas://routes.json`, and setup, verify and start-design prompts. Use only with projects and agents you trust. Screenshot capture uses WebKit; verify browser-specific behavior separately when needed.

CLI commands: `install`, `doctor`, `repair`, `--help`. Installation and repair write client configuration only when explicitly invoked, and use the existing npm package by default. They do not select your local source build automatically. Set up the local entry above yourself. For a read-only local health check:

```sh
DESIGN_CANVAS_PROFILE=local node dist/index.js doctor
```

Report bugs at [this repository's issues](https://github.com/charlieellington/design-canvas-app/issues). Relevant implementation lives in `src/api-client.ts`, `src/tools.ts`, `src/resources.ts` and `src/prompts.ts`.
