#!/bin/sh
# The project dropdowns you type in (CL-183), against a sandbox `cl web` in
# headless Chromium: in the board's filter, "ep" (astro's key prefix) and "cl"
# (cl-wrapper's prefix and the start of its name) come first and Enter picks
# them; a word ("wrap", "backend") or initials work too. The New ticket, Ask
# and ticket Details dialogs get the same box, Escape closes the list before
# the dialog, and the form still submits the project picked, also when it was
# only typed (Ctrl+Enter, or a click on Create, with the list still open).
#
# Run from the checkout after `zig build`; needs chromium and node (22+).
# Every tmux call names the sandbox's socket (-S); nothing touches the real
# server. PORT (default 8444) must not be web.listen's.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
PORT=${PORT:-8444}
CDP=${CDP:-9344}
T=$(mktemp -d /tmp/cl-combo-test.XXXX)
S=$T/s
export HOME=$T XDG_RUNTIME_DIR=$T CL_TMUX_SOCKET=$S GH_CONFIG_DIR=$T/gh
cleanup() {
  [ -n "${WEB:-}" ] && kill "$WEB" 2>/dev/null
  [ -n "${CHROME:-}" ] && kill "$CHROME" 2>/dev/null
  tmux -S "$S" kill-server 2>/dev/null
  sleep 0.3
  \rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/.config/cl" "$T/gh"
cat > "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:$PORT
web.autostart = false
board.dispatch = false
EOF
printf 'combo-test-pw\ncombo-test-pw\n' | "$CL" web password >/dev/null || exit 1
add() { mkdir -p "$T/$1" && git -C "$T/$1" init -q && git -C "$T/$1" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init && "$CL" project add "$1" "$T/$1" --prefix "$2" >/dev/null || exit 1; }
add astro EP; add charts CH; add cl-wrapper CL; add cross-current-backend CCB; add screenreader-driver SD
"$CL" ticket new charts "A chart ticket" >/dev/null || exit 1

"$CL" web >"$T/web.log" 2>&1 &
WEB=$!
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$T/chrome" --window-size=1400,900 about:blank >"$T/chrome.log" 2>&1 &
CHROME=$!
for _ in $(seq 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP/json/version" && curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done

node .claude/test-project-combo.mjs "$PORT" "$CDP" "${SHOTS:-}"
status=$?
[ $status -ne 0 ] && { echo "--- web log"; tail -20 "$T/web.log"; }
exit $status
