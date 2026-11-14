#!/bin/sh
# Start now (CL-171), end to end on a sandbox board: `cl ticket new --start`
# starts a worktree ticket though every worktree slot is taken; an in-order
# sub-ticket behind an unfinished one waits in queued instead; a start that
# fails still prints the key (as JSON with --json), flags start-failed and
# exits non-zero; and POST /api/ticket refuses `start` on a backlog ticket.
#
# Run from the checkout after `zig build`. A fake `claude` on PATH shows a
# prompt and sleeps, so nothing real runs. Every tmux call names the
# sandbox's socket (-S); nothing touches the real server. PORT (default
# 8441) must not be web.listen's.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
PORT=${PORT:-8441}
T=$(mktemp -d /tmp/cl-start-now-test.XXXX)
S=$T/s
export HOME=$T XDG_RUNTIME_DIR=$T CL_TMUX_SOCKET=$S
t() { tmux -S "$S" "$@"; }
cleanup() {
  [ -n "${WEB:-}" ] && kill "$WEB" 2>/dev/null
  t kill-server 2>/dev/null
  sleep 0.3
  \rm -rf "$T"
}
trap cleanup EXIT
failed=0
check() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failed=$((failed + 1)); fi; }

mkdir -p "$T/bin" "$T/.config/cl" "$T/repo" "$T/empty"
printf '#!/bin/sh\nprintf "────\\n❯ \\n"\nexec sleep 600\n' > "$T/bin/claude"
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH"
cat > "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:$PORT
web.autostart = false
board.dispatch = false
EOF
printf 'startnow\nstartnow\n' | "$CL" web password >/dev/null || exit 1
(cd "$T/repo" && git init -q -b main && echo hi > f && git add f && git -c user.email=t@t -c user.name=t commit -qm init && jj git init --colocate -q) >/dev/null 2>&1
# A repo with no trunk to start from: its starts fail.
(cd "$T/empty" && jj git init -q) >/dev/null 2>&1
"$CL" project add qa "$T/repo" --prefix QA --slots 1 --mode worktree >/dev/null || exit 1
"$CL" project add bad "$T/empty" --prefix BAD --mode worktree >/dev/null 2>&1 || exit 1

# One slot, taken.
"$CL" t new qa "Running" --stage queued >/dev/null
"$CL" t start QA-1 >/dev/null 2>&1
out=$("$CL" t new qa "Hotfix" --priority 1 --start 2>&1)
"$CL" t show QA-2 | grep -q '^stage: running' && t has-session -t "$("$CL" t show QA-2 --json | sed -n 's/.*"tmux":"\([^"]*\)".*/\1/p')" 2>/dev/null
check $? "--start runs a worktree ticket with the only slot taken ($out)"
[ "$(t ls -F '#{session_name}' | grep -c '^cl_qa-')" = 2 ]
check $? "two worktree sessions run at once on a one-slot project"

# An in-order sub-ticket behind an unfinished one.
"$CL" t new qa "Steps" --umbrella >/dev/null                      # QA-3
"$CL" t new --parent QA-3 "First" --stage queued >/dev/null       # QA-4
out=$("$CL" t new --parent QA-3 "Second" --start 2>&1)            # QA-5
"$CL" t show QA-5 | grep -q '^stage: queued' && ! "$CL" t show QA-5 | grep -q '^session:' && echo "$out" | grep -q 'waits on QA-4'
check $? "--start on a sub-ticket behind QA-4 waits in queued ($(echo "$out" | tail -1))"

# A start that fails.
json=$("$CL" t new bad "Broken" --start --json 2>/dev/null); code=$?
[ $code != 0 ] && [ "$json" = '{"key":"BAD-1"}' ] && "$CL" t show BAD-1 | grep -q 'start-failed'
check $? "a failed --start --json prints {\"key\":\"BAD-1\"}, exits $code and flags start-failed"

# The API.
CL_PORT=$PORT "$CL" web >"$T/web.log" 2>&1 &
WEB=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
cookie=$(curl -s -D - -o /dev/null -d password=startnow "http://127.0.0.1:$PORT/login" | sed -n 's/^[Ss]et-[Cc]ookie: \(cl_session=[^;]*\).*/\1/p')
code=$(curl -s -o /dev/null -w '%{http_code}' -H "cookie: $cookie" -H "origin: http://127.0.0.1:$PORT" -H 'content-type: application/json' \
  -d '{"project":"qa","title":"Not queued","stage":"backlog","start":true}' "http://127.0.0.1:$PORT/api/ticket")
[ "$code" = 400 ] && ! "$CL" t list --project qa | grep -q 'Not queued'
check $? "POST /api/ticket refuses start on a backlog ticket ($code) and makes nothing"
body=$(curl -s -H "cookie: $cookie" -H "origin: http://127.0.0.1:$PORT" -H 'content-type: application/json' \
  -d '{"project":"qa","title":"Web hotfix","stage":"queued","mode":"worktree","start":true}' "http://127.0.0.1:$PORT/api/ticket")
[ "$body" = '{"key":"QA-6","start":"started"}' ]
check $? "POST /api/ticket with start starts it past the slot cap ($body)"

[ $failed = 0 ] && echo "all ok" || { echo "$failed failed"; echo "--- web log"; tail -5 "$T/web.log"; }
exit $failed
