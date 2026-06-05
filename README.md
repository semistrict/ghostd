# ghostd

Native Ghostty-backed terminal daemon with a browser client.

`ghostd` starts one long-lived PTY, renders it through Ghostty's native Zig
`ghostty-vt` core, and serves a small HTML client that can connect, reconnect,
watch as a reader, or claim the single writer role.

## Workspace

This repo has been trimmed to the files needed for `ghostd`:

- [`apps/ghostd`](apps/ghostd) - native daemon and browser client
- [`packages/@wterm/dom`](packages/@wterm/dom) - DOM terminal renderer and input handling
- [`packages/@wterm/core`](packages/@wterm/core) - shared terminal core types used by the renderer
- [`packages/@internal/ts`](packages/@internal/ts) - shared TypeScript config

## Requirements

- Node.js 24+
- pnpm 11+
- Zig 0.15.2 (`brew install zig@0.15`)
- portless installed globally with pnpm (`pnpm add -g portless`)

## Run

```bash
pnpm install
pnpm dev
```

The app is served at:

```text
https://ghostd.wterm.localhost
```

## Verify

```bash
pnpm build
pnpm type-check
pnpm test
```

## License

Apache-2.0
