# Acme Analytics — fictional local demo

A development fixture for Design Canvas, adapted from Tremor's MIT dashboard template. All users, email addresses, usage and billing values are fictional. Forms do not connect to account, billing or invitation services.

Requires Node.js 20.9+ and pnpm 10.

```sh
pnpm install --frozen-lockfile
NEXT_TELEMETRY_DISABLED=1 pnpm dev
```

Open `http://localhost:3000/overview`. Additional routes: `/details`, `/settings/general`, `/settings/billing`, `/settings/users`.

```sh
NEXT_TELEMETRY_DISABLED=1 pnpm build
```

The native app's built-in demo uses bundled screenshots, so it does not need this server. System fonts avoid external font downloads. Preserve [Tremor's MIT notice](LICENSE.md) when copying or modifying this fixture.
