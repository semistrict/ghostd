#!/bin/sh
set -eu

if command -v portless >/dev/null 2>&1; then
  exec portless "$@"
fi

PNPM_GLOBAL_BIN="${PNPM_HOME:-$HOME/Library/pnpm}"
if [ -x "$PNPM_GLOBAL_BIN/portless" ]; then
  exec "$PNPM_GLOBAL_BIN/portless" "$@"
fi
if [ -x "$PNPM_GLOBAL_BIN/bin/portless" ]; then
  exec "$PNPM_GLOBAL_BIN/bin/portless" "$@"
fi

printf '\nportless is required but not installed. Run: pnpm add -g portless\nSee: https://github.com/vercel-labs/portless\n\n' >&2
exit 1
