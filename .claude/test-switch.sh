#!/bin/sh
# Switching between the web board and a session's terminal (CL-164), end to
# end in headless Chromium against a sandbox `cl web`: the board comes back
# from the back/forward cache as it was, a terminal reopened from the board
# comes back the same way and connects again (what's typed reaches the
# session), Ctrl-Q goes back too, another session's terminal and one opened
# in a new tab load as before, and the pages answer 304 when unchanged.
# Prints how long each switch took.
#
# Run from the checkout after `zig build`; needs chromium and node (22+).
# Every tmux call names the sandbox's socket (-S); nothing touches the real
# server. PORT (default 8439) must not be web.listen's.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
PORT=${PORT:-8439}
CDP=${CDP:-9339}
T=$(mktemp -d /tmp/cl-switch-test.XXXX)
S=$T/s
export HOME=$T XDG_RUNTIME_DIR=$T CL_TMUX_SOCKET=$S
t() { tmux -S "$S" "$@"; }
cleanup() {
  [ -n "${WEB:-}" ] && kill "$WEB" 2>/dev/null
  [ -n "${CHROME:-}" ] && kill "$CHROME" 2>/dev/null
  t kill-server 2>/dev/null
  sleep 0.3
  \rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/.config/cl"
cat > "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:$PORT
web.autostart = false
board.dispatch = false
EOF
printf 'switchtest\nswitchtest\n' | "$CL" web password >/dev/null || exit 1
# Two sessions to open, each a shell that shows what's typed into it.
t new-session -d -s cl_switch_a -x 120 -y 30 "env PS1='a\$ ' sh"
t new-session -d -s cl_switch_b -x 120 -y 30 "env PS1='b\$ ' sh"

CL_PORT=$PORT "$CL" web >"$T/web.log" 2>&1 &
WEB=$!
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$T/chrome" --window-size=1200,800 about:blank >"$T/chrome.log" 2>&1 &
CHROME=$!
for _ in $(seq 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP/json/version" && curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done

node .claude/test-switch.mjs "$PORT" "$CDP" "$S"
status=$?
[ $status -ne 0 ] && { echo "--- web log"; tail -20 "$T/web.log"; }
exit $status
