# ghostd

`ghostd` is a native Ghostty-backed terminal daemon with a browser client.
It keeps one long-lived PTY on the server and lets browser tabs reconnect as
readers or claim the single writer role.

This repository is now laid out as a Zig project with a TypeScript browser
client in `web/`. The remaining `@wterm/*` packages are local support packages
used by the browser client; they are not separate applications.

## What It Does

- Runs a native Zig server backed by Ghostty's `ghostty-vt` terminal core.
- Embeds the built `web/` client into the Zig binary and serves it over HTTP.
- Supports one writer and many readers.
- Lets a reader steal writer mode.
- Preserves terminal state across browser reconnects.
- Uses the writer viewport as the PTY size.
- Includes Playwright regressions that log frontend activity, DOM mutations,
  and decoded WebSocket messages.

## Workspace Packages

- `src/` - Zig daemon source.
- `web/` - browser client source and Vite build.
- `tests/` - Playwright e2e tests.
- `@wterm/dom` (`packages/@wterm/dom`) - local DOM renderer/input package.
- `@wterm/core` (`packages/@wterm/core`) - local renderer core types/WASM bridge.
- `@internal/ts` (`packages/@internal/ts`) - shared TypeScript config.

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
https://ghostd.wterm.localhost
```

## Scripts

```bash
pnpm dev          # build and run ghostd through portless
pnpm build        # build the browser client
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

## Test Artifacts

The Playwright tests write decoded frontend/WebSocket traces under
`test-results/`. These files are ignored by git.

## Embedded Web Assets

`pnpm build:web` builds `web/` with Vite, scans `web/dist/`, and generates
`src/embedded_assets.zig` plus copied embed files under
`src/embedded_asset_files/`. Those generated files are ignored by git and are
rebuilt before native build/run/test commands.

## License

Apache-2.0
