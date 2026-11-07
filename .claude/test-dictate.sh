#!/bin/sh
# `cl dictate` end to end on a sandbox tmux server, with stand-ins for
# pw-record, voice.stt and claude: the binding (Alt+` pressed on a real
# attached client), the paste, the status-right marker, the debounce,
# --cancel, a reused PID, and a recorder that won't stop.
# Run from the checkout after `zig build`. Every tmux call names the
# sandbox's socket (-S); nothing touches the real server.
set -u
cd "$(dirname "$0")/.."
CL="$PWD/zig-out/bin/cl"
T=$(mktemp -d /tmp/cl-dictate-test.XXXX)
S=$T/s
export HOME=$T XDG_RUNTIME_DIR=$T CL_TMUX_SOCKET=$S PATH="$T/bin:$PATH"
t() { tmux -S "$S" "$@"; }
cleanup() { t kill-server 2>/dev/null; pkill -KILL -f "$T/bin/|tmux -S $S attach" 2>/dev/null; \rm -rf "$T"; }
trap cleanup EXIT

mkdir -p "$T/bin" "$T/.config/cl" "$T/proj"
# pw-record: writes its file, then waits; SIGINT ends it (unless STUBBORN).
cat > "$T/bin/pw-record" <<'EOF'
#!/bin/sh
for f; do :; done
printf 'RIFF' > "$f"
if [ -e "$HOME/stubborn" ]; then trap '' INT; else trap 'exit 0' INT; fi
while :; do sleep 0.1; done
EOF
printf '#!/bin/sh\necho "hello from the test"\n' > "$T/bin/stt"
printf '#!/bin/sh\nexec cat -v\n' > "$T/bin/claude"
chmod +x "$T/bin/"*
echo "voice.stt = $T/bin/stt" > "$T/.config/cl/config"

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
recorders() { pgrep -f "$T/bin/pw-record" | wc -l; }
rec() { t show-options -gqv @cl_dictate; }
pane() { t capture-pane -p -t "$SESS"; }
wavs() { ls "$T"/cl-dictate-*.wav 2>/dev/null | wc -l; }

# A session launched by this build, so cl sets its own bindings.
"$CL" -d -n dict "$T/proj" >/dev/null 2>&1
SESS=$(t list-sessions -F '#{session_name}' | grep '^cl_' | head -1)
check "a session launched" '[ -n "$SESS" ]'
check "Alt+\` is bound" 't list-keys -T root | grep -q "M-\`.*dictate"'
# A real client on it, to press keys on. script gives it a terminal; its
# stdin stays open (an EOF would end the client), and TMUX is unset, since
# tmux won't attach from inside another tmux.
(sleep 600 | env -u TMUX script -qfc "tmux -S $S attach -t $SESS" /dev/null >/dev/null 2>&1 &)
sleep 1
CLIENT=$(t list-clients -F '#{client_name}' | head -1)
check "a client attached" '[ -n "$CLIENT" ]'

echo "-- Alt+\` starts"
t send-keys -K -c "$CLIENT" 'M-`'; sleep 0.8
check "one recorder" '[ "$(recorders)" = 1 ]'
check "@cl_dictate names the session" 'rec | grep -q "	$SESS$"'
check "status-right shows the marker" 't show-options -t "$SESS" -v status-right | grep -q dictating'

echo "-- held key (autorepeat): no more recorders, not stopped"
for i in 1 2 3 4 5 6; do t send-keys -K -c "$CLIENT" 'M-`'; sleep 0.05; done; sleep 0.8
check "still one recorder" '[ "$(recorders)" = 1 ]'
check "still recording" '[ -n "$(rec)" ]'

echo "-- Alt+\` again stops and types it in"
sleep 1.1; t send-keys -K -c "$CLIENT" 'M-`'; sleep 1.5
check "the words are in the pane" 'pane | grep -q "hello from the test"'
check "no recorder" '[ "$(recorders)" = 0 ]'
check "@cl_dictate cleared" '[ -z "$(rec)" ]'
check "marker gone" '! t show-options -t "$SESS" -qv status-right | grep -q dictating'
check "WAV deleted" '[ "$(wavs)" = 0 ]'

echo "-- --cancel"
sleep 1.1; "$CL" dictate "$SESS"; sleep 0.3
"$CL" dictate --cancel
check "no recorder" '[ "$(recorders)" = 0 ]'
check "@cl_dictate cleared" '[ -z "$(rec)" ]'
check "marker gone" '! t show-options -t "$SESS" -qv status-right | grep -q dictating'
check "WAV deleted" '[ "$(wavs)" = 0 ]'
check "typed in once only" '[ "$(pane | grep -c "hello from the test")" = 1 ]'

echo "-- a reused PID is left alone"
sleep 300 & V=$!
sleep 1.1; t set-option -g @cl_dictate "$(printf '%d\t1\t%s/gone.wav\t%s' "$V" "$T" "$SESS")"
"$CL" dictate "$SESS"
check "the other process lives" 'kill -0 $V'
check "a new recording started" 'rec | grep -q "^[0-9]*	[0-9]*	$T/cl-dictate"'
sleep 1.1; "$CL" dictate --cancel # the real one it started
t set-option -g @cl_dictate "$(printf '%d\t1\t%s/gone.wav\t%s' "$V" "$T" "$SESS")"
"$CL" dictate --cancel
check "--cancel leaves it too" 'kill -0 $V'
kill "$V"

echo "-- a recorder that won't stop is killed"
touch "$T/stubborn"; sleep 1.1; "$CL" dictate "$SESS"; sleep 0.3
sleep 1.1; "$CL" dictate "$SESS" 2>/dev/null; sleep 0.3
check "no recorder" '[ "$(recorders)" = 0 ]'
check "WAV deleted" '[ "$(wavs)" = 0 ]'
check "@cl_dictate cleared" '[ -z "$(rec)" ]'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
