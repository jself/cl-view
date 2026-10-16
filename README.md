# cl

Claude Code sessions in tmux, with a chooser. A small Zig binary that replaces
the parts of agent-deck I actually use.

- `cl` launches Claude in a new tmux session for the current directory and attaches.
- `Ctrl-Q` detaches and drops you into the chooser; `Enter` attaches again.
- `cl -p work` / `cl -p personal` pick the Claude config dir (profile).
- `cl list` shows every session with its status and a live preview of its pane.

tmux is the database: each session is a tmux session named `cl_<name>_<id>`
with its metadata in `@cl_*` options. Status comes from the registry files Claude
itself writes under `<config dir>/sessions/`, the same source `claude agents` uses,
so `busy` / `idle` / `blocked` match what Claude reports.

Linux only for now: checking whether a Claude process is still alive reads `/proc`.

## Install

Static binaries for x86_64 and aarch64 Linux are on the
[releases page](https://github.com/jself/cl-view/releases):

```
curl -L https://github.com/jself/cl-view/releases/latest/download/cl-x86_64-linux-musl.tar.gz | tar xz
install -m755 cl-x86_64-linux-musl/cl ~/.local/bin/cl
```

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
operator = work
work = ~/.claude-work
personal = ~/.claude
```

`default`, `operator` and dotted keys (`web.*`) are settings; every other key is a profile.
`-p <profile>` selects a profile, and `operator` picks the operator's
profile (falling back to `default`). If `CLAUDE_CONFIG_DIR` is set when
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
cl output <name> [lines]  status, latest reply, and pane tail (default 40 lines)
cl watch                  print a line whenever a session's status changes
cl closed                 closed sessions, most recently closed first
cl operator               attach to the operator session (o in the chooser)
cl alert <text> | --clear flag the chooser header from the operator
cl web                    serve the chooser to a browser (foreground)
cl web password           set the web password (stored as an argon2id hash)
cl web start | stop       run the web server in the background / stop it

launch options:
  -p, --profile <name>    profile from the config
  -n, --name <name>       session name (default: basename of dir)
  -m, --message <text>    send an initial prompt once claude shows its composer
  -r, --resume [id]       claude --resume
  -c, --continue          claude --continue
  -d, --detach            create the session and print its tmux name, don't attach
  -- <args...>            everything after -- goes to claude verbatim
```

The chooser looks like `claude agents`: a count line, then sessions grouped by
status (idle, idle with background tasks running, needs input, waiting,
starting, unknown, gone, working), one line each
with the start of Claude's latest reply and how long ago the status changed.
The selected session's pane is previewed below the list. `Tab` expands every
row with the directory, tmux session name, and Claude's own session name.

The latest reply comes from the transcript Claude writes under
`<config dir>/projects/<cwd>/<session id>.jsonl` (only the last 256 KB is read).

Chooser keys: `j`/`k` move, `Enter` attach, `Tab` toggle details, `n` new session
(asks for directory, name, profile, optional first message), `o` operator, `R` resume a closed session, `d` kill, `r` rename,
`s` send a line, `/` filter, `gg`/`G`, `Ctrl-R` refresh, `q` quit.

`R` lists sessions that are no longer running, most recently closed first, with
Claude's last reply; `Enter` brings one back with `claude --resume` in its old
directory, name, and profile. Every launch is recorded in
`~/.local/state/cl/history.jsonl`, and the chooser keeps each running session's
Claude session id up to date there (so `/clear` is followed). "Closed" is when
the transcript was last written.

## Operator

`o` in the chooser (or `cl operator`) attaches to the operator: a Claude session
that manages the others for you through the `cl` CLI. Ask it to start sessions,
say what everyone is doing, or keep an eye on things; it runs `cl watch` to hear
about status changes. It is not started until you first press `o`, then keeps
running like any other session. It is hidden from the list and from `cl list`,
`send` and `kill`; the header shows its status while it runs.

When something needs you, the operator runs `cl alert "<text>"` and the chooser
shows a ⚑ flag with that text in the top-right corner. Opening the operator
clears it (or `cl alert --clear`).

The operator keeps notes in `~/.config/cl/operator/notes/` (an `index.md` plus
a file per topic), reads them when it starts, and updates them as it goes, so
they survive restarting it. Tell it "note that ..." to add one.

It runs in `~/.config/cl/operator/` with the profile from the `operator`
setting. Its instructions come from the binary (`src/operator.zig`); put a
`CLAUDE.md` in that directory to add your own.

## Web

`cl web` serves the chooser to a browser, for using it from a phone. Each page
load runs its own `cl list` in a terminal (xterm.js, built into the binary), so
everything works as on the desktop. A key bar along the bottom has **← Back**
(sends `Ctrl-Q`, detaching from a session back to the list), Esc, Tab, arrows,
Enter, **Ctrl-J** (a newline in Claude's composer), and Ctrl-C.

```
web.autostart = true            # start it whenever cl launches, lists or attaches
web.listen = 127.0.0.1:8421, tailscale:8421   # one or more host:port
web.password = $argon2id$...    # written by `cl web password`
```

- `cl web password` asks for a password and writes its hash to the config. The
  server refuses to start without one.
- `web.listen` takes one or more comma-separated `host:port` addresses (default
  `127.0.0.1:8421`; `0.0.0.0:8421` for every interface). The host `tailscale`
  binds to this machine's tailnet IPv4, so the page is reachable from your
  other Tailscale devices (http://<machine>:8421) and not from the LAN. While
  Tailscale is down or logged out, that listener waits and retries every 30 s;
  the others serve meanwhile.
- With `web.autostart`, the server runs in a hidden tmux session and logs to
  `~/.local/state/cl/web.log`. After changing the password or upgrading cl,
  run `cl web stop` and it starts again with the next cl command.
- Signing in sets a 30-day cookie signed with a key derived from the password
  hash, so it survives restarts and a new password signs everyone out. Failed
  logins are limited to five a minute, and the terminal WebSocket only accepts
  same-origin connections.
- Attaching from the phone resizes that session to the phone's width
  (`window-size latest`); it switches back when you use it at the desk.

## Notes

- `Ctrl-Q` is bound in tmux (`bind-key -n C-q`) to detach only when the session
  name starts with `cl_`, so it does nothing inside other tmux sessions.
- Nested use works: running `cl` from inside another tmux session attaches a
  nested client.
- `-m` waits for Claude's composer prompt (a `❯` line under the composer border)
  so it never answers a trust or onboarding dialog by accident.

## Releasing

Push a `v*` tag (`git tag v0.1.0 && git push origin v0.1.0`). CI builds both
Linux targets, then publishes a GitHub release with the tarballs and `SHA256SUMS`.
