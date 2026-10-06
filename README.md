# Design Canvas

A native macOS canvas for viewing your local web app across routes and viewport sizes, alongside Markdown, HTML documents and reference images. Its MCP server lets coding agents arrange frames and capture the canvas.

**[Download the official Mac app](https://www.designcanvas.app)** · **[Build from source](docs/BUILDING.md)** · **[MCP setup](docs/MCP.md)**

## Source and downloads

This MIT repository contains the current native app source, MCP server, tests and a fictional local demo. The official download is **0.6.2 (build 10), signed on 19 May 2026**. The source includes later work, including September account-usage and terminal-command features; the download is not a binary of this repository. See [verification and known limitations](docs/VERIFICATION.md).

The hosted sharing service and websites are operated separately and are not included here. Private research, planning, agent configuration, user data, submodules and the original Git history are excluded.

## Build on a Mac

Requires macOS 14 or later and full Xcode (not just Command Line Tools). Verified with Xcode 26.3 on macOS 15.6, Apple Silicon.

```sh
git clone https://github.com/charlieellington/design-canvas-app.git
cd design-canvas-app
./scripts/build-local.sh
open .build/native/Build/Products/Debug/DesignCanvas.app
```

The build resolves public Swifter and Sparkle dependencies. It needs no Apple Developer account, signing certificate, private repository, hosted-service credentials or submodules. The app is signed ad hoc for local use. For the bundled demo without scanning running projects:

```sh
DESIGN_CANVAS_DEMO=1 .build/native/Build/Products/Debug/DesignCanvas.app/Contents/MacOS/DesignCanvas
```

## Local behavior

- Telemetry, crash uploads and identity stitching are disabled.
- Account usage integrations are off until enabled in **View → Enable Account Usage Integrations**. Claude requires a separate login; Codex uses your locally installed CLI and account. These integrations are optional and may change with upstream APIs.
- Local builds use a separate bundle ID, app data, logs, screenshots and MCP token. The loopback API defaults to port 7420; use a separate port when running alongside the official app (see BUILDING.md).
- Local and fork builds never start the official updater. Official downloads keep their existing signed update feed.
- Creating a share link requires an explicitly configured, separately operated backend. Local canvas use and MCP screenshot captures do not require it. The unfinished pinned-comments roadmap is not implemented here.

Read [privacy and security](docs/PRIVACY.md) before connecting an agent to local files or enabling integrations.

## Repository

| Path | Contents |
| --- | --- |
| `DesignCanvas/` | SwiftUI/AppKit/WebKit app, Xcode project, native tests, bundled fictional screenshots |
| `mcp-server/` | TypeScript MCP adapter, CLI setup/repair commands and tests |
| `demo-app/` | Fictional Acme Analytics dashboard, derived from the MIT Tremor template |
| `scripts/` | Local build and native test commands |
| `docs/` | Public setup, behavior and verification documentation |
| `licenses/` | Preserved third-party notices |

```sh
./scripts/test-native.sh
cd mcp-server
npm ci
npm test
npm run build
npm pack --dry-run
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution rights and development scope. First-party code is [MIT licensed](LICENSE); third-party components retain [their notices](THIRD_PARTY_NOTICES.md). The MIT licence does not grant rights to third-party trademarks or imply that a fork is an official release.
