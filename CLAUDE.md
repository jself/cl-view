# cl-wrapper

## Build

The `zig` on PATH is too new for this build; use zvm's 0.16.0:

    ~/.local/share/zvm/0.16.0/zig build test --summary all
    ~/.local/share/zvm/0.16.0/zig build -Doptimize=ReleaseSafe

## After master changes

The human runs the installed `~/.local/bin/cl`, and `cl web` serves the board and web terminals from it. Only master goes there. When master changes (a ticket merged, a fix committed to it), put the running servers on the new code without being asked:

1. Build master and install it: `~/.local/share/zvm/0.16.0/zig build -Doptimize=ReleaseSafe && install -m755 zig-out/bin/cl* ~/.local/bin/` (`cl`, and `cl-window` when webkitgtk-6.0 is installed). Build from a checkout whose working copy is master with nothing else in it (`jj log -r @-` shows `master` and `jj diff` is empty).
2. Restart `cl web`: `pkill -f "^$HOME/.local/bin/cl web$"`. A loop in the `cl_web_*` tmux session starts it again 10 seconds later. Web terminals drop for a moment and reconnect. Match the full path: a looser pattern like `bin/cl web$` also kills test servers running from `zig-out/bin/cl`.
3. Restart any test launch that is running (`cl ticket launch <key> --stop`, then `cl ticket launch <key>`).

Tell the human to reload the board page.

A ticket's branch never goes into `~/.local/bin`, even when cl switches the project's checkout to it and says to rebuild what runs from there. That would replace the human's merged build with unmerged code (and drop whatever merged since the branch was cut). Build it into `zig-out` (`~/.local/share/zvm/0.16.0/zig build`) and run it as a test server, below. Use `zig-out/bin/cl` for the branch's own CLI checks too.

## Test plans

To let the human try a change to the web server or board, launch the branch's
build as a second server next to the installed one, on its own port and the
same config and board (it leaves the dispatcher to the main server):

    ~/.local/share/zvm/0.16.0/zig build && CL_PORT=8422 zig-out/bin/cl web

and give http://127.0.0.1:8422/board (or http://<machine>:8422/board over
tailscale) as what to open. Use any free port other than web.listen's.
