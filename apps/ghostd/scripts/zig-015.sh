#!/bin/sh
set -eu

if [ -x /opt/homebrew/opt/zig@0.15/bin/zig ]; then
  exec /opt/homebrew/opt/zig@0.15/bin/zig "$@"
fi

if [ -x "$HOME/.local/share/zigup/0.15.2/files/zig" ]; then
  exec "$HOME/.local/share/zigup/0.15.2/files/zig" "$@"
fi

echo "ghostd native requires Zig 0.15.2." >&2
echo "Install with: brew install zig@0.15" >&2
exit 1
