#!/bin/sh
# The three-part handoff (CL-169), end to end in a sandbox: `cl ticket done`
# takes # Verified, # Test plan and # Demo; `cl ticket testplan` prints all
# three; a demo step launches in clrun_<key>_d<n>; and in headless Chromium
# the Test tab shows "Checked by Claude" (and "Works as expected" for a plan
# without checks) while the Demo tab walks its steps without Pass/Fail.
#
# Run from the checkout after `zig build`; needs chromium and node (22+).
# Every tmux call names the sandbox's socket (-S); nothing touches the real
# server. PORT (default 8443) must not be web.listen's. SHOTS=<dir> keeps
# screenshots of the two tabs.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
SRC=$PWD
PORT=${PORT:-8443}
CDP=${CDP:-9343}
T=$(mktemp -d /tmp/cl-handoff-test.XXXX)
S=$T/s
export HOME=$T XDG_RUNTIME_DIR=$T CL_TMUX_SOCKET=$S PATH="$T/bin:$PATH"
cleanup() {
  [ -n "${WEB:-}" ] && kill "$WEB" 2>/dev/null
  [ -n "${CHROME:-}" ] && kill "$CHROME" 2>/dev/null
  tmux -S "$S" kill-server 2>/dev/null
  sleep 0.3
  \rm -rf "$T"
}
trap cleanup EXIT
failed=0
check() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failed=1; fi; }

mkdir -p "$T/.config/cl" "$T/bin" "$T/qa"
cat > "$T/.config/cl/config" <<EOF
web.listen = 127.0.0.1:$PORT
web.autostart = false
board.dispatch = false
EOF
printf 'handoff-pw\nhandoff-pw\n' | "$CL" web password >/dev/null || exit 1
printf '#!/bin/sh\nexec sleep 600\n' > "$T/bin/claude"
chmod +x "$T/bin/claude"
git -C "$T/qa" init -q && git -C "$T/qa" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
"$CL" project add qa "$T/qa" --prefix QA >/dev/null || exit 1
"$CL" ticket new qa "All three parts" >/dev/null && "$CL" ticket new qa "Verified only" >/dev/null || exit 1
tmux -S "$S" new-session -d -s keep sleep 600

# QA-1: all three parts. QA-2: Verified and only the step that starts it.
"$CL" ticket done QA-1 --summary "did it" --test-plan - <<'EOF'
# Verified
- `zig build test`: all **284** pass
- `cl ticket show QA-1`: Last reads "x"

# Test plan
## Start it
run: echo test-run; sleep 300
## On the phone
- [ ] It looks right

# Demo
## Start the demo
run: echo demo-run; sleep 300
## The new tab
open: http://127.0.0.1:1/board
Look at the top: the new part.
EOF
check $? "done takes a three-part handoff"
"$CL" ticket done QA-2 --summary "did it" --test-plan - <<'EOF'
# Verified
- ran it: fine
# Test plan
## Start it
run: echo two; sleep 300
EOF
check $? "done takes Verified with only a start step"
out=$("$CL" ticket done QA-2 --summary x --test-plan - 2>&1 <<'EOF'
# Demo
## Look
- [ ] a check in a demo
EOF
)
[ $? != 0 ] && echo "$out" | grep -q "a demo has no checks"; check $? "a demo with checks is refused: $out"

out=$("$CL" ticket done QA-2 --summary x --test-plan - 2>&1 <<'EOF'
# Verified
- tests pass
# Test plan
- [ ] a check outside any step
EOF
)
[ $? != 0 ] && echo "$out" | grep -q "before its first"; check $? "a check outside a ## step is refused: $out"
"$CL" ticket new qa "Demo only" >/dev/null
printf '# Demo\n## Look\nopen: http://127.0.0.1:1/\n' | "$CL" ticket done QA-3 --summary x --test-plan - >/dev/null
"$CL" ticket testplan QA-3 | grep -q "Step 1/1: Try it" && "$CL" ticket testplan QA-3 | grep -q "^Demo$"
check $? "a demo-only handoff still has a test plan (Try it) and prints its demo"
tp=$("$CL" ticket testplan QA-1)
echo "$tp" | sed 's/^/     | /'
echo "$tp" | grep -q "^Checked by Claude:" && echo "$tp" | grep -q "Step 2/2: On the phone" && echo "$tp" | grep -q "^Demo$" && echo "$tp" | grep -q "open: http://127.0.0.1:1/board"
check $? "testplan prints Verified, the steps and the demo"
"$CL" ticket testplan QA-2 | grep -q "Step 2/2: Try it" && "$CL" ticket testplan QA-2 | grep -q "\[ \] Works as expected"
check $? "a plan without checks gets Try it: Works as expected"
"$CL" ticket testplan QA-1 --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.exit(j.verified.includes("284") && j.steps.length===2 && j.demo.length===2 ? 0 : 1)'
check $? "testplan --json has verified, steps and demo"

"$CL" ticket launch QA-1 --demo --step 1
tmux -S "$S" ls -F '#{session_name}' | grep -qx clrun_qa-1_d1; check $? "launch --demo --step 1 runs in clrun_qa-1_d1"
"$CL" ticket launch QA-1 --step 1 >/dev/null
tmux -S "$S" ls -F '#{session_name}' | grep -qx clrun_qa-1_s1; check $? "the test step runs beside it in clrun_qa-1_s1"
"$CL" ticket launch QA-1 --demo --step 1 --stop
! tmux -S "$S" ls -F '#{session_name}' | grep -qx clrun_qa-1_d1 && tmux -S "$S" ls -F '#{session_name}' | grep -qx clrun_qa-1_s1
check $? "--demo --stop stops only the demo's"
"$CL" ticket launch QA-1 --demo --step 1 >/dev/null
"$CL" ticket launch QA-1 --stop
! tmux -S "$S" ls -F '#{session_name}' | grep -q '^clrun_'; check $? "--stop without a step stops the demo's too"

CL_PORT=$PORT "$CL" web >"$T/web.log" 2>&1 &
WEB=$!
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$T/chrome" --window-size=1200,1000 about:blank >"$T/chrome.log" 2>&1 &
CHROME=$!
for _ in $(seq 50); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP/json/version" && curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.2
done
node "$SRC/.claude/test-handoff.mjs" "$PORT" "$CDP" "$S" "${SHOTS:-}" || failed=1
[ $failed = 0 ] && echo "all passed" || { echo "some failed"; tail -20 "$T/web.log"; }
exit $failed
