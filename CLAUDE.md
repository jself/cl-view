# cl-wrapper

## Build

The `zig` on PATH is too new for this build; use zvm's 0.16.0:

    ~/.local/share/zvm/0.16.0/zig build test --summary all
    ~/.local/share/zvm/0.16.0/zig build -Doptimize=ReleaseSafe

## After every change

The human runs the installed `~/.local/bin/cl`, and `cl web` serves the board and web terminals from it. Every time the code changes (a commit, a fix, a merge, or a switch to another branch), put the running servers on the new code without being asked:

1. Build and install: `~/.local/share/zvm/0.16.0/zig build -Doptimize=ReleaseSafe && install -m755 zig-out/bin/cl* ~/.local/bin/` (`cl`, and `cl-window` when webkitgtk-6.0 is installed)
2. Restart `cl web`: `kill $(pgrep -f 'bin/cl web$')`. A loop in the `cl_web_*` tmux session starts it again 10 seconds later. Web terminals drop for a moment and reconnect.
3. Restart any test launch that is running (`cl ticket launch <key> --stop`, then `cl ticket launch <key>`).

Tell the human to reload the board page.
