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

Or with make, which does the same (zvm's 0.16.0 when it's installed, else
the `zig` on PATH; `make ZIG=...` picks another):

```
make            # cl, plus cl-window when it can be built (see Window)
make install    # both into ~/.local/bin (PREFIX=... for elsewhere)
make cl         # cl only
make window     # cl and cl-window, failing if cl-window can't be built
make test
make clean
```

`make` builds `cl` first, so a machine without `webkitgtk-6.0` (or where
cl-window fails to compile) still gets `cl`, with a warning; `make install`
then installs `cl` alone.

## Config

`~/.config/cl/config`, one profile per line. Values are Claude config dirs
(what `CLAUDE_CONFIG_DIR` is set to inside the session).

```
default = work
operator = work
work = ~/.claude-work
personal = ~/.claude
```

`default`, `operator` and dotted keys (`web.*`, `board.*`, `gutter.*`, `tmux.*`) are settings; every other key is a profile.
`-p <profile>` selects a profile, and `operator` picks the operator's
profile (falling back to `default`). If `CLAUDE_CONFIG_DIR` is set when
`cl` runs, it overrides `default`: the profile with that directory is used, or
one named after the directory (`~/.claude-work` becomes `claude-work`) is added
for this run. Without a config file there is a single `default` profile that
leaves `CLAUDE_CONFIG_DIR` untouched.

### tmux server

cl uses tmux's default server unless it is given a socket, as an absolute path:

```
tmux.socket = /run/user/1000/cl-try/tmux
```

or `CL_TMUX_SOCKET=/run/user/1000/cl-try/tmux`, which wins over the config.
Then every tmux call cl makes, `cl web`'s and the dispatcher's included, is
`tmux -S <socket>`, and the sessions cl starts get `CL_TMUX_SOCKET` too, so a
`cl` run inside one stays on that server.

A sandbox (a `cl` whose `HOME` isn't your home directory from the passwd
database) without a socket runs no tmux at all: `cl web`, `cl ticket
dispatch` and the session commands refuse to start and say why, and the
board commands that need tmux fail. Its default server is most likely your
real one (a `TMUX_TMPDIR` that doesn't exist yet makes tmux fall back to
`/tmp`), and a sandbox that reached it has killed every session at once. To
mean the real server from a sandbox, name its socket (`tmux display -p
'#{socket_path}'`).

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
cl alert <text> | --clear alert you from this session (Needs you and the chooser)
cl web                    serve the chooser to a browser (foreground)
cl web password           set the web password (stored as an argon2id hash)
cl web start | stop       run the web server in the background / stop it
cl web install | uninstall  start it on boot, as a systemd user service (Linux)
cl web --port N ...       the same on port N, as a second server (or CL_PORT=N)
cl board                  the ticket board in the terminal (b in the chooser)
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

Chooser keys: `j`/`k` move, `Enter` attach, `b` the ticket board (see The terminal board), `Tab` toggle details, `n` new session
(asks for directory, name, profile, optional first message), `o` operator, `R` resume a closed session, `P` parked tickets (Enter resumes one, `x` ends the park), `h` hide / unhide, `H` show hidden, `d` kill, `r` rename,
`s` send a line, `/` filter (name, directory, profile), `gg`/`G`, `Ctrl-R` refresh, `Ctrl-L` redraw, `q` quit.
The bottom line shows the keys that fit the terminal's width; `?` lists them all
(in the board too).

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
about status changes, and `cl ticket watch` to hear when a ticket needs feedback
(see What needs you). It is not started until you first press `o`, then keeps
running like any other session. It is hidden from the list and from `cl list`,
`send` and `kill`; the header shows its status while it runs.

When something needs you, the operator runs `cl alert "<text>"`: the chooser
shows a ⚑ flag with that text in the top-right corner, and the web board's
Needs you an Alert card with the text, who raised it and when (see Alerts).
Opening the operator clears it (or `cl alert --clear`).

#### Alerts

Any cl session can raise one, not only the operator: `cl alert "<text>"` run
inside a session belongs to that session (and to its ticket, `$CL_TICKET`, if
it has one); run anywhere else it is the operator's. Each session holds one at
most, so a new one from the same session replaces the last, while alerts from
different sessions show separately. They live on the session in tmux, like
everything else about it, so they survive a `cl web` restart and go when the
session does.

Where they show: the chooser (the operator's at the top right, any other
session's on its row), the web board's Needs you (an Alert card with Open,
which opens the session's terminal or the operator's chat, and Dismiss), and
`cl ticket needs` (an `alert` line each; `--json` puts them under `alerts`).
Opening the session anywhere (the chooser, `cl attach`, the web terminal, or
Open) or dismissing it clears it everywhere, as does `cl alert --clear` from
that session. A hidden session's alerts never show, nor do those about a hidden
project's ticket. The board's tab title counts what needs you, so it shows from
another tab.

It continues its last conversation when it starts again, so the chat carries
on across restarts (`/clear` in it starts a new one). For the board it has a
`cl-tickets` skill (written to `~/.config/cl/operator/.claude/skills/` each
time it is opened): ask it for a ticket and it picks the project, writes the
ticket's first message, and creates it. Its conversation goes on across
upgrades, so it may still hold an older version of the skill: when a new cl
rewrites it, the next message cl sends the operator (a Quick Ticket, a job
for it) starts by telling it to load the skill again.

The operator keeps notes in `~/.config/cl/operator/notes/` (an `index.md` plus
a file per topic), reads them when it starts, and updates them as it goes, so
they survive restarting it. Tell it "note that ..." to add one.

It runs in `~/.config/cl/operator/` with the profile from the `operator`
setting. Its instructions come from the binary (`src/operator.zig`); put a
`CLAUDE.md` in that directory to add your own. They name the full path of the
`cl` that started it, so it doesn't depend on `cl` being on the PATH its Bash
tool gets from your shell.

That folder and the session name `operator` are the operator's: `cl` refuses to
start any other session there or by that name (`cl operator` opens the real
one). A copy would lack the operator's tag and instructions, and other Claude
sessions, finding it by name, would message it instead. For the same reason a
bare `cl` with no terminal (an agent reading the help, say) prints the help
rather than starting a session in the current folder, and `cl <dir>` without
`-d` refuses when there is no terminal to attach to.

`review.model` does the same for the automated review (Review and testing).

`operator.model = sonnet` (any `claude --model` value) runs the operator on
another model than the profile's default: faster answers, voice ones
included. It takes effect the next time the operator starts (`/exit` in Chat).

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
web.font_size = 16              # text size of the board and terminal pages, in px (default 16)
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
- `cl web install` runs it as a systemd user service instead, so it starts
  on boot (below).
- Signing in sets a 30-day cookie signed with a key derived from the password
  hash, so it survives restarts and a new password signs everyone out. Failed
  logins are limited to five a minute, and the terminal WebSocket only accepts
  same-origin connections.
- `web.font_size` scales the whole board (cards, columns, dialogs, the ticket
  view) and sets the terminal page's font; 14 is the size before it existed.
  On the board, Ctrl+= / Ctrl+- / Ctrl+0 make it bigger, smaller, or back to
  `web.font_size`, like browser zoom; each browser (and `cl window`)
  remembers its own.
- On the board, O (outside a text box, with no dialog open) opens the
  operator chat, like the Chat button.
- The board works from the keyboard (? lists the keys). S labels everything
  on screen that can be clicked (buttons, cards, tabs, boxes; in a dialog,
  the dialog's), and typing a label clicks it. Ctrl+K finds a ticket by key
  or title, or a command; Tab on a ticket lists what you can do with it
  (open a tab, start, approve, move, park, kill...). / searches, h/j/k/l
  and the arrows move between cards (g/G: top and bottom of the column) and
  Enter opens one, Q makes a quick ticket and N a new one. Single keys don't
  fire in a text box: Esc leaves the box, keeping what you typed, and the
  next Esc closes its dialog. Of these keys, only S, Ctrl+K and ? work
  with a dialog open; the dialogs have keys of their own (below).
- In the New ticket dialog, Ctrl+Enter (Cmd+Enter on a Mac) creates the
  ticket from any field, the description box included.
- In a ticket's test plan walk-through (its Test tab), P and F pass or fail
  the first check of the step that isn't answered yet, N goes to the next
  step, and C puts the cursor in the step's comment box (the note box on the
  results page). They don't fire while you type in a box; Esc leaves it
  without closing the ticket.
- Attaching from the phone resizes that session to the phone's width
  (`window-size latest`); it switches back when you use it at the desk.
- `CL_PORT=8422` (or `cl web --port 8422`) replaces the port of every
  `web.listen` entry, so `CL_PORT=8422 zig-out/bin/cl web` serves a branch's
  build on 127.0.0.1:8422 and tailscale:8422 next to the installed one, with
  the same config and board. That server is a second one: it doesn't run the
  board's dispatcher (the main server keeps starting queued tickets), cl
  commands run with `CL_PORT` set don't autostart anything, and `cl web start`
  / `cl web stop` with it start and stop only that port's background server
  (logging to `web-8422.log`), never the main one. `cl window` with `CL_PORT`
  opens and starts that port's server. Such a server takes its port over:
  it first stops any other `cl web` started with the same port (another
  ticket's test server still running, or `cl web start`'s), so the newest
  build is the one that answers. The main server is never stopped this way.

### Start on boot

The hidden tmux session only starts when some cl command runs, so after a
reboot the phone app, its notifications and the board's dispatcher wait for
you to open a terminal. On Linux, `cl web install` makes the main server a
systemd user service instead:

- It writes `~/.config/systemd/user/cl-web.service`, which runs this cl's
  `web` (normally `~/.local/bin/cl web`) and logs to the same `web.log`;
  stops the server running in tmux; and enables and starts the service
  (`systemctl --user enable`, then `restart`, so running it again picks up a
  new unit). `systemctl --user status cl-web` shows how it is doing.
- Like the tmux loop, systemd starts it again 10 s after it exits, however it
  exits (`Restart=always`), so killing it is a restart: the after-merge
  command's `pkill -f "^$HOME/.local/bin/cl web$"` still works.
- The unit's PATH is `~/.local/bin`, the directory cl runs from, then the PATH
  of the shell that ran `cl web install` (and `/usr/local/bin:/usr/bin:/bin`).
  systemd's own PATH has no `~/.local/bin`, and the tmux server the service
  may start at boot (and every session in it) inherits the unit's PATH. Run
  it again from a shell whose PATH is right if that changes. `LANG`,
  `LC_ALL`, `EDITOR`, `VISUAL`, `TMUX_TMPDIR`, `CL_TMUX_SOCKET`,
  `XDG_STATE_HOME` and `XDG_DATA_HOME` are copied in too when set.
- That is all the environment a tmux server started by the service gets, and
  so every session on it: not the rest of your login shell's (tokens your
  `.zshrc` exports, `SSH_AUTH_SOCK` for `git push` over ssh, `DISPLAY`). A
  tmux server started from your shell keeps the full one; after a reboot the
  service is what starts it. Put what sessions need in `~/.config/cl/web.env`
  (`NAME=value` lines, read when the service starts; `systemctl --user
  restart cl-web` after changing it), or set it in tmux with `tmux
  set-environment -g NAME value` for sessions started after.
