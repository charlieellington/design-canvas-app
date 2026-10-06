# Local data and optional services

Public-source builds send no analytics, crash reports or download identity-stitching requests. The wrappers are no-ops and telemetry SDK dependencies are removed. Logs stay on your Mac and may contain project paths and URLs; inspect them before sharing a bug report.

Local app storage:

| Data | Location |
| --- | --- |
| Preferences | `com.designcanvas.app.local` UserDefaults domain |
| Sessions and saved command palette | `~/Library/Application Support/DesignCanvasLocal/` |
| Screenshots | `~/Library/Caches/DesignCanvasLocal/screenshots/` |
| Logs | `~/Library/Logs/DesignCanvasLocal/app.log` |
| MCP bearer token | `~/.designcanvas-local/api_token` |

Verified official builds retain the corresponding `DesignCanvas` and `.designcanvas` directories. Local builds do not migrate official app data. Forks can change BuildPolicy's local namespace for further separation.

The app discovers local dev servers, inspects their project directories and renders pages in WebKit. Pages you open can make their own network requests. Markdown and HTML frames are local content; HTML can execute scripts. Connecting an agent grants it the local canvas API's ability to read selected files and capture rendered content. Connect only agents and projects you trust.

The API binds to loopback and checks bearer authentication and Host headers. The token is stored with owner-only permissions. It is not a network sharing API. The MCP adapter refuses non-loopback URLs so it cannot send a local token to a remote host. The official and local apps default to port 7420. To run them together, set DESIGN_CANVAS_PORT to a different port on the local app and point its MCP adapter at that loopback origin.

## Account usage

**View → Enable Account Usage Integrations** is off by default. Enabling it starts optional Claude usage polling and a local `codex app-server` process. Claude cookies live in this app's WebKit profiles, including a separate profile for a second account. Codex uses the existing locally installed CLI's account session; the app does not collect a new API key. Disable the toggle to stop polling and the process. Use each account's sign-out control to clear Claude cookies.

Claude usage depends on an unofficial endpoint. Codex account and rate-limit behavior depends on the installed CLI. Neither integration is required for the canvas or MCP.

## Sharing

Creating links is disabled until you explicitly set `DesignCanvasShareBaseURL` to a backend implementing the share protocol. The backend is not included. HTTPS is required, except for HTTP on loopback. For your own local development backend, for example:

```sh
defaults write com.designcanvas.app.local DesignCanvasShareBaseURL -string 'http://127.0.0.1:4000'
```

Restart the app after changing it. Remove the setting with `defaults delete com.designcanvas.app.local DesignCanvasShareBaseURL`. Creating a link uploads selected frame images and layout metadata to that endpoint. Setting a URL does not provide a hosted service or enable pinned comments. No default localhost service or hosted domain is contacted by sharing.

Local/fork builds do not check the official update feed or replace themselves with an official download. Updating a fork is the fork maintainer's responsibility.
