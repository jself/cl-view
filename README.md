# cl

Claude Code sessions in tmux, with a chooser. A small Zig binary that replaces
the parts of agent-deck I actually use.

- `cl` launches Claude in a new tmux session for the current directory and attaches.
- `Ctrl-Q` detaches and drops you into the chooser; `Enter` attaches again.
- `cl --work` / `cl --personal` pick the Claude config dir (profile).
- `cl list` shows every session with its status and a live preview of its pane.

tmux is the database: each session is a tmux session named `cl_<name>_<id>`
with its metadata in `@cl_*` options. Status comes from the registry files Claude
itself writes under `<config dir>/sessions/`, the same source `claude agents` uses,
so `busy` / `idle` / `blocked` match what Claude reports.

## Build

Requires Zig 0.16.0 (the pinned libvaxis commit targets exactly that version).

```
zig build -Doptimize=ReleaseSafe
install -m755 zig-out/bin/cl ~/.local/bin/cl
```

With zvm: `~/.local/share/zvm/0.16.0/zig build -Doptimize=ReleaseSafe`.

## Config

`~/.config/cl/config`, one profile per line. Values are Claude config dirs
(what `CLAUDE_CONFIG_DIR` is set to inside the session).

```
default = work
work = ~/.claude-work
personal = ~/.claude
```

Any `--<profile>` flag selects that profile. If `CLAUDE_CONFIG_DIR` is set when
`cl` runs, it overrides `default`: the profile with that directory is used, or
one named after the directory (`~/.claude-work` becomes `claude-work`) is added
for this run. Without a config file there is a single `default` profile that
leaves `CLAUDE_CONFIG_DIR` untouched.

## Usage

```
cl [options] [dir]        launch claude in dir (default: cwd) and attach
cl list | ls              interactive chooser (--plain / --json for scripts)
cl attach <name>          attach to a session (Ctrl-Q detaches)
cl kill <name>            kill a session
cl send <name> <text>     type text + Enter into a session

launch options:
  --<profile>             e.g. --work, --personal
  -n, --name <name>       session name (default: basename of dir)
  -m, --message <text>    send an initial prompt once claude shows its composer
  -r, --resume [id]       claude --resume
  -c, --continue          claude --continue
  -d, --detach            create the session and print its tmux name, don't attach
  -- <args...>            everything after -- goes to claude verbatim
```

The chooser looks like `claude agents`: a count line, then sessions grouped by
status (needs input, working, idle, starting, unknown, gone), one line each
with the start of Claude's latest reply and how long ago the status changed.
The selected session's pane is previewed below the list. `Tab` expands every
row with the directory, tmux session name, and Claude's own session name.

The latest reply comes from the transcript Claude writes under
`<config dir>/projects/<cwd>/<session id>.jsonl` (only the last 64 KB is read).

Chooser keys: `j`/`k` move, `Enter` attach, `Tab` toggle details, `n` new session
(asks for directory, name, profile, optional first message), `d` kill, `r` rename,
`s` send a line, `/` filter, `gg`/`G`, `R` refresh, `q` quit.

## Notes

- `Ctrl-Q` is bound in tmux (`bind-key -n C-q`) to detach only when the session
  name starts with `cl_`, so it does nothing inside other tmux sessions.
- Nested use works: running `cl` from inside another tmux session attaches a
  nested client.
- `-m` waits for Claude's composer prompt (a `❯` line under the composer border)
  so it never answers a trust or onboarding dialog by accident.