- A user's systemd only starts at boot, before anyone logs in, with
  *lingering* on. Without it, `cl web install` runs `loginctl enable-linger`,
  which lets your user services (all of them, not only this one) start at
  boot and keep running after you log out; when that isn't allowed it says
  to run `sudo loginctl enable-linger <you>`, and meanwhile the service
  starts at login. `loginctl disable-linger` turns it off.
- While it's installed, `cl web start` / `stop` and web.autostart start and
  stop the service (`systemctl --user start | stop cl-web`) and never a tmux
  one. A `CL_PORT` second server is unaffected.
- tmux gives every pane a systemd scope that is *part of* the unit its server
  started in, so a tmux server started by the service would lose every
  session whenever the service stops or restarts. So at startup, if no tmux
  server runs, the service starts one in a scope of its own
  (`systemd-run --user --scope`, unit `cl-tmux-<pid>`), with `exit-empty`
  off so it stays up between sessions, and checks again before each session
  it starts (should that server have gone); `KillMode=process` leaves anything else
  it started alone.
- `cl web uninstall` stops, disables and removes the unit (lingering stays as
  it is), then starts the server in tmux again if web.autostart is on. If
  systemctl can't stop it, the unit stays and nothing else starts.
- If any systemctl step of `cl web install` fails, it disables and removes
  the unit again and restarts the tmux server it stopped.

macOS has no systemd: `cl web install` refuses there, and web.autostart or
`cl web start` (tmux) remain the way to run it.

### On a phone

