# design-canvas-mcp

MCP adapter for the native [Design Canvas](https://www.designcanvas.app) Mac app. It connects coding agents to a loopback HTTP API and supports routes, Markdown/HTML documents, images, frame batches, sections and screenshots, plus project resources and setup/verification prompts.

Node.js 20.9+ and the Mac app are required. The npm package name remains `design-canvas-mcp` (published version 0.6.0). This source lives in [design-canvas-app](https://github.com/charlieellington/design-canvas-app/tree/main/mcp-server); it includes local-profile support beyond the older package.

## Official app

Configure your MCP client with `command: "npx"` and `args: ["-y", "design-canvas-mcp"]`. The official app creates its bearer token at `~/.designcanvas/api_token` and listens on port 7420.

## Source adapter and local app

```sh
npm ci
npm test
npm run build
DESIGN_CANVAS_PROFILE=local node dist/index.js
```

The last command starts an MCP stdio process. In an MCP client, use an absolute `node`/`dist/index.js` entry with `env: { "DESIGN_CANVAS_PROFILE": "local" }`. The local app creates `~/.designcanvas-local/api_token`. Use only one app at a time.

Optional environment settings: `DESIGN_CANVAS_TOKEN_FILE`, `DESIGN_CANVAS_TOKEN`, and a loopback-only `DESIGN_CANVAS_URL`. The adapter rereads tokens on each request. Never commit tokens or client configuration.

Read the [complete setup and tool reference](https://github.com/charlieellington/design-canvas-app/blob/main/docs/MCP.md). `install`/`repair` explicitly modify client settings and default to the published npm package; they do not automatically configure a local source adapter. `doctor` is read-only.

## Package review

```sh
npm pack --dry-run
```

The package contains compiled `dist/` JavaScript, package metadata, README and the MIT licence. Do not republish this snapshot as an unchanged 0.6.0 release. Publishing a new npm version is a separate maintainer task.

[MIT licence](LICENSE) · [Report a bug](https://github.com/charlieellington/design-canvas-app/issues)
