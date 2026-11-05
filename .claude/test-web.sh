#!/bin/sh
# A second cl web on port 8431, from this checkout's build, on the real board.
# Its own HOME holds a copy of ~/.config/cl/config with another port and the
# dispatcher off, so it doesn't start tickets alongside the main cl web.
set -e
cd "$(dirname "$0")/.."
T=/tmp/cl-test-web-$(id -u)
mkdir -p "$T/.config/cl"
sed -e "s#~/#$HOME/#g" -e '/^web\.listen/d' -e '/^web\.autostart/d' -e '/^board\.dir/d' \
    -e '/^board\.worktrees/d' -e '/^board\.dispatch/d' "$HOME/.config/cl/config" > "$T/.config/cl/config"
cat >> "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:8431, tailscale:8431
web.autostart = false
board.dir = $HOME/.local/state/cl
board.worktrees = $HOME/.local/share/cl/worktrees
board.dispatch = false
EOF
exec env HOME="$T" CL_TEST_WEB=1 "$PWD/zig-out/bin/cl" web