The board installs as an app (a PWA: its own home-screen icon, opening
full-screen on the board without the browser's address bar). Phones only
install it from an HTTPS page, so put `tailscale serve` in front of `cl web`
(HTTPS on your tailnet only, with a real certificate for the machine's
`ts.net` name; HTTPS certificates must be on in the tailnet's admin console):

    tailscale serve --bg --https=8443 http://127.0.0.1:8421

Then open `https://<machine>.<tailnet>.ts.net:8443/board` on the phone, sign
in, and install it: on Android, Chrome's menu → **Install app** (or **Add to
Home screen**); on an iPhone, Safari's Share → **Add to Home Screen**. The
installed app keeps its own sign-in (on an iPhone it doesn't share Safari's
cookies), so it asks for the password once. The same address also gets the
microphone for voice (below).

- Pick any free port for `--https`; plain `--https=443` replaces whatever
  this machine already serves there. `tailscale serve status` shows what's
  set, and `tailscale serve --https=8443 off` removes it. Only `tailscale
  funnel` would put it on the internet; `serve` stays on the tailnet.
- The app is the page served live, nothing cached on the phone: it needs
  the tailnet up and `cl web` running, and picks up a new cl at once.
- Over plain `http://<machine>:8421` Android only makes a home-screen
  shortcut that opens in a browser tab; an iPhone's Add to Home Screen
  still opens full-screen.

#### Notifications

The phone (or any browser on the HTTPS address) can get a notification when
something lands in Needs You: a question or permission prompt, a plan or
work ready for you, work that didn't land, a parked ticket waking, Claude
idle, or a `cl alert`. Tapping it opens a compact view of just that item:
a question with its options, the plan with Approve plan and a box for
feedback, the review with Merge (Full ticket shows the rest, and closing it
shows the board). On the board, Projects → **Notifications** → **Turn on for
this device**, and allow them. On an iPhone this works only in the app added
to the home screen (iOS 16.4 or later), not in Safari.

- The same dialog lists every device that's on, each with an on/off switch,
  **Test** (sends one now, or shows why it couldn't) and **Remove** (it
  stays removed until you press Turn on on that device again); picks
  which kinds notify; and sets quiet hours (in each device's own time).
  What comes up in quiet hours waits in Needs You without a notification.
- On Android the notification also has buttons that act there and then,
  signed in as the board is on that phone: a question's options (a single
  question with one answer) or a permission prompt's, **Approve plan**,
  **Merge** (work in Review or Testing with a branch or change of its own),
  or **Dismiss** (an alert, or a flag that doesn't wait on you). It says
  what it's doing at once, then what happened; an item dealt with since
  (on the board, or by Claude moving on) is left alone and says so. Chrome
  shows two buttons; iOS shows none, so there the compact view is the way.
- Each thing notifies once, when it is new: a flag that leaves Needs You
  while Claude works on it and comes back doesn't notify again. What lands
  while `cl web` restarts (after a merge, say) still notifies once it is
  back. Tapping a notification while signed out comes back to its ticket
  after you sign in. A newer
  notification for the same ticket replaces the older one, and opening the
  board clears those about what no longer needs you.
- It is standard Web Push: `cl web` sends to the browser's push service
  (Google's for Chrome on Android, Apple's for an iPhone, Mozilla's for
  Firefox), so this machine needs to reach those over HTTPS. Only one
  server sends (the one holding `<board.dir>/push.lock`), so a test server
  next to the main one doesn't notify twice. Devices and the key cl signs
  with are kept in the board database; a device whose browser dropped its
  subscription is removed the first time a send says so.

## Window

`cl window` opens the web UI (board, session terminals, chat) in its own
desktop window, so terminal keys aren't taken by a browser. It starts `cl web`
first if nothing answers on its port (from `web.listen`, or `CL_PORT`), and
opens the board. Closing the window leaves `cl web` and every session running;
reopening it comes back to the page, size and zoom you left. A second
`cl window` raises the open one.

While the window isn't focused, something new landing in Needs You (a flag,
or a session's `cl alert`) makes it ask for attention: KDE highlights its
taskbar entry (other desktops show it their own way) without taking focus.
It checks every few seconds (`GET /api/needs`), whatever page it is on. Only
new ones count: a flag that drops out of Needs You while Claude works on its
ticket and comes back when Claude stops doesn't ask again.

`cl window install` adds it to the app launcher (a `.desktop` entry and icon
under `~/.local/share`, pointing at the `cl` you ran it with).

The window is `cl-window`, a small GTK 4 / WebKitGTK program that the build
makes next to `cl` when `webkitgtk-6.0` is installed (Arch: `webkitgtk-6.0`;
force it on or off with `-Dwindow=true|false`). Install it beside `cl`:

```
zig build -Doptimize=ReleaseSafe
install -m755 zig-out/bin/cl zig-out/bin/cl-window ~/.local/bin/
cl window install
```

- The web view has no browser shortcuts, so Ctrl+W, Ctrl+T, Ctrl+L, Ctrl+R
  and the rest go to the terminal. The window's own keys use Ctrl+Shift:
  R reloads, + / - / 0 zoom the page (terminal included), I opens the web
  inspector. F5 reloads as well, from the board, a terminal or the chat
  (so a terminal never gets F5), and Ctrl+F5 or Shift+F5 reloads past the
  cache. On the board, Ctrl+= / Ctrl+- resize it too (see `web.font_size`).
- With voice on, Ctrl+Shift+Space in a terminal dictates into it (Voice,
  "Dictating into a session").
- The clipboard is the desktop's. In a terminal, a copy in tmux (a mouse
  selection) or by a program in it (Claude Code, via OSC 52) lands there;
  so does Ctrl+Shift+C on a Shift+drag selection. Ctrl+Shift+V pastes. A
  browser tab does the same, though it may refuse a copy that doesn't
  follow a click or key.
- Sign in once; the cookie and page storage are kept in
  `~/.local/share/cl/window`. Its log is `~/.local/state/cl/window.log`.
- Links to other sites, "open in the browser" links (gutter) and links in a
  terminal (Claude's, and bare URLs) open in the default browser.
- Without `cl-window` (release binaries are static and don't include it),
  `cl window` opens a Chromium-family browser with `--app`, or else the default
  browser. Those keep Ctrl+W, Ctrl+T and Ctrl+N for themselves.

## Voice

A prototype: talk to the operator from the web board and hear a short
answer. It is off unless `voice.stt` is set. Nothing about it is built into
cl: whisper and Piper are programs it runs when the config names them, so
installing cl needs neither, and there's no build flag. Unset, there is no
mic button; set to something that isn't installed, the board shows the
command's error ("voice.stt failed: sh: whisper-cli: command not found")
when you use it.

With it on, the board has a mic button next to Chat. Click it, speak, and
click again (or hold **V**, outside text boxes, and let go; Esc cancels).
`cl web` turns the recording into text with `voice.stt` and types it into the
operator as `[voice] <what you said>`, the way Quick ticket does (starting
the operator if it isn't running). The operator handles it as usual, and its
instructions tell it to end with `cl say "<a sentence or two>"`, written to
be heard. The board waits for that, shows it in a box at the bottom right
(↻ says it again, × stops), and speaks it. If the operator finishes without
`cl say`, the board speaks the first sentence of its written reply.

```
voice.stt = whisper-cli -m ~/.local/share/whisper/ggml-base.en.bin -nt -np -f
voice.tts = ~/.local/bin/piper -m ~/.local/share/piper/en_US-lessac-medium.onnx -f
```

Both are shell commands, and cl adds a file as the last argument:

- `voice.stt` gets a 16 kHz mono WAV file and prints the words. Without it
  there is no mic button.
- `voice.tts` gets the text on stdin and writes a WAV file. Or it's the URL
  of a speech server that keeps its model loaded (below), which is quicker.
  Without it the browser speaks with its own voice (`speechSynthesis`),
  which in `cl window` and on Linux browsers is usually espeak, and robotic.
- Give full paths for anything outside `/usr/bin`: `cl web` often runs
  without `~/.local/bin` on PATH (where `uv tool install` puts `piper`). `~`
  works, since the shell runs the command.
- When either fails, the board shows the last line of the command's error
  ("voice.tts failed: sh: line 1: piper: command not found"); all of it goes
  to the server's log.

Setup with whisper.cpp and Piper, both local, on Arch:

```
sudo pacman -S whisper-cpp                         # whisper-cli
mkdir -p ~/.local/share/whisper ~/.local/share/piper
curl -L -o ~/.local/share/whisper/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
uv tool install piper-tts                          # ~/.local/bin/piper (Arch's `piper` package is something else)
for f in en_US-lessac-medium.onnx en_US-lessac-medium.onnx.json; do
  curl -L -o ~/.local/share/piper/$f \
    https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/$f
done
```

### Piper as a server (quicker answers)

Run as a command, Piper loads its 63 MB model on every answer, about 2.5 s
before it says anything. Its HTTP server loads it once. With `voice.tts` set
to the server's URL, `cl web` POSTs each answer to it, and the board asks for
each sentence separately and starts playing the first while the rest are
made: about a second from the operator's `cl say` to sound. It needs Piper's
`http` extra and something to keep it running, here a systemd user service:

```
uv tool install --force 'piper-tts[http]'
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/piper-tts.service <<'EOF'
[Unit]
Description=Piper text to speech for cl

[Service]
WorkingDirectory=%h/.local/share/piper
ExecStart=%h/.local/share/uv/tools/piper-tts/bin/python -m piper.http_server --host 127.0.0.1 --port 5005 --data-dir %h/.local/share/piper -m en_US-lessac-medium
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user enable --now piper-tts
```

```
voice.tts = http://127.0.0.1:5005/synthesize
voice.tts_voice = en_GB-alba-medium     # optional: another voice in ~/.local/share/piper
voice.tts_speed = 1.4                   # optional: speaking speed, 1 is normal
voice.tts_pitch = 1.04                  # optional: a little higher (1.08 is about a semitone)
```

Piper has no pitch control, so `voice.tts_pitch` is the board playing each
clip that much faster without keeping its pitch; cl asks Piper for speech
that much slower to match, so `voice.tts_speed` still holds. Without a server
(a `voice.tts` command, or the browser's voice) the browser's own rate and
pitch are used where it can, and a command's speed is its own flags (Piper:
`--length-scale 0.75`).

Keep `--host 127.0.0.1`: Piper's default is every interface. Its page at
http://127.0.0.1:5005/ tries the loaded voice. For others, download them
(`~/.local/share/uv/tools/piper-tts/bin/python -m piper.download_voices
--download-dir ~/.local/share/piper en_GB-alba-medium`; the list is at
https://rhasspy.github.io/piper-samples/) and name one in `voice.tts_voice`
(restart `cl web`), or make it the server's default with `-m` (restart the
service). A voice takes a few seconds to load the first time it's used.

On macOS, `brew install whisper-cpp` gives the same `whisper-cli`. Any other
command that fits works too: a hosted speech API behind a small script, say.
Then restart the server (`cl web stop`) and reload the board.

- The browser allows the microphone only on HTTPS or `127.0.0.1`/`localhost`.
  `cl window` and a browser on this machine work; a phone over
  `http://<machine>:8421` gets "the browser only allows the mic on HTTPS".
  `tailscale serve` can put HTTPS in front of `cl web` for that (Web, "On a
  phone").
- `cl window` allows the microphone for cl's own pages, and lets the answer
  play without a click.
- Speed, on CPU: whisper's `base.en` takes 2–4 s for a short request.
  Piper as a command takes 3–4 s, mostly loading its model; as a server,
  about 0.5 s for the first sentence. Adding `-ac 768` to
  `voice.stt` makes whisper about a third faster but it then only hears the
  first ~15 seconds; `tiny.en` is faster and less accurate.
- Quiet recordings aren't sent: whisper turns silence into words like "you".
- The operator runs the `cl` that started it (by full path), so its commands
  match its instructions. Both are fixed when it starts: after upgrading cl,
  `/exit` in Chat restarts it with the new ones the next time it's needed.
- Where the time goes: whisper (2–4 s), the operator's turn, and Piper. For a
  quicker turn, set `operator.model` (above); for quicker speech, run Piper
  as a server. The board hears about `cl say` within ~150 ms (a long poll).

### Dictating into a session

The same mic types into a session instead of talking to the operator. In a
session's terminal page (opened from the board, in `cl window` or a browser),
hold **Ctrl+Shift+Space** while you speak and let go, or tap it, speak, and
tap it again; the mic button in the key bar under the terminal does the same
with a click (or a tap on a phone). Esc cancels, while it listens or while
the words are being worked out. `cl web` turns the recording
into text with `voice.stt`, as above, and the page pastes it into the
session, so the words land at Claude's prompt (with a space after them)
without being sent: read them, fix them, press Enter. A box at the top right
shows what it's doing, and why when it fails.

It needs only `voice.stt`: without it there is no mic button and
Ctrl+Shift+Space goes to the terminal as usual. Holding works because the
page sees the key go up, which a terminal inside tmux never passes on.

- It's the browser's microphone, so the HTTPS rule above applies: `cl
  window`, a browser on this machine, or a phone through `tailscale serve`.
- In a plain terminal attached to tmux there's no page to record from:
  see the next section.

### Dictating from a terminal

In a terminal attached to a session (`cl attach` in Konsole, say), press
**Alt+`** (backtick), speak, and press it again: the words land at Claude's
prompt the same way, unsent. It's a toggle, not a hold, because a terminal
never says when a key goes up. While it records, the session's status line
shows "● dictating" at the right; messages there say it's working out the
words, and why when it fails.

It's `cl dictate`, which you can also run yourself or bind elsewhere:

    cl dictate [name]     start recording, or stop and type the words in
    cl dictate --cancel   stop without typing anything

- It records this machine's mic with `pw-record` (PipeWire), into a WAV
  under `$XDG_RUNTIME_DIR`, and runs `voice.stt` on it, so it needs both.
- There's one recording at a time: the second press types into the session
  the first one started in, wherever you pressed it. A recording left
  running stops itself after 4 minutes; the next press still types it in.
  Presses less than a second apart count as one, so holding the key down
  (its autorepeat) starts one recording and doesn't stop it.
- Without a name it dictates into the session it runs in, or else the one
  the most recently used tmux client shows. So a desktop hotkey (KDE's
  Shortcuts, say) bound to `~/.local/bin/cl dictate` works whatever has
  the focus.
- Ctrl+Shift+Space, the web page's key, works too in a terminal that
  tells it from Ctrl+Space through tmux's extended keys (which cl turns
  on). Konsole doesn't: it sends Ctrl+Space, which goes to the session as
  usual, so use Alt+` there. For another key, add a tmux binding of your
  own (`bind-key -n M-v run-shell -b "cl dictate '#{session_name}' >/dev/null 2>&1"`,
  with cl on the tmux server's PATH) or a desktop hotkey.
- The binding names the `cl` that set it, as cl's hooks do: whatever last
  launched or attached a session, or started `cl web` (the main server,
  not a second one on `CL_PORT`). So after a merge, the restarted `cl web`
  points it at the new build, terminals already attached included. If
  that `cl` is gone (a ticket's build, its worktree removed), the key says
  so on the status line; attaching again binds it to yours.
- Claude Code's own `/voice` is the other way: it records with SoX or
  `arecord` and transcribes on Anthropic's servers, not locally.

## Board

A ticket board on top of the sessions, stored in SQLite at
`<board.dir>/board.db` (default `~/.local/state/cl`). Use it in the browser
at `/board` on `cl web` (the terminal page links to it), or with `cl ticket`;
both do the same things. The design notes are in `docs/board-plan.md`.

```
board.dir = ~/.local/state/cl
board.worktrees = ~/.local/share/cl/worktrees
board.dispatch = true            # cl web starts queued tickets
board.trust_projects = true      # say yes to Claude's folder-trust dialog in project folders and worktrees
```

Every ticket belongs to a project, which gives it a key prefix:

```
cl project add qa-tool ~/devel/qa-tool --slots 2 --mode worktree   # QA-1, QA-2, ...
cl project add boats ~/devel/boats --prefix BOAT
cl project list | set <name> [options] | rm <name>
cl project hide boats         # its tickets leave the board, Needs You, needs and list; queued ones still run
cl project unhide boats
cl project pause boats [--now] # start nothing new there (see Pausing); --all for every project
cl project resume boats
cl project set qa-tool --after-merge '<command>'   # run on each merge (see After merge)
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
review) are kept out through `.git/info/exclude`; everything
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
- Moving a ticket in progress back to queued or backlog stops it: its session
  ends as `cl t kill` does, so Claude doesn't carry on unseen (holding the
  project's slot) while the board says it waits. Its conversation and change
  are kept; queued, the dispatcher starts it again when its turn comes and it
  resumes; in backlog it waits until you queue or start it. It is refused while
  another ticket is in progress in that session (a queue project's shared
  session, or its parent's), which would be cut off too.
- Inside a ticket's session (`CL_TICKET` set) the key can be left out:
  `cl t done --summary ...`, `cl t comment "..."` (as claude).
- `--plan` starts a ticket in planning: Claude runs in plan mode, interviews
  you (`--skill grilling` or `--skill wayfinder` names a skill for it), posts
  the plan and runs `done`, which means "plan ready" there. On the web board,
  its Needs you card's Read the plan opens the ticket's Plan tab, with Approve
  plan and a box to send feedback. The plan stays approvable while Claude
  answers; a revised plan it hands in replaces it. Edit plan there changes
  its markdown yourself while a fresh session will build it (Planning, or
  Backlog and Queued before it has run: a session resuming its conversation
  isn't told the plan): that session gets the plan as you saved it, and
  Claude isn't told you changed it. If Claude hands
  in a revised plan while you edit, Save is refused rather than replace it. `cl t approve` moves it to Queued, and a new session builds it; on
  a ticket in review or testing, approve moves it on a stage.

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
  own session, up to the project's `--slots` in progress at once (3 by
  default).

A ticket starts from trunk unless it targets another branch: `--onto
<branch>` (a jj bookmark or git branch, like a long-lived feature branch that
mustn't reach trunk yet) on `cl t new` or `cl t edit` (`--onto ""` clears
it), or a project's default with `cl project set <name> --onto <branch>`.
A ticket without one of its own takes the project's, and a new sub-ticket
takes its parent's. The branch has to exist. Such a ticket starts on it: a
jj change on top of it (queue or worktree), a git worktree branch made from
it, a planning workspace on it, and a git queue ticket's session is told to
work on top of it. Its session is also told not to take the work to trunk.
`cl t show`, `--json` (`onto`, and `onto_own` for the ticket's own setting)
and the board's ticket view show it, and the New ticket dialog, the
ticket's Details tab and the project's dialog set it. A Quick Ticket that
names a branch to build on or merge into gets it as `--onto`. Finishing it merges into that branch, not trunk
(below); merging the branch itself into trunk stays yours to do.

A ticket can switch ways at any time (`cl t relocate QA-1 worktree|queue`, or
**Move to a worktree** / **Move to the queue** in the board's ⋯ menu, or the ticket's
**Runs as** and `cl t edit QA-1 --worktree|--queue`). One that hasn't
started only changes mode, except that one sent to a worktree from Queued
starts there right away (it no longer waits for a shared session), as does
one in Running, Review or Testing whose session is gone. One under way (jj only: it needs a change of its
own) takes its change and its conversation along, once its session is idle.
To a worktree: a `jj workspace` on its change, its transcript copied there
(Claude keeps them by directory) and resumed, and the queue session gets a new
conversation, free for the next ticket. Back to the queue: the workspace is
forgotten (its work stays in the change) and the conversation resumes in the
project's checkout on that change, in the project's session once it is free
(until then it waits in Queued). A move to a worktree respects the project's
`--slots`: with all of them taken it waits in Queued and starts in its
worktree when one frees up. Its change and bookmark stay the same throughout,
and Claude is told it moved.

```
cl t move QA-1 queued      the dispatcher starts it when it can
cl t start QA-1 [--now]    start it now (--now: type into a busy queue session anyway)
cl t dispatch [--once]     the dispatcher; `cl web` runs it too
cl t cleanup QA-1 --branch remove the worktree and its merged branch
```

The first message tells Claude the ticket (with any notes you added before
it started) and how to finish: write a review guide for gutter
(`.claude/review-guide.md`, only asked for when gutter is installed; Claude
checks it with `gutter -open=false`, so no browser tab opens), then `cl ticket done <key> --summary ...`, with
`--test-plan -` and the plan on stdin if there is something to try: steps
the Test tab walks you through one at a time, with buttons to run a command
and open a page, checks to pass or fail and a comment box per step, all
saved as you go (`cl t testplan --format`). You can send what you have to
Claude from any step: checks you didn't get to go as not tested, and Claude
is told which steps still need testing. Finishing needs every check passed. The plan is kept in the ticket on the board, not in a file,
so each ticket's Test tab shows only what its own session gave. So is the
review guide: `done` moves `.claude/review-guide.md` into the ticket (a
guide older than the ticket's session is someone else's and is dropped), and
gutter gets the ticket's own (or none), never what another ticket left in a
shared checkout. A later round without a new guide keeps the old one. An idle
session that never said done stays in running.

Sessions cl starts for tickets get `CL_TICKET` and hooks (`--settings
<board.dir>/claude-hooks.json`): a permission prompt sets `input`, and the
end of a turn clears it. An AskUserQuestion call is kept on the ticket as it
starts (PreToolUse), so the board has its questions and options while the
menu is open, even where Claude Code writes the call to the transcript only
once it is answered. A ticket whose session goes away gets `ended`;
`cl t start` starts it again.

A session cl didn't start for the ticket (one you told about it with `cl
send`, or the one it went on in after its own ended) can be made its session
with `cl t attach <key> <session>` (a cl name, or tmux name). The board then
follows that session for the ticket, as if cl had started it there: its
status, flags and Needs You, and `cl t kill` and the rest act on it. A ticket
with no jj change of its own takes the one the session works in, when that
is unclaimed work (the working copy's change, undescribed and not in trunk,
and no other ticket's): it is described and bookmarked like a started
ticket's, so finishing it merges it, and its base (what gutter diffs
against) is the commit below it. When there is none to take (a shared
checkout on another ticket's change, or git), attach says so: finishing it
then only closes it, and merging its work is yours to do. When Claude is
idle there, it is restarted resuming the same conversation (a new one if it
hasn't said anything yet), with the ticket's hooks and `CL_TICKET`, and told
the ticket (its description and how to finish); not when it was told already
(cl started it there, or an earlier attach restarted it, in the conversation
it still has). When it is busy, waiting on you, or idle with a background
task (a dev server) a restart would end, it is left as it is: the session is
recorded, and attaching it again once it is idle adds the rest. A ticket in
Backlog or Queued moves to Running; one in Review or Testing stays put. It is
refused for a session outside the ticket's project (its checkout, the
ticket's worktree or the project's worktrees), when the session belongs to
another ticket that isn't done, and when the ticket has a live session of its
own (`cl t kill` it first). There is no board action for it yet.

### Pausing

`cl project pause <name>` (or `--all`, or **Pause** in the web board's
Projects view) holds a project's dispatching, for when its work has to stop
for a while (moving it to another account, say). The dispatcher starts
nothing new there: queued tickets stay in Queued, keeping their order, and
read "paused" instead of "waiting for a slot"; planning tickets wait to be
planned; and a parked ticket whose check passes ends its park but waits in
Queued (with the note it resumes with) instead of resuming. What runs goes
on to the end of its work, and Review and Testing wait on you as before.
`cl project resume <name>` (or `--all`) starts dispatching again, top of the
queue first. The pause is kept on the project, so it survives a `cl web`
restart; `cl project list` says `paused`, and the board shows a banner with
**Resume**.

A pause holds only what cl starts on its own. What you start yourself still
starts (`cl t start`, the board's Start, `unpark`, a move to a worktree), and
what goes into a session that is already running still goes (comments sent
with `--send`, answers, merge and PR instructions, after-merge runs).

`--now` (**Pause now** on the board) also stops what the project is working
on, as moving a running ticket back to Queued does: each Running ticket's
session is killed and it goes back to Queued, its conversation and change
kept, to resume where it left off once the project resumes. Planning
sessions end too; their tickets stay in Planning and are planned again,
resuming the conversation. A ticket whose session another ticket in progress
shares (a sub-ticket in its parent's) is left running and named.

### Parking a ticket

A ticket waiting on something outside cl (a PR review, a deploy) can be
parked rather than left with an idle session:

```
cl t park QA-3 --reason "PR #30: waiting for approval, merge and deploy" --every 1h \
  --until 'gh run list --repo org/repo --workflow deploy.yml --json conclusion -q ".[0].conclusion" | grep -qx success'
cl t unpark QA-3 [--no-resume]
cl t list --parked
```

Parking ends its session as `cl t kill` does (stage and conversation kept),
keeps it out of Needs You, and shows "Parked: <reason>" on its card. The
dispatcher never starts a parked ticket, even one moved to Queued; only the
park ending (or `cl t start`, which ends it) brings it back. Moving it to
Done (by any route: the board, `cl t move`, Claude's `done --close`, an
umbrella closing) ends the park without resuming it, and `cl t rm` drops it
with the ticket. Shelved in Backlog it stays parked; a check that passes
there ends the park (`unparked` flag) but leaves it in Backlog, its note
waiting for when it's queued again. With
`--until`, the dispatcher (`cl web`, `cl t dispatch`) runs the command with
`sh -c` from the ticket's directory, at once and then every `--every`
(default 1h), detached and in the dispatcher's environment (your `gh` login
and so on); one check may run up to 10 minutes. Exit 0 ends the park: the
ticket gets the `unparked` flag and its session resumes, told "Parked
condition met: <reason>. Continue." No pass within `--max` (default 7d)
ends it with `park-expired`, and the session stays stopped. Without
`--until` nothing checks it. On the board, Park in the ticket popup's ⋯ menu does
the same with a form, and the Parked switch over the board hides parked tickets. `unpark` (the board's Resume, `P` in the
chooser) ends it by hand and resumes the session; `--no-resume` (Cancel
park) only ends it. Claude can park its own ticket from its session (the
key may be left out); the session closes after the command answers.
`cl t show` (and `--json`) has the park, its last check and the next.

#### Parking on a PR

```
cl t park QA-3 --pr https://github.com/org/repo/pull/30    (or --pr '#30')
```

`--pr` writes the check itself: `gh pr view <n> -R <repo> --json state`,
merged passes. The repo comes from the URL, or for `#30` from the ticket's
checkout's `origin` remote (jj's remotes first, then git's); `org/repo#30`
works too. `--reason` defaults to "PR #30: waiting to merge" and `--max` to
14d (`--every` stays 1h: it's one cheap gh call). A PR closed without merging
ends the park at its next check with a `pr-closed` flag in Needs You,
rather than being checked until `--max`; the session stays stopped. Merged,
its session resumes told "The PR it waited on has merged: <url>.". The
board's Park form has a PR field that does the same.

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

On the board's Needs You, Hide takes a card out until the ticket raises a
new flag; its flags stay ("not now"). Dismiss clears the card's flag, as
`cl t unflag` does ("seen it, it's dealt with"): the ticket doesn't change,
and the flag comes back only if the same thing happens again. When two or
more cards share a kind, "Dismiss all" clears that kind on them after you
confirm. Dismiss is only offered on informational flags (didn't start,
session ended, after-merge failed, didn't land, not merged, woke from park,
park expired, PR closed, flags set by hand); a question, a permission prompt, a review, a test or a conflict waits
on you, and clears when you act on it.

`cl t watch` prints a line each time a ticket's flags or stage change, until
killed (`--json` for one object per line, with the flag's details):

```
CL-37 cl-wrapper set question Add cl ticket watch
CL-37 cl-wrapper cleared question Add cl ticket watch
CL-37 cl-wrapper moved running->review Add cl ticket watch
CL-90 cl-wrapper new backlog Fix the login page
CL-37 cl-wrapper needs question,review Add cl ticket watch
CL-37 cl-wrapper left question,review Add cl ticket watch
```

`needs` and `left` follow Needs you, decided the same way the board does it.
`needs` comes when a ticket lands there, or asks something new while it's
there, with the flags it asks about. `left` comes when it goes (answered,
hidden, dismissed, parked, or Claude went back to work on it).

Options narrow it, each a comma-separated list: ticket keys, `--project`,
`--change set,cleared,moved,new,needs,left`, `--flag <kinds>` (lines about
those flags only) and `--stage <stages>` (moved and new lines into those
stages only). `cl t watch --change needs` follows Needs you, and
`cl t watch --change needs --flag question,input --project qa` follows only
qa's questions and permission prompts.

It reads the board every two seconds, so it sees what the CLI, the web board
and the dispatcher do alike. Tickets of hidden projects and of hidden
sessions stay quiet; unhiding one doesn't replay what changed meanwhile, but
its tickets now in Needs you get a `needs` line.

The operator keeps it running, by default as `--change needs` (Needs you).
It picks other options from what you've told it, and decides for itself what,
if anything, to do with each line. By default it does nothing, since you see
Needs you yourself. Tell it to keep a project moving and it handles what lands
in Needs you for that project, within what you let it do (answer questions,
approve, finish, restart; it asks once if you didn't say). It alerts you for
the rest. It also answers the kinds of questions you've said it may handle,
raises one `cl alert` for tickets or kinds of flag you asked it to follow, and
alerts when something looks wrong that the board won't make obvious. What you
tell it goes in its notes.

### Review and testing

```
cl t gutter QA-1 [--stop]          review the ticket's changes in gutter's window; Submit sends it to Claude
cl t autoreview QA-1 [--stop]      a second Claude reviews the changes; its findings wait on the ticket for you
cl t autoreview QA-1 --send        send the findings to the ticket's session (another round)
cl t testplan QA-1                 Claude's test plan, step by step
cl t launch QA-1 --step 2          run step 2's run: command (tmux session clrun_qa-1_s2; --stop ends it)
cl t test QA-1                     walk through the plan here; failures go back to Claude (s at a check stops and sends what you have)
cl t approve QA-1                  review -> testing -> done
```

Reviewing in gutter is optional. cl uses
`gutter.path` from the config when it is set, else `gutter` on PATH:

```
gutter.path = ~/bin/gutter       # "" (the default) looks gutter up on PATH
```

Without gutter (or when `gutter.path` isn't an executable file) the board
shows no Open in gutter, Claude isn't asked for a review guide, and
`cl t gutter` says gutter isn't installed and exits 1. Review still works:
read Claude's summary, approve, or send it back with a comment.

`cl t gutter` (or the board's Open in gutter) opens gutter's window
(`gutter -sync -window`, in tmux session clg_qa-1) in the ticket's worktree,
diffing against the revision the ticket started from. When you click Submit,
cl pastes the review into the ticket's session, keeps it on the ticket as your
comment, and the ticket starts another round. Closing gutter without
submitting (or `--stop`) leaves the ticket as it was. gutter only listens on
127.0.0.1, so while it runs the board links to it and `cl web` also opens the
same port on its other `web.listen` addresses (tailscale) and forwards it. Test results that all pass move a ticket in testing to
done; a failure sends them to Claude for another round, and so can comments
when everything passed (the board asks).

#### Automated review

`cl t autoreview QA-1`, or the board's Auto review (in a ticket's action bar,
or Run automated review on its Review tab; in Review or Testing), has a second
Claude go over the changes before you spend time on them. It isn't the
ticket's own session, which is anchored on its own reasoning; the ticket stays
where it is while it runs, out of Needs You (`cl t needs` and `cl t watch`
too), as when Claude is working on it. When the review finishes or fails, the
ticket is back there with its Ready for review flag (raised again if you
dismissed or hid it meanwhile), and its card says how many findings there
are. The reviewer is
an interactive `claude` in tmux session clrv_qa-1 (`tmux attach -t clrv_qa-1`
to watch), in the ticket's directory, under the same profile as the ticket's
session (the ticket's, else its project's, else `default`; never whatever
`CLAUDE_CONFIG_DIR` `cl web` happens to have), so its usage goes to the same
account. `review.model = sonnet` picks its model; without it, the profile's.

It is told the ticket, its plan, your comments and Claude's summary, and
looks for bugs first, then gaps against what was asked, then breaches of the
repo's CLAUDE.md, AGENTS.md or CONTRIBUTING.md. A project can have it use a
skill instead (`cl project set <p> --review-skill code-review`); the skill's
findings still come back in cl's format. cl writes what it reviews to
`~/.local/state/cl/autoreview/QA-1.diff` (the changes' descriptions and the
diff, as of the start) and its instructions to `QA-1.md` next to it, both kept
for you to look at. It runs with Claude's `dontAsk` permission mode and an
allow list: reading files (Read, Grep, Glob) and writing one file, its
findings (`QA-1.json`). No shell, so not even a read command's `--output`.
Anything else is refused, not asked, so it can't change the work or wait on
a prompt nobody sees. It has
none of the ticket's hooks, so it can't flag, move or finish the ticket. When
it stops, its own Stop hook hands the findings to cl (sending it back once if
the JSON is wrong) and closes its session. One that is still running after 20
minutes, or whose session ends without findings, is recorded as failed.

Nothing goes to the ticket's session by itself. The findings show on the
Review tab and in `cl t show`, most severe first, with two ways on: Send
findings to Claude (`--send`) pastes them in like a review you wrote, which
starts another round, and Open in gutter with findings opens gutter with them
as your draft review: those with a file and line as inline comments, the rest
in the overall note. Delete the wrong ones, edit or add, and Submit as usual.
A draft of your own for the same changes is kept instead (the board says so);
one cl wrote that you left as it was is replaced by newer findings.
Edit, on the Review tab, opens the message Send findings would paste in as
one text to change: drop findings, reword them, add your own. Saved, it is
what Send findings sends, and Open in gutter puts it whole in the overall
note (without the opening line addressed to Claude); Back to the findings
drops it, and a new review starts without it. If the review runs again while
you edit, Save is refused, so your edit isn't put on findings you haven't seen.
The Review tab, the ticket's Needs You card and its board card say where the
findings stand, each in its own color: New findings (N to read, nothing sent
yet), Sent to Claude (it hasn't finished the round they started), Handled by
Claude (it ran `cl ticket done` after them, and its summary shows as its
reply; findings sent before cl kept this read as handled once the ticket is
out of Running),
or Outdated (never sent, and Claude has changed the code since: Run again).
Sent, handled or outdated findings fold away behind Show the findings, dimmed,
and nothing about them puts the ticket in Needs You. The message sent asks
Claude to end its summary with one line per finding (`Finding 2: fixed`,
`partly` or `declined`); when its reply has one for every finding, each
finding shows what Claude did with it and the state says "2 fixed, 1
declined". Otherwise the board doesn't guess, and only the reply is there.
Findings sent into a round already under way (the ticket in Running) stay
Sent to Claude after its next done, which may have come before Claude read
them. A review run again after Claude handled the last one's findings keeps
that outcome under it as "Last review: handled by Claude".
Done,
deleting the ticket, or moving it back to Queued stops a review that's
running.

A project can have it run by itself when a ticket reaches Review: `cl project
set <p> --auto-review on` (or the project's "When a ticket reaches Review" on
the board). When Claude says it's done (`cl ticket done`, or the board's
done for it), the review starts right away, so the ticket reaches Needs You with its findings already there
instead of waiting for you to press Auto review. `--auto-review send` also
sends what it finds to Claude, as Send findings would, for one round; when
Claude finishes that round, the ticket waits for you with the old findings and
Claude's answer. A review with no findings sends nothing.
Either way it runs only the first time a ticket reaches Review: not again when
it comes back (Claude says done twice, answers the findings, or finishes a
round you started with a comment), so the two don't go back and forth with
nobody looking. Auto review still runs one whenever you press it. A ticket
with no changes, or one whose reviewer can't start, is skipped (its log says
why, and the next time it reaches Review tries again; so does one whose
automatic review failed) and is in Needs You as usual; so are findings cl
couldn't send because the ticket's session is gone. With send, the ticket
only comes back to Needs You if cl couldn't send them, or once Claude has
answered. If you approve or send the
ticket back while the review runs, nothing is sent by itself. A review
started this way says so on the Review tab and in `cl t show`. `off` (the
default) goes back to only when you start it.

Tests clean up after themselves. Sending test results stops the ticket's
launches, and so does finishing it. Once a minute the main `cl web` also
stops whatever a finished (or deleted) ticket left running: its launch
sessions, and any second `cl web` (`CL_PORT`, `--port`, or
`.claude/test-web.sh`'s) whose build or directory is in that ticket's
worktree, such as one its Claude started by hand. Test servers outside the
worktrees root are left alone.

### Finishing

Done closes the ticket's session, whichever way it gets there (and so does
deleting a ticket). Finished from the board of its own test server, that
server's launch is left running until the minute sweep below stops it, so the
request isn't cut off before the session is closed. Once a minute the main
`cl web` also closes any Done ticket's session still alive that no unfinished
ticket uses, should whatever moved it have been stopped halfway (say, `cl web`
restarted by an after-merge command). For a ticket with a branch of its own
(a jj change, or a git worktree's branch) you choose what happens to the branch first: the board asks
when a card is dropped on Done (or Done is picked, or it is approved out of
testing), and the CLI takes a flag:

```
cl t move QA-1 done --merge        merge it into the main branch, or its --onto branch (see below)
cl t move QA-1 done --pr           Claude pushes it and opens a PR
cl t move QA-1 done --tell "<text>"  Claude does what you say first (anything)
cl t move QA-1 done [--close]      just close (the default; also approve and test)
```

The board's dialog has the same choices: "Tell Claude what to do" takes your
words, for anything the others don't cover, branch or not. When a ticket
shouldn't be finished the usual way, its Claude can say so with
`cl t custom-close QA-1 "<what to do instead>"` (`--clear` undoes it). The card
then shows a Custom close pill, Merge and PR are turned off for it (in the
dialog and the CLI), and the dialog fills Tell Claude in with Claude's
words.

#### Work left for after a PR merges

A ticket finished with a PR closes when the PR is open; whatever is left
for after the merge (a deploy, a backfill on prod) goes in a follow-up:

```
cl t move QA-3 done --pr --then "Deploy, back up, dry run, then run metadata:redact on prod"
```

(`approve --pr --then` too; on the board, the box under Open a PR in the
Done dialog.) When Claude runs `cl t done QA-3 --close --pr-url <url>`
(refused without the URL while there are steps), QA-3 goes to Done as usual,
and cl creates a sub-ticket of it, "After PR #30 merges: <title>", in Queued
and parked on that PR (`--pr` above). Its description names the parent, the
PR and the steps. When the PR merges, it starts with a fresh session that
does them; closed without merging, it gets `pr-closed` and waits for you.
Claude can suggest the steps from its session with `cl t custom-close --then
"<steps>"` (not a custom close: Merge and PR stay on): the Done dialog fills
the box in with them, and `move --pr` without `--then` takes them (`--then
""` drops them).

With `--merge` or `--pr` the instruction is typed into the ticket's session
and the ticket stays where it is with a Finishing pill; questions and
conflicts come back through the board as usual. When Claude is through it
runs `cl t done QA-1 --close [--pr-url <url>]`: the ticket moves to done, the
PR link becomes a comment, and then the session closes.

A jj change is merged by cl itself: it rebases the change onto trunk and,
with no conflicts, moves trunk to it and drops the bookmark (a change with no
edits is dropped instead). A checkout left on the merged change gets a new one
on top, and one with nothing of its own moves up to trunk. The ticket's
worktree is brought up to date first (`jj workspace update-stale`), so it
ends up on trunk with the merged files and nothing pending. When the checkout's
files changed and the session is still there, Claude is asked to restart what
runs from it before Done. Conflicts are recorded by jj in the change and put on
the ticket as a `conflict` flag listing the files; trunk stays put, and Claude
is asked to settle them in the change and run `cl t done QA-1 --close`, which
merges it then (and refuses while any are left). Git branches are merged by
Claude as before.

A ticket with a target branch (`--onto`) goes into that branch instead
everywhere above: cl rebases the jj change onto it and moves its bookmark,
Claude merges a git branch into it, and a PR is opened against it. The
project's checkout then stays where it was unless it was on the merged
change itself, rather than moving onto the branch. Nothing after-merge runs
(see After merge).

#### When it doesn't land

Work that was approved but didn't reach trunk is flagged, so it shows in
Needs You with the ticket's key and why, Done or not:

- `conflict`: merging it conflicts; the flag lists the files (above).
- `merge-failed` (Didn't land): cl couldn't merge it (jj failed, no trunk
  bookmark; jj's error is on the flag), or the ticket was finishing (Claude
  merging it, opening its PR, doing what you told it) and Claude ended its turn
  without running `done --close` (the flag has the end of what it said) or its
  session ended (the ticket stops finishing, so Merge can be tried again).
  Trying again (Merge, PR, Tell Claude) clears it, and so does reaching Done.
- `unmerged` (Not merged): it went to Done without cl merging it (Close, a
  Tell Claude, or a git branch Claude said it merged) while its jj change or
  branch still holds work its target doesn't have: trunk, or its `--onto`
  branch, which the flag names (work on the branch that trunk lacks is
  where it belongs, not left behind). A custom close isn't checked:
  Claude said what to do with it instead, and you chose that. Its Not merged
  tab merges a jj change from there (`cl t move QA-1 done --merge` does the
  same), which clears it; so does reopening the ticket. Dismiss it when it
  wasn't meant to land.

A flag rather than a prompt at Close: the board, the CLI and Claude all close
tickets, and only the result says whether the work is on trunk.

#### Before it gets there: Will conflict

Conflicts needn't wait for the merge. The dispatcher (`cl web`, `cl t
dispatch`) test-rebases every open ticket's jj change onto its target (trunk,
or its `--onto` branch) once a minute, on a thread of its own, whenever the
target or the change has moved since the last test. First it checks whether
the files the change touches overlap the ones the target changed; only when
they do does it merge for real, with `git merge-tree` (renames not followed,
as jj's rebase doesn't follow them either). The test itself changes no working copy,
bookmark or jj operation. When the target moves, each ticket's workspace is
snapshotted first (a plain `jj log` there, as any jj command does), so work jj
hasn't recorded yet counts; that can add a snapshot to jj's operation log.
Each jj or git command gets 30 seconds. A ticket whose result can't be
told (its target bookmark gone, say) loses its warning rather than keeping
an old one.

A ticket that would conflict gets a **Will conflict** pill on its card (the
files in its tooltip), a box in its popup listing the files, a "will conflict"
event, and a line in `cl t show` (`drift` in `--json`). It isn't a flag:
nothing goes to Needs You, and nothing is typed into its session. The pill
goes by itself once the change no longer conflicts (rebased, or trunk moved
again).

```
cl t rebase QA-1      Rebase now: Claude rebases onto the target and settles the conflicts
```

Rebase now (the popup's button, or `cl t rebase`) types that into the
ticket's session: `jj rebase -b <change> -d '"<target>"'`, then settle what jj
records, check it builds, and carry on. It is only sent into a session that
is idle and on that ticket, so a working session isn't interrupted and a
question isn't answered by accident; otherwise it says why and waits for you
to try again. A ticket in Review or Testing goes back to Running, as a sent
comment does, and Claude says done again after. Git branches (no jj change)
aren't checked.

#### After merge

A project can have a command cl runs once a ticket is merged, to rebuild,
install or restart what runs from it:

```
cl project set cl-wrapper --after-merge 'zig build -Doptimize=ReleaseSafe && install -m755 zig-out/bin/cl* ~/.local/bin/'
cl project set cl-wrapper --after-merge ''     # none
cl project after-merge cl-wrapper              # run it now, on trunk as it is
```

It runs with `sh -c`, detached (a session of its own, so it outlives the
`cl web` or tmux session that merged the ticket, even when it restarts
them), in a clean checkout of the merged trunk commit at
`~/.local/state/cl/after-merge/<project>`: a detached git worktree of the
project's repo, reset to the commit with untracked files removed. Ignored files
(build output, caches) stay between runs. The project's own checkout isn't
used, because it may hold another ticket's unfinished work. The command gets
`CL_TICKET` (the merged ticket), `CL_TICKETS` (all the tickets in this run),
`CL_PROJECT`, `CL_COMMIT`, `CL_PROJECT_DIR` (the project's checkout) and
`CL_CHECKOUT` (the clean one, also its working directory).

Output goes to `~/.local/state/cl/after-merge-<project>.log`. The ticket's
activity gets the start and the result. A non-zero exit puts an `after-merge`
flag on the ticket with the log's tail; it shows in Needs you even though the
ticket is Done, and its After merge tab can run the command again or dismiss
the flag. One run per project goes at a time. Tickets merged during a run get one
more run after it, on the newest trunk.

It runs only for merges into trunk. A merge into a ticket's `--onto` branch
runs no command and asks Claude for no after-merge steps: what runs is built
from trunk, which hasn't changed. When that branch goes into trunk (your
call, by hand), run `cl project after-merge <name>` if it needs the steps.

When cl merges it: a jj change, right after cl moves trunk to it (a change with
no edits runs nothing). A git branch, which Claude merges, when Claude runs
`cl t done QA-1 --close` after the merge. With a command set, Claude
isn't asked to rebuild or restart anything itself.

Without a command, Claude does the after-merge steps instead. When cl has
merged a jj change, it types the steps into the ticket's session, and the ticket
stays Finishing until Claude runs `cl t done QA-1 --close`. If that session is
gone, the operator gets them and the ticket goes to Done. A git branch's merge
instruction includes them. A change whose conflicts Claude settled gets them
from `cl t done --close`, which merges it, prints the steps, and finishes on the
next `--close`. And when a command fails, the operator is asked to sort it out:
it gets the log's tail and reruns the command (`cl project after-merge`) once
the environment is fixed, or makes a ticket when the merged code is broken. A
run by hand also covers the project's tickets with a failed run, so one that
passes clears their flags. The steps are the project's own:

```
cl project set qa-tool --after-merge-claude 'Restart the dev server (npm run dev in tmux window 2).'
cl project set qa-tool --after-merge-claude ''       # the default
cl project set qa-tool --after-merge-claude none     # Claude does nothing after a merge
```

The default is to rebuild and restart whatever runs from the project's
checkout, as its CLAUDE.md says.

An open board notices when the server comes back from another build, and
reloads by itself (keeping the open ticket, drafts and scroll), or shows a
Reload banner while you are typing.

### The web board

`/board` shows Board, Lanes (a row per project) and List views, with "Needs
you" across the top: every ask, with quick answers, and the sessions' alerts
(`cl alert`, see Alerts). Filters pick what needs
you, a project, and whether sub-tickets show. A ticket opens in a popup:
answer its questions, comment or send it back, watch its session or open it
in the terminal (`/?attach=<session>`), open gutter, launch and test, see
its sub-tickets and activity, and edit it. On a phone the columns swipe and
the popup fills the screen.

Drag a card to another column to move it, or up and down for priority (on a
phone, hold it first). Each column runs top to bottom in priority order,
except Done (latest first); new tickets go to the bottom, and the dispatcher
starts queued tickets from the top.

Paste or drop an image (png, jpeg, gif or webp, up to 10 MB) into a
ticket's description, in New ticket or its Details, and it is uploaded and
put in as `![image](/absolute/path.png)`. The popup shows it as a thumbnail
that opens full size. Images live with the board, in
`<board.dir>/images/<KEY>/` (`images/new/` until the ticket is created;
unused ones there go after a day), and are served only to the logged-in
board. The session's first message lists the paths and tells Claude to open
them with its Read tool (it starts with `--add-dir` on the folder, so that
needs no permission). Deleting the ticket deletes its images.

- Sub-tickets are tickets with a parent: their own key, stage, flags and
  comments. `cl t new --parent QA-1 "title"`, or from the ticket's own
  session `cl t sub "title"`. `list --top` leaves them out, `list --parent
  QA-1` lists them, and `show` includes them. A ticket with sub-tickets can't
  be removed until they are.
- Sub-tickets run in order: each waits for the one ranked before it to be
  Done (rank them with `cl t rank` or by dragging, and the order follows),
  in queue and worktree projects alike. `--parallel` (on `new` or `edit`)
  lets one run without waiting; `--in-order` puts it back. A sub-ticket after
  a parallel one waits for it too, back to the first one in order.
- An umbrella (`cl t new --umbrella`, `edit --umbrella`, or Kind on the
  board) is only a container for sub-tickets: it never gets a session, and
  the dispatcher and Start leave it alone. Queueing it queues its sub-tickets
  (Backlog to Queued; back to Backlog shelves the ones not started); in
  Backlog (or Planning) it stays put while you add sub-tickets. Queued, it
  moves to Running when one of them starts, and to Done by itself when the
  last unfinished one reaches Done (or is deleted), which may finish its own
  umbrella too. Its card says Umbrella and what its sub-tickets are doing
  instead of a session status. Boards from before umbrellas had their
  parents that never started made umbrellas, once.
- Any other parent has work of its own, and runs first: its sub-tickets wait
  until it is Done (split-off work builds on it). If its sub-tickets are
  still all done before it is, it is flagged `ready-to-close` (Ready to
  close): Needs You offers Move to Done, which finishes it the usual way
  (Merge, PR or Close), or Dismiss to keep it open. A new sub-ticket, or one
  taken back out of Done, clears the flag.
- A parent's card and `show` count its sub-tickets done (`3/5`).
- Dependencies: `cl t edit QA-5 --after QA-3,WEB-2` makes QA-5 wait until
  those (any project) are Done; `--not-after QA-3` drops the link, and `new`
  takes `--after` too. On the board, a ticket's Blocked by row does the same:
  type a key (it suggests open tickets) and Add, or × on a link to drop it. The dispatcher leaves a waiting ticket in Queued (its
  card says "Waits on QA-3"), and starts it once they're done; `cl t start`
  still starts it by hand. A link that would make tickets wait on each other
  in a circle is refused, and so is a reorder of sub-tickets that would.
  `show` lists what it waits on and what it blocks (`--json`: `blocked_by`,
  `blocks`). Removing a ticket drops the links to it and says which tickets
  no longer wait on it.

### The terminal board

`b` in the chooser (or `cl board`) shows the board in the terminal: a column
per stage, each card with its key, title, session status and flags, in the
same order as the web board's columns. It shows what the web board shows:
hidden projects' tickets, sub-tickets and Done only when switched on (`H`,
`S`, `D`), and parked tickets unless switched off (`P`). It re-reads
the board every second and keeps the cursor on its ticket as cards move. The
operator's alert shows at the top right, as in the session list, and `o`
opens the operator from the board too.

Over the columns, Needs you lists the tickets `cl ticket needs` does, oldest ask
first, each with what it actually asks: the question and its numbered
options, the command a permission prompt is about, the plan or review
summary waiting for approval, the files that conflict, a failed after-merge
command. `Tab` steps into it (and back; `esc` too), where the keys below act
on the selected row, so `A 1` answers a question there and `a` approves; `N`
folds it away and back.

`h`/`l` and `j`/`k` (or the arrows) move between cards, `Enter` opens a
ticket in full (flags with what Claude asks, description, plan, sub-tickets,
comments and activity, and its session's pane below), and `Enter` again
opens its session; `esc` goes back. `n` makes a new ticket in the column the
cursor is on (Backlog from Done; one made in Planning plans first), asking
for its project (the selected ticket's to start with), title and an optional
description. On a card or an open ticket:

- `t` opens its session (attaches; `Ctrl-Q` comes back).
- `a` approves (plan → Queued, Review → Testing, Testing → Done).
- `A` answers what Claude asks: an option number or your own words, one per
  question separated by `|` (`cl ticket answer`).
- `m` then a stage letter moves it (`b p q r v t d`); `<` and `>` move it one
  stage back or on.
- `c` adds a note (it goes with the ticket's next prompt), `s` sends a line
  into its session (on a ticket in Review or Testing, that sends it back).
- `/` searches keys, titles and descriptions.

Going to Done asks what the web board asks: to spin off unfinished
sub-tickets, then, for a ticket with a branch or change of its own, whether
to merge it, open a PR, just close it, or tell Claude what to do.

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
