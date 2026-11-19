#!/bin/sh
# Ctrl+K finds a ticket by its PR's number (CL-180), against a sandbox
# `cl web` in headless Chromium: "2738" and "#2738" list both tickets whose
# PRs are #2738 (in two repos), with "PR <repo>#2738" in each one's note;
# a ticket whose key is the number typed comes before a PR match, and after
# one when the number is typed with "#"; a ticket whose key and PR both match
# ranks with the other key matches; Enter opens the ticket. A Done ticket
# whose PR was opened outside `cl ticket done --pr-url` (WEB-2) gets it on
# record from the dispatcher's one look (a fake gh answers), and Ctrl+K finds
# it; one whose branch has no PR (WEB-3) is looked at once and left be.
#
# Run from the checkout after `zig build`; needs chromium, node (22+) and
# sqlite3. Every tmux call names the sandbox's socket (-S); nothing touches
# the real server. PORT (default 8443) must not be web.listen's.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
PORT=${PORT:-8443}
CDP=${CDP:-9343}
T=$(mktemp -d /tmp/cl-pal-pr-test.XXXX)
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

mkdir -p "$T/.config/cl" "$T/qa" "$T/web" "$T/gh" "$T/bin"
# gh pr list --head <branch>: only web-2-footer has a PR, acme/site#2741.
cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = --head ] && b=$2; shift; done
[ "$b" = web-2-footer ] && echo https://github.com/acme/site/pull/2741
exit 0
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
cat > "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:$PORT
web.autostart = false
board.dispatch = true
EOF
printf 'pal-test-pw\npal-test-pw\n' | "$CL" web password >/dev/null || exit 1
for p in qa web; do git -C "$T/$p" init -q && git -C "$T/$p" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init; done

# QA-1 and WEB-1: PRs #2738 in two repos (WEB-1 merged, Done). QA-2: PR #12.
# QA-3 has PR #3, its own key's number, and WEB-3's key is that number too.
# Twelve QA tickets, so QA-12's key is a number one PR has too.
DB=$T/.local/state/cl/board.db
"$CL" project add qa "$T/qa" --prefix QA >/dev/null || exit 1
"$CL" project add web "$T/web" --prefix WEB >/dev/null || exit 1
for i in $(seq 12); do "$CL" ticket new qa "Ticket $i" >/dev/null || exit 1; done
for t in "Login page" "Footer" "Header"; do "$CL" ticket new web "$t" >/dev/null || exit 1; done
sqlite3 "$DB" "UPDATE tickets SET pr_url = 'https://github.com/acme/api/pull/2738', pr_stage = 'review', stage = 'review' WHERE key = 'QA-1';
  UPDATE tickets SET pr_url = 'https://github.com/acme/site/pull/2738', stage = 'done' WHERE key = 'WEB-1';
  UPDATE tickets SET pr_url = 'https://github.com/acme/api/pull/12' WHERE key = 'QA-2';
  UPDATE tickets SET pr_url = 'https://github.com/acme/api/pull/3' WHERE key = 'QA-3';
  UPDATE tickets SET stage = 'done', branch = 'web-2-footer' WHERE key = 'WEB-2';
  UPDATE tickets SET stage = 'done', branch = 'web-3-header' WHERE key = 'WEB-3';" || exit 1

"$CL" web >"$T/web.log" 2>&1 &
WEB=$!
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$T/chrome" --window-size=1400,900 about:blank >"$T/chrome.log" 2>&1 &
CHROME=$!
for _ in $(seq 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP/json/version" && curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done

node .claude/test-pal-pr.mjs "$PORT" "$CDP"
status=$?
events=$(sqlite3 "$DB" "SELECT t.key || ' ' || e.kind || ' ' || e.detail FROM events e JOIN tickets t ON t.id = e.ticket WHERE e.kind LIKE 'pr %' ORDER BY e.id")
expect="WEB-2 pr lookup 
WEB-3 pr lookup 
WEB-2 pr found https://github.com/acme/site/pull/2741
WEB-3 pr not found web-3-header"
# The two detached lookups may finish in either order.
if [ "$(echo "$events" | sort)" = "$(echo "$expect" | sort)" ]; then echo "ok   each Done ticket with a branch was looked up once: WEB-2's PR found, WEB-3 none"
else echo "FAIL the lookups' events"; echo "$events"; status=1; fi
[ $status -ne 0 ] && { echo "--- web log"; tail -20 "$T/web.log"; }
exit $status
