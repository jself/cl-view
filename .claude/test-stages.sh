#!/bin/sh
# Test first, review last (CL-168), against a sandbox `cl web` in headless
# Chromium: the columns read Running, Testing, Review in Board and Lanes; a
# ticket Claude finished with a test plan is in Testing, "Ready to test" with
# its summary, and approves "Tested, to review"; one with no test plan went
# straight to Review, "Ready for review", and its "Approve, finish…" opens the
# Done dialog; a ticket held in Running for its automated review says
# "reviewing" and isn't in Needs You.
#
# Run from the checkout after `zig build`; needs chromium, node (22+) and
# sqlite3. Every tmux call names the sandbox's socket (-S); nothing touches
# the real server. PORT (default 8442) must not be web.listen's.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
PORT=${PORT:-8442}
CDP=${CDP:-9342}
T=$(mktemp -d /tmp/cl-stages-test.XXXX)
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

mkdir -p "$T/.config/cl" "$T/qa" "$T/gh"
cat > "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:$PORT
web.autostart = false
board.dispatch = false
EOF
printf 'stages-pw\nstages-pw\n' | "$CL" web password >/dev/null || exit 1
git -C "$T/qa" init -q && git -C "$T/qa" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init

# QA-1: Claude finished with a test plan (Testing). QA-2: finished with none
# (straight to Review), with a branch for the Done dialog. QA-3: Claude
# finished and its automated review runs (held in Running), its session idle.
DB=$T/.local/state/cl/board.db
"$CL" project add qa "$T/qa" --prefix QA >/dev/null || exit 1
for t in "Assignable members" "Rename the setting" "Retry on EBUSY"; do "$CL" ticket new qa "$t" >/dev/null || exit 1; done
for k in QA-1 QA-2 QA-3; do "$CL" ticket move $k running >/dev/null || exit 1; done
"$CL" ticket done QA-1 --summary "Members can be assigned from the card" --test-plan - >/dev/null <<'EOF' || exit 1
## Try it
- [ ] the card has an Assign button
EOF
"$CL" ticket done QA-2 --summary "Renamed it everywhere" >/dev/null || exit 1
sqlite3 "$DB" "UPDATE tickets SET branch = 'qa-2-rename' WHERE key = 'QA-2';
  UPDATE tickets SET autoreview = '{\"status\":\"running\",\"started\":$(date +%s),\"round\":1,\"auto\":\"send\",\"held\":true}' WHERE key = 'QA-3';
  INSERT INTO flags (ticket, kind, source, detail, at) SELECT id, 'idle', 'auto', '', 1 FROM tickets WHERE key = 'QA-3';" || exit 1

CL_PORT=$PORT "$CL" web >"$T/web.log" 2>&1 &
WEB=$!
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$T/chrome" --window-size=1400,900 about:blank >"$T/chrome.log" 2>&1 &
CHROME=$!
for _ in $(seq 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP/json/version" && curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done

node .claude/test-stages.mjs "$PORT" "$CDP"
status=$?
[ $status -ne 0 ] && { echo "--- web log"; tail -20 "$T/web.log"; }
exit $status
