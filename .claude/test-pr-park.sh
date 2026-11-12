#!/bin/sh
# A ticket finished with a PR (CL-167), end to end against a sandbox
# `cl web` in headless Chromium: it waits in its stage parked on the PR (the
# card says "Waiting on PR #31", the popup links the PR), a review comment
# wakes it (flagged, its session resumed), its round's `done` parks it on the
# PR again in the same stage, and the merge moves it to Done. The Done
# dialog says PR keeps it where it is.
#
# gh and claude are fakes in the sandbox's bin: gh answers from files in
# $T/gh, claude just waits. Run from the checkout after `zig build`; needs
# chromium, node (22+) and sqlite3. Every tmux call names the sandbox's
# socket (-S); nothing touches the real server. PORT (default 8441) must not
# be web.listen's.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
SRC=$PWD
PORT=${PORT:-8441}
CDP=${CDP:-9341}
T=$(mktemp -d /tmp/cl-pr-park-test.XXXX)
S=$T/s
export HOME=$T XDG_RUNTIME_DIR=$T CL_TMUX_SOCKET=$S FAKE_GH=$T/gh PATH="$T/bin:$PATH"
cleanup() {
  [ -n "${WEB:-}" ] && kill "$WEB" 2>/dev/null
  [ -n "${CHROME:-}" ] && kill "$CHROME" 2>/dev/null
  tmux -S "$S" kill-server 2>/dev/null
  sleep 0.3
  \rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/.config/cl" "$T/bin" "$T/gh" "$T/qa"
cat > "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:$PORT
web.autostart = false
board.dispatch = false
EOF
printf 'prtest-pw\nprtest-pw\n' | "$CL" web password >/dev/null || exit 1
cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
"pr view") cat "$FAKE_GH/view" ;;
"pr checks") cat "$FAKE_GH/checks"; exit 1 ;;
api*) cat "$FAKE_GH/inline" ;;
*) echo "unexpected: $*"; exit 2 ;;
esac
EOF
printf '#!/bin/sh\nexec sleep 600\n' > "$T/bin/claude"
chmod +x "$T/bin/gh" "$T/bin/claude"
git -C "$T/qa" init -q && git -C "$T/qa" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init

# QA-1 is finishing with a PR, as the Done dialog's PR leaves it, and Claude
# reports the PR; QA-2 is in Review with a branch, for the Done dialog.
DB=$T/.local/state/cl/board.db
"$CL" project add qa "$T/qa" --prefix QA >/dev/null || exit 1
"$CL" ticket new qa "Assignable members" >/dev/null && "$CL" ticket new qa "Another one" >/dev/null || exit 1
"$CL" ticket move QA-1 review >/dev/null && "$CL" ticket move QA-2 review >/dev/null || exit 1
sqlite3 "$DB" "UPDATE tickets SET branch = 'qa-1-assignable', finishing = 'pr', session_id = '00000000-0000-4000-8000-000000000001' WHERE key = 'QA-1'; UPDATE tickets SET branch = 'qa-2-another' WHERE key = 'QA-2';"
"$CL" ticket done QA-1 --close --pr-url https://github.com/o/r/pull/31 --summary "Opened the PR" || exit 1

CL_PORT=$PORT "$CL" web >"$T/web.log" 2>&1 &
WEB=$!
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$T/chrome" --window-size=1400,900 about:blank >"$T/chrome.log" 2>&1 &
CHROME=$!
for _ in $(seq 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP/json/version" && curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done

# What the page script runs between its checks: a park check (with gh's
# answers from $T/gh), and Claude's `done` after its round.
cat > "$T/step" <<EOF
#!/bin/sh
case "\$1" in
feedback) cat "$SRC/.claude/test-pr-park/view.json" > "$FAKE_GH/view"; cp "$SRC/.claude/test-pr-park/inline.jsonl" "$FAKE_GH/inline"; echo '[]' > "$FAKE_GH/checks" ;;
merged) echo '{"state":"MERGED","headRefOid":"e8e7"}' > "$FAKE_GH/view" ;;
round) "$CL" ticket done QA-1 --summary "Fixed it; proposed reply: ..." ; exit ;;
esac
"$CL" ticket park-check QA-1 --at "\$(sqlite3 "$DB" "SELECT at FROM parks WHERE ticket = (SELECT id FROM tickets WHERE key = 'QA-1')")"
EOF
chmod +x "$T/step"

node .claude/test-pr-park.mjs "$PORT" "$CDP" "$T/step" "$S"
status=$?
[ $status -ne 0 ] && { echo "--- web log"; tail -20 "$T/web.log"; }
exit $status
