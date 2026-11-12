# cl board: plan

A ticket board on top of cl. Everything still runs as Claude Code sessions in
tmux; no API calls. The board is a tab in `cl web` (same server, same
password), with a phone layout, and can be wrapped as a desktop app later.

## Model

- **Stages** are the workflow and the columns: Backlog, Planning (optional),
  Queued, Running, Testing, Review, Done (CL-168: test first, review last).
- **Flags** say what needs you and drive the inbox and filters. Several can be
  set at once, independent of the stage:
  - `input`: Claude is blocked on a permission prompt (auto)
  - `question`: Claude asked an `AskUserQuestion` (auto)
  - `testing`: Claude said it's done: ready to test (auto, see Done)
  - `review`: tested (or nothing to test): ready for review (auto on Testing →
    Review, or by hand)
  - anything you set by hand

  A ticket whose session is busy working on it is left out of the inbox (the
  board's strip and `cl ticket needs`) until the session stops.
- **Views**: Board (stage columns), Lanes (project rows × stage columns), List.
  "Needs you" is an expanding strip at the top of every view, with a card per
  ask and its quick actions; it is the main thing to use while work runs.
  Clicking a ticket opens its popup: status, comments, questions, session
  tail, Open shell (also for questions), Open in gutter.
- **Re-iterating**: a comment sent to Claude on a ticket in Testing or Review
  means "not done": it goes back to Running and its round goes up, and its
  next done returns it to the stage it came from. A comment
  that isn't sent is a note and moves nothing.
- **Planning** is optional: `--plan` starts a ticket in the Planning column,
  where Claude plans in plan mode and its questions reach the inbox. A
  ticket can name a skill for it (the grilling skill, say) when you want a
  deeper interview; most tickets skip planning.
- **Sub-tickets**: full tickets with a parent (own key, stage, flags,
  comments). The ticket's agent creates them with `cl t sub`; each can raise
  its own questions and needs. The board has a show/hide filter for them
  (they always show on the parent's popup). A queue-mode sub-ticket with no
  target runs in its parent's session; `--worktree` gives it its own.
- **Parity**: every web action is a `cl ticket` / `cl project` command, and
  the web board calls the same code (`src/board.zig`).

## Storage

SQLite, vendored as the amalgamation and compiled by `zig build`, so the
binaries stay static. The file is `board.db` under `board.dir` from the config
(default `~/.local/state/cl`). FTS5 for search.

    tickets   id, key (CL-12), title, body, project, stage, mode (queue|worktree),
              target (tmux session for queue mode), worktree, branch, profile,
              tmux, session_id, summary, guide, created, updated
    comments  ticket, author (you|claude), body, at
    flags     ticket, kind, source (auto|manual), detail (JSON), at, cleared_at
    events    ticket, kind, detail (JSON), at        -- the Activity tab
    projects  name, dir, prefix, slots, mode, profile

Projects live in the database (so the web board can edit them), managed with
`cl project`. The config gains:

    board.dir = ~/.local/state/cl
    board.worktrees = ~/.local/share/cl/worktrees

## How tickets start

- **Queue (default)**: the ticket goes into the queue of a cl session you pick,
  or a new session (popup: directory, profile). When that session goes idle
  and its previous ticket is done, the dispatcher sends the next ticket's
  prompt with `cl send`.
- **Worktree**: one worktree per ticket, run in parallel up to the project's
  slot limit. `git worktree add <worktrees>/<project>/<key> -b <key>` (or `jj
  workspace add` in jj repos), then a new session there with the ticket as its
  first prompt. Removed when the ticket is closed, if you ask.

The dispatcher runs inside `cl web` (it is already long-running), polling the
store and session statuses every few seconds.

## Knowing what Claude is doing

Three sources, all local files or tmux:

1. **Session status**, as cl reads it today (`<config>/sessions/<pid>.json`):
   busy, blocked, idle, background task running.
2. **The transcript** (`<config>/projects/<dir>/<session>.jsonl`). Checked:
   an `AskUserQuestion` call is stored with its questions, headers and options,
   and the answer comes back as a matching tool result. A call with no result
   yet is a question waiting for you, so the board can show it with its
   options. The same applies to a permission prompt: the tool call (say the
   Bash command) is in the transcript with no result while the status is
   blocked.
3. **Claude telling us.** Every ticket prompt (and, for sessions cl starts,
   `--append-system-prompt`, as the operator already does) says: when the
   work is finished and needs no more input, write a gutter guide to
   `.claude/review-guide.md` (format: `gutter -guide-format`) and run
   `cl ticket done --summary "…"`. `CL_TICKET` is set in the session's
   environment so the command knows the ticket. An idle session that never
   said done stays in Running; only `done` moves it on (to Testing, or Review with no test plan).

   Claude Code hooks, passed per session with `--settings`, are a backstop:
   a Stop hook records each finished turn (the Activity tab), and a
   Notification hook records prompts the instant they appear.

## Acting from the board

- **Comment**: stored on the ticket; "Send to Claude" types it into the
  session with `cl send`.
- **Answer a question / permission prompt**: send the option's keys into the
  pane (`tmux send-keys`: the number, or typing for Other). Needs a spike to
  confirm Claude's menus take number keys reliably. Open shell always works.
- **Open shell**: the existing web terminal, attached to the ticket's tmux
  session instead of the chooser (`/ws?attach=<tmux>`). Works for questions
  too.
- **Open in gutter** (only when gutter is installed, see `gutter.path`): run `gutter -dir <worktree>/.claude -r <base>..<branch>`
  in a hidden tmux window on the server and open its URL (reachable over
  tailscale from the phone). "Send review to Claude": run it with `-sync` and
  `cl send` the review it prints.

## Test plans

Like the wizard skill, but for trying a change. When there's something to try,
Claude gives a handoff to `cl ticket done <key> --test-plan -` on stdin (the
ticket prompt asks for it; `cl ticket testplan --format` shows the format), and
the board keeps it in the ticket. It has up to three parts, each under a `# `
heading:

- `# Verified`: what Claude checked by itself and what it saw. Claude runs
  every check it can (tests, commands, scripts, curl, a headless browser, a
  sandbox board) instead of handing it to you. Shown read-only at the top of
  the Test tab ("Checked by Claude") on the first step and on Results.
- `# Test plan`: only what needs you: what Claude can't do (a real browser or
  phone, voice, your accounts, how it feels) and where it wants your
  judgment, plus the step that starts what you'd try it on. Without checks of
  its own, the board adds a last step, "Try it", with the one check "Works
  as expected", so testing still happens and approves the usual way.
- `# Demo` (optional): a guided tour of something new (a feature, UI, a
  command), in its own Demo tab: the same steps and buttons, no checks, no
  results, never gating. Its commands run in `clrun_<key>_d<n>` (`cl t launch
  <key> --demo`).

Without those headings the whole thing is the test plan. In the test plan and
the demo, each `## ` heading is a step:

    ## Start the dev server
    run: npm run dev
    wait: http://localhost:4321
    ## Log in
    open: http://localhost:4321/login
    Sign in as the staging admin.
    ## The hero image
    open: http://localhost:4321/
    - [ ] The hero loads as AVIF

The Test tab walks through it one step at a time (Back, Next, a dot per
step): `run:` is a Run button (the command runs from the ticket's directory in
a hidden tmux session, `clrun_<key>_s<n>`, `cl t launch <key> --step <n>`, its
output under it), `wait:` says whether that local URL answers yet, `open:` is
a button that opens the page in a new tab (the cl window hands it to the
browser), other lines are what to do by hand, and `- [ ]` checks are Pass or
Fail with a note, and each step has a comment box. Nothing runs or opens until
its button is pressed. Results, notes, comments and the step you're on are
saved on the ticket as you go (`test_progress`), so a reload or another device
picks up where you left off; a new plan or submitting starts over. The last
page sums up the checks and comments, step by step. A failure sends them to
Claude for another round. Everything passed with comments offers Send to
Claude (another round) or Pass and finish (the comments stay on the ticket).
Everything passed with nothing to say approves a ticket in Testing; in an
earlier stage the results are only kept. `cl t test <key>` is
the same walk-through in the terminal (it asks before running or opening). A
plan in the older Setup / Launch / Checks shape reads as three steps.

## Phases

1. Store and CLI: vendored SQLite, `cl ticket new|list|needs|show|edit|move|comment|flag|done|rm`,
   `cl project add|set|rm|list`. **Done.**
2. Starting work: worktrees (git and jj), queue dispatcher (`cl t dispatch`,
   and a thread in `cl web`), `CL_TICKET`, the ticket prompt, hooks
   (permission prompt → `input`, turn end clears it), plan mode with an
   optional skill, `approve`, `cleanup`, restarting ended sessions. **Done.**
3. Signals: transcript parsing for questions and permission prompts; flags
   and stage changes from them and from `done`. **Done** (checked against a
   real session: registry `waiting` + `waitingFor`, pending tool_use, menu on
   screen).
4. Web board: Board / Lanes / List, inbox, ticket popup, phone layout, live
   updates (polling every 3 s). **Done.**
5. gutter and test plans: guide check, Open in gutter (relayed over
   tailscale), review back to Claude; test plans (below). **Done.**
6. Answering from the board. **Done**: number keys pick an option (checked
   in a real session), "Type something" takes free text, several questions
   end with Submit.

Desktop app: Chrome or Edge `--app=http://…:8421` first (no code), Electron
or Tauri only if that falls short.
