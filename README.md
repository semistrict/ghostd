# ghostd

`ghostd` is a native Ghostty-backed terminal daemon with a browser client.
It keeps one long-lived PTY on the server and lets browser tabs reconnect as
readers or claim the single writer role.

This repository is laid out as a Zig project with a TypeScript browser client
in `web/`. The browser assets are built and embedded into the native binary, so
the daemon can serve the client itself. The remaining `@ghostd-web/*` packages are
local support packages used by the browser client; they are not separate
applications.

## What It Does

- Runs a native Zig server backed by Ghostty's `ghostty-vt` terminal core.
- Embeds the built `web/` client into the Zig binary and serves it over HTTP.
- Supports one writer and many readers.
- Lets a reader steal writer mode.
- Preserves terminal state across browser reconnects.
- Uses the writer viewport as the PTY size.
- Includes Playwright regressions that log frontend activity, DOM mutations,
  and decoded WebSocket messages.

Current scope: one terminal session per daemon process.

## Layout

- `src/` - Zig daemon source.
- `web/` - browser client source and Vite build.
- `tests/` - Playwright e2e tests.
- `scripts/` - build helpers, asset embedding, and portless wrapper.
- `packages/@ghostd-web/dom` - local DOM renderer/input package.
- `packages/@ghostd-web/core` - local shared renderer/core TypeScript types.
- `packages/@internal/ts` - shared TypeScript config.

## Requirements

- Node.js 24+
- pnpm 11+
- Zig 0.15.2 (`brew install zig@0.15`)
- portless installed globally with pnpm:

```bash
pnpm add -g portless
```

## Run

```bash
pnpm install
pnpm dev
```

Portless serves the app at:

```text
https://ghostd-web.localhost
```

## Scripts

```bash
pnpm dev          # build and run ghostd through portless
pnpm build        # build local TS packages, web client, and embedded assets
pnpm build:web    # build web/ and regenerate embedded asset sources
pnpm type-check   # type-check all TypeScript packages
pnpm test         # DOM tests, native tests, and Playwright e2e tests
pnpm e2e          # Playwright e2e tests only
```

Native commands:

```bash
pnpm native:run
pnpm native:test
pnpm e2e
```

Direct Zig build:

```bash
sh scripts/zig-015.sh build
./zig-out/bin/ghostd --port 7341
```

Plain `zig build` also works when `zig` on `PATH` is Zig 0.15.x. Ghostty 1.3.1
does not build with Zig 0.16.

## Test Artifacts

The Playwright tests write decoded frontend/WebSocket traces under
`test-results/`. These files are ignored by git.

## Embedded Web Assets

`pnpm build:web` builds `web/` with Vite, scans `web/dist/`, and generates
`src/embedded_assets.zig` plus copied embed files under
`src/embedded_asset_files/`. Those generated files are checked in so the Zig
binary can be built directly without pnpm. Regenerate them after changing
anything under `web/`.

## License

Apache-2.0
