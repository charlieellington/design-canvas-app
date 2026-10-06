# Building and developing

Use full Xcode on macOS 14+. Select it with `xcode-select` if your active developer directory points to Command Line Tools. The tested configuration is Xcode 26.3, macOS 15.6, arm64.

From the repository root, `./scripts/build-local.sh` creates `.build/native/Build/Products/Debug/DesignCanvas.app`. Open that bundle directly. Public Swift dependencies are pinned in the Xcode project and `Package.resolved`; initial resolution needs network access. No private repositories, submodules, web service, developer account or distribution credentials are needed.

For an optimized local build:

```sh
CONFIGURATION=Release ./scripts/build-local.sh
open .build/native/Build/Products/Release/DesignCanvas.app
```

Both configurations use `com.designcanvas.app.local` and an ad hoc signature. Opening the Xcode project and choosing the DesignCanvas scheme also works with ad hoc signing; choose your own team only if you want your own signed distribution. Forks should choose their own bundle ID and data namespace before distributing. Do not install a local build over the official download.

If the official app already uses port 7420, launch the source build with `DESIGN_CANVAS_PORT=7421` and set `DESIGN_CANVAS_URL=http://127.0.0.1:7421` on its MCP adapter. This does not change the existing npm package defaults.

## Native tests

`./scripts/test-native.sh` runs the hosted XCTest target. App startup services are skipped in the test host. Tests cover canvas geometry, document state, routes, workspace file indexing, Markdown path repair, onboarding, MCP activity, usage decoding/polling and local build policy.

## Fictional demo

The app's built-in demo uses bundled screenshots without fetching a hosted demo. `DESIGN_CANVAS_DEMO=1` forces that mode and disables automatic project scanning for reproducible previews.

The separate `demo-app/` source contains only fictional dashboard data. Email addresses use `example.com`. It needs Node.js 20.9+ and pnpm 10:

```sh
cd demo-app
pnpm install --frozen-lockfile
NEXT_TELEMETRY_DISABLED=1 pnpm dev
```

Open `http://localhost:3000/overview`. Routes include `/details`, `/settings/general`, `/settings/billing` and `/settings/users`. It has no real billing, account or invitation backend. Build with `NEXT_TELEMETRY_DISABLED=1 pnpm build`. System fonts avoid a build-time Google Fonts dependency. The demo is a development fixture, not a hosted production service.

## Maintainer distributions

The official bundle identity remains `com.designcanvas.app`. Its existing updater uses `https://www.designcanvas.app/appcast.xml` and the existing public EdDSA verification key. The official download and feed are not moved to this repository.

A future official build must explicitly set `DC_OFFICIAL_DISTRIBUTION=YES`, use the official bundle ID and pass signature validation for the original release team before the updater can start. The flag alone does not enable updates for a fork or ad hoc build. Maintainers must separately configure any sharing backend. Public source has no telemetry provider configuration.

Official signing, notarization, Sparkle signing, storage uploads and feed publishing remain a separate maintainer release process. This repository's scripts never retrieve Keychain distribution credentials, upload symbols, publish a DMG, modify an appcast or push commits. Do not treat a source snapshot or local app as a new official binary release.
