# ghostd

Browser client connected to one long-lived Ghostty-backed terminal session with one writer and many readers.

## Setup

```bash
pnpm --filter ghostd native:dev
```

The native daemon opens at `ghostd.wterm.localhost` through portless. It serves
the built HTML client from `dist` and accepts terminal clients at
`/api/terminal`.

## Native Daemon

`ghostd` runs as a native Ghostty-backed daemon:

```bash
pnpm --filter ghostd native:test
pnpm --filter ghostd build
pnpm --filter ghostd native:run
```

The native path uses Ghostty's Zig `ghostty-vt` module directly and requires
Zig 0.15.2 (`brew install zig@0.15`). It does not use the `@wterm/ghostty`
WASM adapter.

## How It Works

- The native daemon starts one shell in a PTY.
- PTY output is written into Ghostty's native Zig `ghostty-vt` terminal core.
- Browser clients connect to `/api/terminal` over WebSocket.
- WebSocket messages are MessagePack-encoded binary frames.
- New clients receive a full snapshot, so refreshing the page attaches to the current terminal state instead of creating a new shell.
- The first connected client becomes the writer. Additional clients are readers.
- Only the writer can send terminal input to the PTY. When the writer disconnects, the next connected reader becomes the writer.
- `pnpm --filter ghostd client:dev` runs the Vite development server for client-only iteration.

## Key Files

<table>
  <tr>
    <th>File</th>
    <th>Purpose</th>
  </tr>
  <tr>
    <td><code>native/src/main.zig</code></td>
    <td>Native PTY owner, Ghostty state, static file server, WebSocket server, and MessagePack snapshot encoder.</td>
  </tr>
  <tr>
    <td><code>src/remote-core.ts</code></td>
    <td>Client-side <code>TerminalCore</code> implementation backed by remote snapshots and row updates.</td>
  </tr>
  <tr>
    <td><code>src/protocol.ts</code></td>
    <td>Message types shared by the server and client.</td>
  </tr>
</table>
