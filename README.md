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

Runs on Linux and macOS (Windows: use WSL). It needs tmux on PATH
(`brew install tmux` on macOS).

## Install

Binaries are on the [releases page](https://github.com/jself/cl-view/releases):
static `x86_64-linux-musl` / `aarch64-linux-musl` for Linux, and
`aarch64-macos` (Apple silicon) / `x86_64-macos` (Intel) for macOS.

```
t=x86_64-linux-musl   # or aarch64-linux-musl, aarch64-macos, x86_64-macos
curl -L https://github.com/jself/cl-view/releases/latest/download/cl-$t.tar.gz | tar xz
mkdir -p ~/.local/bin && install -m755 cl-$t/cl ~/.local/bin/cl
```

On macOS, a binary downloaded with curl runs as is. One downloaded with a
browser is quarantined; clear that with `xattr -d com.apple.quarantine ~/.local/bin/cl`.

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

`default`, `operator` and dotted keys (`web.*`, `board.*`) are settings; every other key is a profile.
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
cl hide | unhide <name>   hide a running session from the chooser, or show it again
cl send <name> <text>     type text + Enter into a session
cl output <name> [lines]  status, latest reply, and pane tail (default 40 lines)
cl watch                  print a line whenever a session's status changes
cl closed                 closed sessions, most recently closed first
cl operator               attach to the operator session (o in the chooser)
cl alert <text> | --clear flag the chooser header from the operator
cl web                    serve the chooser to a browser (foreground)
cl web password           set the web password (stored as an argon2id hash)
cl web start | stop       run the web server in the background / stop it
cl ticket | t <command>   the ticket board (see Board)
cl project <command>      projects that tickets belong to

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
(asks for directory, name, profile, optional first message), `o` operator, `R` resume a closed session, `h` hide / unhide, `H` show hidden, `d` kill, `r` rename,
`s` send a line, `/` filter (name, directory, profile), `gg`/`G`, `Ctrl-R` refresh, `Ctrl-L` redraw, `q` quit.

`h` hides the selected session without stopping it: Claude, its background
tasks, and any extra tmux windows keep running, and the header counts what is
hidden. `H` shows hidden sessions too (marked `hidden`), where `h` unhides one.
Hidden is a tmux option (`@cl_hidden`), so it lasts as long as the session.
The operator leaves hidden sessions alone: `cl watch` says nothing about them,
so they raise no alerts.

`R` lists sessions that are no longer running, most recently closed first, with
Claude's last reply; `Enter` brings one back with `claude --resume` in its old
directory, name, and profile. Every launch is recorded in
`~/.local/state/cl/history.jsonl`, and the chooser keeps each running session's
Claude session id up to date there (so `/clear` is followed). "Closed" is when
the transcript was last written. `/` filters the list by name, directory, or
profile.

Claude deletes old transcripts (`cleanupPeriodDays` in its `settings.json`, 30
days by default). Resuming one that is gone starts a new Claude session in the
same directory with the same name and profile; the list marks those, and drops
them once a newer session with the same name and directory exists. The same
applies to `cl -r <id>`.

## Operator

`o` in the chooser (or `cl operator`, or **Chat** on the web board) attaches to the operator: a Claude session
that manages the others for you through the `cl` CLI. Ask it to start sessions,
say what everyone is doing, or keep an eye on things; it runs `cl watch` to hear
about status changes. It is not started until you first press `o`, then keeps
running like any other session. It is hidden from the list and from `cl list`,
`send` and `kill`; the header shows its status while it runs.

When something needs you, the operator runs `cl alert "<text>"` and the chooser
shows a ⚑ flag with that text in the top-right corner. Opening the operator
clears it (or `cl alert --clear`).

It continues its last conversation when it starts again, so the chat carries
on across restarts (`/clear` in it starts a new one). For the board it has a
`cl-tickets` skill (written to `~/.config/cl/operator/.claude/skills/` each
time it is opened): ask it for a ticket and it picks the project, writes the
ticket's first message, and creates it.

The operator keeps notes in `~/.config/cl/operator/notes/` (an `index.md` plus
a file per topic), reads them when it starts, and updates them as it goes, so
they survive restarting it. Tell it "note that ..." to add one.

It runs in `~/.config/cl/operator/` with the profile from the `operator`
setting. Its instructions come from the binary (`src/operator.zig`); put a
`CLAUDE.md` in that directory to add your own.

## Web

`cl web` serves the chooser to a browser, for using it from a phone. Each page
load runs its own `cl list` in a terminal (xterm.js, built into the binary), so
everything works as on the desktop. A key bar along the bottom has **⇦**
(back: sends `Ctrl-Q`, detaching from a session back to the list), Esc, Tab,
arrows, Enter, **C-j** (a newline in Claude's composer), C-c, and **C-l**
(refit the terminal to the screen, after a rotation say, fit the session's
window to it, and redraw).

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
  the others serve meanwhile. The address comes from `tailscale ip -4` (on
  macOS, the CLI inside `/Applications/Tailscale.app` is used if `tailscale`
  is not on PATH).
- With `web.autostart`, the server runs in a hidden tmux session and logs to
  `~/.local/state/cl/web.log`. After changing the password or upgrading cl,
  run `cl web stop` and it starts again with the next cl command.
- Signing in sets a 30-day cookie signed with a key derived from the password
  hash, so it survives restarts and a new password signs everyone out. Failed
  logins are limited to five a minute, and the terminal WebSocket only accepts
  same-origin connections.
- Attaching from the phone resizes that session to the phone's width
  (`window-size latest`); it switches back when you use it at the desk.

## Board

A ticket board on top of the sessions, stored in SQLite at
`<board.dir>/board.db` (default `~/.local/state/cl`). Use it in the browser
at `/board` on `cl web` (the terminal page links to it), or with `cl ticket`;
both do the same things. The design notes are in `docs/board-plan.md`.

```
board.dir = ~/.local/state/cl
board.worktrees = ~/.local/share/cl/worktrees
board.dispatch = true            # cl web starts queued tickets
board.trust_worktrees = true     # say yes to Claude's folder-trust dialog in new worktrees
```

Every ticket belongs to a project, which gives it a key prefix:

```
cl project add qa-tool ~/devel/qa-tool --slots 2 --mode worktree   # QA-1, QA-2, ...
cl project add boats ~/devel/boats --prefix BOAT
cl project list | set <name> [options] | rm <name>
```

Every project gets jj: adding one, or starting its first ticket, runs
`jj git init --colocate` when the directory has no jj repo yet. Git keeps
working, and worktree tickets get `jj workspace`s. A directory inside a bigger
git repo is left alone, and so is everything when jj isn't installed.

With jj, every ticket gets a change of its own on top of trunk (the default
branch), described `QA-1: <title>`, with a bookmark of its key and title on
it so git sees a branch; `cl t show` lists both. Its work goes into that change
by itself (jj snapshots the files), so nothing is committed by hand, and the
review in gutter shows that change. cl's own files in `.claude/` (review guide,
review, test plan) are kept out through `.git/info/exclude`; everything
gitignored, like `node_modules`, stays out as usual.

Stages are the workflow: backlog, planning (optional), queued, running,
review, testing, done. Flags say what needs you and are separate from the
stage: `input` (a permission prompt), `question`, `review`, `testing`, or any
word you like. While a ticket's session is busy working on it, it stays out of
the inbox whatever its flags say; it comes back once the session stops.

```
cl t new qa-tool "Flaky login spec" -m "fails one run in five" [--worktree | --queue] [--plan]
cl t list [--stage review] [--project qa-tool] [--flag question] [--search login] [--open] [--json]
cl t needs                       the inbox: flagged tickets Claude isn't working on, oldest first
cl t show QA-1 [--json]          details, flags, comments and activity
cl t edit QA-1 --title ... | move QA-1 testing | rm QA-1
cl t comment QA-1 "also cover logout" --send
cl t flag QA-1 needs-design "which layout?" | unflag QA-1 needs-design
cl t done QA-1 --summary "Fixed the race"
```

- `done` is how Claude says a ticket is finished and needs nothing more: it
  moves to review with the `review` flag, and the summary becomes a comment.
- `comment --send` also types the comment into the ticket's session. On a
  ticket in review or testing it means "not done yet": the ticket goes back
  to running and its round goes up. Without `--send` a comment is a note.
- Entering testing sets `testing`; leaving review or testing clears its flag;
  done clears every flag.
- Inside a ticket's session (`CL_TICKET` set) the key can be left out:
  `cl t done --summary ...`, `cl t comment "..."` (as claude).
- `--plan` starts a ticket in planning: Claude runs in plan mode, interviews
  you (`--skill grilling` or `--skill wayfinder` names a skill for it), posts
  the plan and runs `done`, which means "plan ready" there. `cl t approve`
  moves it to running and tells Claude to build it; on a ticket in review or
  testing, approve moves it on a stage.

### Running tickets

A ticket runs one of two ways (`--queue` is the default, a project can set
`--mode worktree`):

- **queue**: typed into a session when that session is idle and has no other
  ticket in progress (planning, running, review or testing; it is free once
  that ticket is done): `--target <tmux name>`, else the parent's session for
  a sub-ticket, else the session of the project's ticket in progress, else a
  new session in the project's directory. The project's checkout is shared,
  so when a session takes a ticket up on its own (idle, not a sub-ticket going
  on in its parent's conversation) the checkout switches to that ticket's
  change (`jj edit`), and each ticket's files come back with its resumed
  conversation. Claude is told first thing when the files changed, so it
  restarts what runs from the checkout. A sub-ticket in its parent's
  conversation works in the parent's change.
- **worktree**: its own worktree at `<board.worktrees>/<project>/<key-title>`
  (a `git worktree` with a branch of that name, or a `jj workspace`) and its
  own session, up to the project's `--slots` in progress at once.

```
cl t move QA-1 queued      the dispatcher starts it when it can
cl t start QA-1 [--now]    start it now (--now: type into a busy queue session anyway)
cl t dispatch [--once]     the dispatcher; `cl web` runs it too
cl t cleanup QA-1 --branch remove the worktree and its merged branch
```

The first message tells Claude the ticket (with any notes you added before
it started) and how to finish: write a review guide for gutter
(`.claude/review-guide.md`), a test plan if there is something to try
(`.claude/test-plan.md`: Setup, Launch, Checks), then `cl ticket done
<key> --summary ...`. An idle session that never said done stays in running.

Sessions cl starts for tickets get `CL_TICKET` and hooks (`--settings
<board.dir>/claude-hooks.json`): a permission prompt sets `input`, and the
end of a turn clears it. A ticket whose session goes away gets `ended`;
`cl t start` starts it again.

### What needs you

cl watches each ticket's session (every few seconds, in `cl web` or `cl t
dispatch`). When Claude waits, it reads what for from local files: the
session registry says it is waiting, the transcript holds the pending
AskUserQuestion (its questions and options) or the command a permission
prompt is about, and the pane shows the menu's numbered options. That
becomes the ticket's `question` or `input` flag, with the details, and clears
when the session moves on.

```
cl t answer QA-1 2                 pick option 2 (a question, or a permission prompt)
cl t answer QA-1 "Green please"    your own words ("Type something")
cl t answer QA-1 1 "Large"         two questions: one answer each, then Submit
cl t key QA-1 esc | interrupt      press a key in the session
```

Answers are keypresses in the session, the same as typing them yourself.

### Review and testing

```
cl t gutter QA-1 [--stop]          gutter on the ticket's changes, with Claude's review guide
cl t send-review QA-1              send the review you submitted in gutter back to Claude
cl t testplan QA-1                 Claude's test plan: setup steps, launch command, checks
cl t launch QA-1 [--stop]          run the launch command (tmux session clrun_qa-1)
cl t test QA-1                     walk through the plan here; failures go back to Claude
cl t approve QA-1                  review -> testing -> done
```

gutter diffs against the revision the ticket started from. It only listens on
127.0.0.1, so when the board opens it, `cl web` also opens the same port on
its other `web.listen` addresses (tailscale) and forwards it, while that
ticket's gutter runs. Test results that all pass move the ticket to done; a
failure sends them to Claude for another round.

### Finishing

Done closes the ticket's session. For a ticket with a branch of its own
(a jj change, or a git worktree's branch) you choose what happens to the branch first: the board asks
when a card is dropped on Done (or Done is picked, or it is approved out of
testing), and the CLI takes a flag:

```
cl t move QA-1 done --merge        merge it into the main branch (see below)
cl t move QA-1 done --pr           Claude pushes it and opens a PR
cl t move QA-1 done [--close]      just close (the default; also approve and test)
```

With `--merge` or `--pr` the instruction is typed into the ticket's session
and the ticket stays where it is with a Finishing pill; questions and
conflicts come back through the board as usual. When Claude is through it
runs `cl t done QA-1 --close [--pr-url <url>]`: the ticket moves to done, the
PR link becomes a comment, and then the session closes.

A jj change is merged by cl itself: it rebases the change onto trunk and,
with no conflicts, moves trunk to it and drops the bookmark (a change with no
edits is dropped instead). A checkout left on the merged change gets a new one
on top, and one with nothing of its own moves up to trunk. When the checkout's
files changed and the session is still there, Claude is asked to restart what
runs from it before Done. Conflicts are recorded by jj in the change and put on
the ticket as a `conflict` flag listing the files; trunk stays put, and Claude
is asked to settle them in the change and run `cl t done QA-1 --close`, which
merges it then (and refuses while any are left). Git branches are merged by
Claude as before.

### The web board

`/board` shows Board, Lanes (a row per project) and List views, with "Needs
you" across the top: every ask, with quick answers. Filters pick what needs
you, a project, and whether sub-tickets show. A ticket opens in a popup:
answer its questions, comment or send it back, watch its session or open it
in the terminal (`/?attach=<session>`), open gutter, launch and test, see
its sub-tickets and activity, and edit it. On a phone the columns swipe and
the popup fills the screen.

- Sub-tickets are tickets with a parent: their own key, stage, flags and
  comments. `cl t new --parent QA-1 "title"`, or from the ticket's own
  session `cl t sub "title"`. `list --top` leaves them out, `list --parent
  QA-1` lists them, and `show` includes them. A ticket with sub-tickets can't
  be removed until they are.

## Notes

- `Ctrl-Q` is bound in tmux (`bind-key -n C-q`) to detach only when the session
  name starts with `cl_`, so it does nothing inside other tmux sessions.
- `Ctrl-L` redraws when the screen looks off. In the chooser it re-reads the
  terminal size and repaints. Inside a `cl_` session it fits the window back
  to your terminal (say, after the web page on a phone shrank it), puts
  `window-size latest` back, repaints, and passes `Ctrl-L` on to Claude.
  Elsewhere it is passed through untouched.
- `←` at the start of Claude's prompt is dropped in `cl_` sessions. There it
  would open Claude's agents view, which can't be turned off and parks the
  conversation as a background job. `←` still moves through text you've typed,
  works in menus, and is untouched in other panes, windows and tmux sessions.
  If a session does end up in the agents view, `cl` shows the parked
  conversation's real status, and Enter there returns to it.
- Nested use works: running `cl` from inside another tmux session attaches a
  nested client.
- `-m` waits for Claude's composer prompt (a `❯` line under the composer border)
  so it never answers a trust or onboarding dialog by accident.

## Releasing

Push a `v*` tag (`git tag v0.1.0 && git push origin v0.1.0`). CI builds the
Linux and macOS targets (and runs the tests on a macOS runner), then publishes a GitHub release with the tarballs and `SHA256SUMS`.
