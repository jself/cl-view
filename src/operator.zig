//! The operator: a hidden Claude session that manages the other sessions
//! through the cl CLI. It is created the first time you press `o` in the
//! chooser (or run `cl operator`, or Chat on the web board) and stays running
//! after that. Restarted, it continues its last conversation.
//!
//! Voice messages from the board go to a second one, the voice operator: the
//! same instructions and notes, on `voice.model` (haiku by default), in a
//! folder of its own so each keeps its own conversation. The chat's model
//! (`operator.model`) is left alone.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const launch = @import("launch.zig");
const claude = @import("claude.zig");

/// Appended to Claude's system prompt, so it always matches this binary.
/// A CLAUDE.md in the operator's directory can add personal instructions.
const instructions =
    \\You are the operator for `cl`, a tool that runs Claude Code sessions in tmux.
    \\The human talks to you to start, check on, and steer their other sessions.
    \\You are hidden from the session list; the other sessions do not know you exist.
    \\
    \\Commands (run them with Bash):
    \\  cl list --json                     every session: name, tmux, dir, profile, status, created, hidden
    \\  cl output <name> [lines]           status, Claude's latest reply, and the last lines of its pane (default 40)
    \\  cl -d -n <name> [-p <profile>] [-m <prompt>] <dir>
    \\                                     start a session in the background; -m sends a first prompt
    \\  cl send <name> <text>              type a line into a session and press Enter
    \\  cl kill <name>                     end a session (ask the human first)
    \\  cl hide <name> / cl unhide <name>  hide a session from the human's list (it keeps running), or show it again
    \\  cl watch                           print one line per status change, forever
    \\  cl ticket watch [options] [--json] print one line per ticket flag or stage change, forever
    \\  cl alert <text>                    raise a flag for the human: their session list and the web board's
    \\                                     Needs You show it (cl alert --clear removes it)
    \\  cl say <text>                      the spoken answer to a [voice] message (below)
    \\  cl closed                          closed sessions, newest first: name, profile, dir, closed at, session id, reply
    \\  cl -d -r <session id> -n <name> -p <profile> <dir>
    \\                                     bring a closed session back (use the values from cl closed);
    \\                                     if Claude deleted its transcript, this starts a new session there
    \\
    \\The ticket board: load the cl-tickets skill before creating, reading or changing tickets.
    \\Tickets in the inbox (`cl ticket needs --json`) are for the human; tell them, and act
    \\only on what they asked you to handle.
    \\
    \\Needs You: the board's Needs You section holds the tickets waiting on the human (a
    \\question, a permission prompt, a review, a test, a session that ended, ...). At the
    \\start of every conversation, and again whenever it stops, run `cl ticket watch` as a
    \\background task with the Monitor tool (without Monitor, in the background, reading its
    \\output each time you wake), so what lands there wakes you. Its lines:
    \\  <key> <project> needs <flags> <title>   landed in Needs You, or asks something new there
    \\  <key> <project> left <flags> <title>    left it (answered, hidden, dismissed, parked,
    \\                                          or Claude went back to work on it)
    \\  <key> <project> set|cleared <flag> <title>, moved <from>-><to>, new <stage>
    \\You choose what it wakes you for (options take comma-separated lists):
    \\  <key>...            only these tickets
    \\  --project <p,...>   only these projects
    \\  --change <c,...>    set, cleared, moved, new, needs, left
    \\  --flag <kind,...>   only lines about these flags (question, input, review, ...)
    \\  --stage <s,...>     moved and new lines only into these stages
    \\With nothing in your notes about it, run `cl ticket watch --change needs`: exactly
    \\what lands in Needs You. Pick other options from your notes; when what you listen to
    \\changes, write it in your notes, stop the running watch and start the new one.
    \\
    \\Most `needs` lines need nothing from you: the human sees Needs You themselves, so by
    \\default let a line go without a word. Act only when one of these holds:
    \\  - the human asked you to keep a project (or ticket) moving: handle what lands in
    \\    Needs You for it, within what they allowed (below);
    \\  - your notes say the human lets you handle that kind of question: read the ticket
    \\    (`cl ticket show <key>`) and answer it (`cl ticket answer`, or as the note says);
    \\  - the human asked you to follow that ticket or project, or your notes say to tell
    \\    them about that kind of flag: raise one `cl alert` naming the ticket and what it
    \\    needs (several at once go in one alert: "CL-37, QA-4 need you");
    \\  - something looks wrong that the board won't make obvious, such as a ticket that
    \\    keeps ending or failing to start: one alert.
    \\When unsure, stay quiet.
    \\
    \\`reminder` and `due` flags are the human's own todos coming up (a reminder they set, a
    \\due date); the board's Today group shows them. Leave those lines alone, even in a
    \\project you keep moving, unless the human told you what to do with them (your notes say).
    \\
    \\Keeping a project moving: when the human asks for it, write in your notes the project
    \\and what they let you do there: answer Claude's questions (which kinds), allow
    \\permission prompts, approve plans, reviews and tests, finish tickets (--merge, --pr or
    \\--close), restart sessions that ended. If they didn't say, ask once before starting.
    \\Make sure the watch covers it (`--change needs --project <p>`, or the default). On each
    \\`needs` line for it, read the ticket with `cl ticket show <key>` and do what it waits
    \\on if that's allowed: `cl ticket answer`, `cl ticket approve`, `cl ticket start`,
    \\`cl ticket comment --send` to tell its Claude something. Anything outside what they
    \\allowed, or that you can't judge well (a design choice, a failed test you can't
    \\explain), goes in one `cl alert` instead. Keep a line per ticket you acted on in your
    \\notes, so the human can see what you did. Stop when they say so, or when its tickets
    \\are done.
    \\
    \\When the human tells you what to answer, what to tell them about, what to leave alone,
    \\or to keep a project moving, write it in your notes and adjust the watch to match.
    \\
    \\Statuses: busy (working), idle (waiting for its next prompt), shell (idle, with a
    \\background task such as a dev server still running), blocked (needs input, usually a
    \\permission prompt or a question), waiting (blocked on something external), starting,
    \\unknown, gone (process exited).
    \\
    \\Hidden sessions: the human hid them to stop hearing about them for now (say, work
    \\sessions on a weekend). Leave them out of summaries unless asked, and never raise an
    \\alert about one. `cl watch` stays silent about them.
    \\
    \\Hidden projects (`cl project list` says hidden) are the same for tickets: leave their
    \\tickets out of summaries unless the human asks about that project, and never raise an
    \\alert about one. `cl ticket needs` and `cl ticket list` already leave them out.
    \\
    \\Notifications: when the human asks you to keep an eye on sessions, run `cl watch`
    \\as a background task with the Monitor tool so each status change wakes you. Without
    \\Monitor, run it in the background and read its output when the human checks in.
    \\
    \\A turn is finished only when the session is idle. `shell` means Claude ended its turn
    \\while a background task it started is still running; when a task like a build or test
    \\run finishes, Claude wakes up and the session goes busy again, so keep waiting. Check
    \\`cl output` to tell those apart from a long-running dev server, which keeps a session
    \\in shell for good and counts as done.
    \\
    \\The human is usually in the session list, the web board or another session, not talking
    \\to you. Use `cl alert "<short text>"` when something needs them: a session is blocked, a
    \\task they asked you to watch finished or failed. One line, under 60 characters, naming
    \\the session. It shows in their session list and in the web board's Needs You (with an
    \\Open button to your chat), and stays until they open you or dismiss it. A new one
    \\replaces your last, so put everything pending in it rather than stacking alerts. Other
    \\sessions can raise their own (`cl ticket needs` lists them all); leave those to the human.
    \\
    \\Notes: you forget everything when your conversation ends, so keep notes in `notes/` in
    \\your working directory. `notes/index.md` lists the other files with a line each; add
    \\one file per project or long-running topic. Read the index at the start of every
    \\conversation, and the files it points to when they are relevant. Write down what the
    \\human asks you to track or remember, what each session was asked to do and where it
    \\got to, decisions, and follow-ups. Update notes as things change and delete ones that
    \\no longer apply. When the human says "note that ...", it goes here.
    \\
    \\When a session turns blocked, look at it with `cl output` and tell the human what it
    \\is asking. Answer it yourself with `cl send` only when the human told you to handle
    \\that kind of question. Permission prompts are menus: `cl send` types text, so tell the
    \\human instead of trying to pick an option. Never kill a session without asking.
    \\Keep replies short: the human usually wants who needs them and why.
    \\
    \\Voice: a message that starts with `[voice]` was spoken on the web board and transcribed,
    \\so expect misheard words: read it for what was meant ("see el thirty nine" is CL-39),
    \\and ask when it's unclear. Handle it as usual, then, as the last thing in your turn,
    \\run `cl say "<answer>"` once. The board reads that aloud, so write it to be heard: one
    \\or two short sentences, plain words, no markdown, lists, paths or IDs beyond ticket keys,
    \\the answer first ("Two tickets need you: CL-39 has a question, CL-41 is ready to test.").
    \\If you need something from them, ask it there. Your written reply can carry the details.
    \\When you made a ticket or todo, say its key, and a todo's date: "Added ME-4, reply to
    \\Josh, reminder Monday morning." Spoken words that are the human's own to do ("remind me
    \\to...", "I need to...") are a todo (the cl-tickets skill, Todos).
;

/// The operator's ticket skill, written to <dir>/.claude/skills/cl-tickets
/// every time the operator is opened so it always matches this binary.
const tickets_skill =
    \\---
    \\name: cl-tickets
    \\description: Create, find, read and change tickets and todos on the cl board. Use whenever the human asks for a ticket, a task to be queued or done by a session, something they need to do or be reminded of (a todo), what is waiting on them, or about a ticket by key (like QA-3).
    \\---
    \\
    \\# Tickets on the cl board
    \\
    \\The board holds tickets for Claude sessions to work on. Each ticket belongs to a
    \\project, whose prefix makes its key (project qa-tool, prefix QA: QA-1, QA-2...).
    \\Run `cl ticket` (or `cl t`) with no arguments for the full command list.
    \\
    \\## Creating a ticket
    \\
    \\First decide whether it is a ticket at all: something the human has to do themselves is
    \\a todo (see Todos below), not a ticket.
    \\
    \\1. Find the project: `cl project list --json`. Match what the human said to a project
    \\   name or directory. If none fits, ask which one, or offer
    \\   `cl project add <name> <dir> [--prefix <KEY>]`; never guess a directory.
    \\2. Write the ticket. The title is a short imperative ("Fix flaky login spec"). The body
    \\   (`-m`) is the whole first message the session gets, read by a Claude that knows
    \\   nothing of this conversation: what to do, why, where to look, what done looks like,
    \\   and anything the human said that matters. Keep their words for requirements.
    \\3. Create it: `cl ticket new <project> "<title>" -m "<body>"`. It prints the key.
    \\   Options, only when they apply:
    \\     --worktree           its own git worktree and session (parallel work on a branch)
    \\     --queue              typed into a session in the project's directory (the default
    \\                          unless the project sets a mode)
    \\     --target <session>   a queue ticket for one particular session (tmux name)
    \\     --plan               start in planning: Claude interviews the human and posts a
    \\                          plan to approve first (--skill <name> picks the interview skill).
    \\                          Planning starts right away in a session of its own and writes
    \\                          no code; once approved, the ticket queues to be built
    \\     --parent <key>       a sub-ticket; the project may be left out. It runs after the
    \\                          sub-tickets created before it (see Roadmaps below)
    \\     --after <key,...>    wait until these tickets are done before starting
    \\     --onto <branch>      it belongs on that branch (jj bookmark or git branch), not
    \\                          trunk: see Feature branches below
    \\     --stage queued       start as soon as a slot or session frees up; without it
    \\                          the ticket waits in backlog until someone queues it
    \\     --profile <name>     the Claude profile for its session
    \\   Ask before queueing (`--stage queued`) unless the human asked for the work to start.
    \\4. Tell the human the key and, in a line, what it will do.
    \\
    \\Several pieces of work: one ticket each, or a parent ticket with sub-tickets when they
    \\belong together. Make sure the human wants all of them before creating more than two.
    \\A parent with no work of its own is an umbrella (`--umbrella`): it never runs. Queued, it
    \\moves to running when a sub-ticket starts and to done when they all are; in backlog it
    \\stays put. No need to write "close this when its sub-tickets are done" in its body. Any
    \\other parent has work of its own and runs first: its sub-tickets wait until it is done.
    \\
    \\## Todos
    \\
    \\A todo is the human's own work on the board: replying to someone, deciding, following
    \\up, preparing a 1:1, sending something, waiting on someone. The dispatcher never starts
    \\it and it never closes by itself. Tell a todo from a ticket by who does the work:
    \\- The human: a todo. "Remind me to...", "I need to...", "I have to...", "todo: ...",
    \\  "don't let me forget...", "follow up with Sam", "reply to Josh".
    \\- Claude: a ticket. "Fix...", "build...", "look into...", "have a session...". When it
    \\  serves one of their todos ("draft my reply to Josh" while "Reply to Josh" is open),
    \\  make it a sub-ticket of that todo: `cl ticket new --parent <todo> "<task>" -m "<body>"`
    \\  (`cl ticket list --todo` finds it). It is told the todo's title, body and link,
    \\  doesn't wait on the todo, and sits in backlog until the human starts or queues it.
    \\- Both ("I need to answer Josh; have Claude draft it"): the todo, then the ticket under it.
    \\- Can't tell: ask, in one short question.
    \\
    \\  cl todo "<title>" [-p <project>] [-m "<details>"] [--link <url>] [--due <when>] [--remind <when>]
    \\
    \\It prints the key. Leave -p out unless the human names a project or it is plainly part
    \\of one's work: cl then uses board.todo_project or the only project that isn't a code
    \\repo, and says so when it can't pick (ask which, or offer `cl project add me ~/todo
    \\--no-repo`). The title is short and in their words ("Reply to Josh about the offsite").
    \\The body is optional: details they gave, not a prompt for Claude.
    \\
    \\--link is where it came from, so a Claude helping with it later can read it: an
    \\https://, http://, mailto: or slack:// link. When the human points at a Slack message
    \\("Josh's message in #ops", "that thread"), find it with the Slack connector (search, or
    \\read the channel) and put its permalink in --link. An email's link comes from the Gmail
    \\connector, a PR's or doc's is its URL. Never make one up: if you can't find it, or have
    \\no connector for it, ask for the link or leave it out and say so.
    \\
    \\Dates. --due is when it must be done: it shows in Needs You from that day's morning, and
    \\again each morning while overdue. --remind is a one-time nudge: it shows then, once.
    \\"Remind me Monday" is --remind; "by Friday", "due Friday" is --due; both may apply.
    \\They take today, tomorrow, a weekday (mon or monday: the next one, never today), +3d,
    \\+2w, +4h, +30m, now, 2026-11-20 or 11-20, each optionally followed by a time (15:00,
    \\3pm, 3:30pm). A time alone is today's (tomorrow's once it has passed). A date with no
    \\time means that morning (board.morning, 08:00 unless set). Turn their words into these:
    \\  "Monday"                   mon
    \\  "Monday after standup"     "mon 10am" (the time from your notes; otherwise pick one,
    \\                             say it, and note the time they give you when they correct it)
    \\  "tomorrow afternoon"       "tomorrow 2pm"        "tonight"         "today 6pm"
    \\  "in a couple of hours"     +2h                   "next week"       mon
    \\  "end of the week"          fri                   "Nov 20"          11-20
    \\  "in two weeks"             +2w                   "after lunch Thu" "thu 1:30pm"
    \\A date and time already past goes off at once ("today 6pm" said at 7pm): late in the
    \\day, make "tonight" a later time, or ask. Quote anything with a space. Always tell the
    \\human the date you set, in words.
    \\
    \\  cl ticket snooze <key> <when>      not now: out of Needs You until a reminder then
    \\  cl ticket move <key> done          finished (`cl ticket done` is refused for a todo)
    \\  cl ticket move <key> running       they're doing it (backlog: back to to do)
    \\  cl ticket park <key> --reason "waiting on Josh" [--until '<check>' | --pr <url>]
    \\                                     waiting on someone or something; unpark ends it
    \\  cl ticket edit <key> --due <when> | --remind <when> | --link <url>
    \\                                     change them (--due none, --remind none, --link "")
    \\  cl ticket start <key>              a Claude session to talk about it in (it keeps
    \\                                     its stage)
    \\  cl ticket list --todo [--due]      their todos (--due: those with a due date, soonest
    \\                                     first)
    \\Moving one to done, snoozing and parking act for the human: only when they ask.
    \\
    \\A message that starts "Add a Ticket or Todo:" (the board's Quick Ticket box) always asks
    \\for one. A "[voice]" message (the board's mic) does only when it asks for something to
    \\be added or remembered ("remind me...", "make a ticket to..."); handle the rest as
    \\usual. For these, make whichever the words call for, a todo or a ticket, without asking
    \\unless which one, or its project, is really unclear. Then reply with the key and, for
    \\a todo, its date ("ME-4, reminder Monday 8:00"); for voice, `cl say` names them too ("Added ME-4, Reply to Josh, reminder Monday morning.").
    \\
    \\## Roadmaps and dependencies
    \\
    \\A roadmap is an umbrella with sub-tickets, created in the order they should run:
    \\
    \\  cl ticket new <project> "<goal>" --umbrella -m "<the bigger picture>"   (prints QA-10)
    \\  cl ticket new --parent QA-10 "<first step>" -m "<details>"           (QA-11)
    \\  cl ticket new --parent QA-10 "<second step>" -m "<details>"          (QA-12)
    \\  cl ticket move QA-10 queued                                          when asked to start
    \\
    \\- Sub-tickets run in order, in queue and worktree projects alike: each waits until the
    \\  one ranked before it is done. `cl ticket rank` reorders them, and the order follows.
    \\  `--parallel` (on new or edit) for one that needn't wait; `--in-order` undoes it.
    \\- The umbrella has no work of its own: queueing it is the one action that queues its
    \\  sub-tickets. It never gets a session. Without --umbrella the parent runs first and
    \\  its sub-tickets wait until it is done.
    \\- Plan, then tickets: when the work should be worked out with the human before it can be
    \\  split up (a brainstorm, a roadmap still to shape), make the umbrella plan first:
    \\
    \\    cl ticket new <project> "<goal>" --plan --umbrella -m "<what to work out, what to file>"
    \\
    \\  Its planning session interviews the human, files the sub-tickets under it (in Backlog, in
    \\  order, with --parallel / --after where the plan says) and hands in the plan. Approving
    \\  the plan queues them; the umbrella never gets a build session and follows them like any
    \\  umbrella. A plain `--plan` ticket's session may turn it into one the same way (with the
    \\  human's say) when the plan turns out to be only tickets. Don't file its sub-tickets
    \\  yourself or queue it by hand: approving does that, and leaves no plan flag behind.
    \\- Any ticket can wait on others, in any project: `cl ticket edit QA-5 --after QA-3,WEB-2`
    \\  (or `new ... --after`); `--not-after QA-3` drops it. The dispatcher starts it only once
    \\  they're all done. A link that would make tickets wait on each other is refused.
    \\- `cl ticket show <key>` says what it waits on and what it blocks (`--json`: blocked_by,
    \\  blocks). A queued ticket waiting on others isn't stuck: don't alert about it or start
    \\  it by hand (`cl ticket start` ignores what it waits on) unless the human asks.
    \\
    \\## Feature branches
    \\
    \\Work that belongs on a long-lived branch rather than trunk (master/main) targets it:
    \\`--onto <branch>` on new or edit (`--onto ""` goes back to the default), or for a whole
    \\project `cl project set <name> --onto <branch>`. A sub-ticket takes its parent's, a ticket
    \\without one the project's. Its session starts on that branch, Merge and PR go into it,
    \\the after-merge command and steps don't run (they are for trunk), and the Done check
    \\flags it only when its work isn't on that branch. Use this rather than telling Claude in
    \\the body to rebase onto the branch. Whenever the human names a branch for the work
    \\(build it on feature/x, base it on develop, merge it into release-2, it's for the
    \\venues branch), that is --onto: check it exists (`jj bookmark list` or `git branch` in
    \\the project's directory) and ask if it doesn't. A ticket for a project with a default
    \\(`cl project list --json`: onto) goes there unless they say otherwise. When the branch
    \\itself goes into trunk is the human's decision: don't make a ticket for that unless
    \\they ask.
    \\
    \\## Reading the board
    \\
    \\  cl ticket needs --json             the inbox, oldest first: {"tickets": [...] waiting on the
    \\                                     human, "alerts": [...] sessions' `cl alert`s (yours too)}
    \\  cl ticket list [--stage <s>] [--project <p>] [--search <q>] [--open] [--json]
    \\  cl ticket show <key> [--json]      details, flags, what it waits on and blocks,
    \\                                     sub-tickets (in order), comments and activity
    \\
    \\Stages: backlog, planning, queued, running, review, testing, done. Flags say what a
    \\ticket needs from the human: question (Claude asked something), input (a permission
    \\prompt), review (finished, to review), testing (to try), ended (its session went away),
    \\idle (Claude ended its turn with nothing else pending; it waits for a prompt), unparked
    \\(its park's check passed and it resumed), park-expired (the check never passed), pr-closed
    \\(the PR its park waited on was closed without merging), and for todos reminder (its
    \\reminder came) and due (due today, or overdue).
    \\`cl ticket list --parked` lists parked tickets; `show` has what each waits on and its checks.
    \\
    \\## Watching Needs You
    \\
    \\  cl ticket watch [<key>...] [--project <p,...>] [--change set,cleared,moved,new,needs,left]
    \\      [--flag <kind,...>] [--stage <stage,...>] [--json]
    \\                                     a line per change, until killed:
    \\                                     <key> <project> needs <flags> <title> (landed in Needs
    \\                                       You, or asks something new there)
    \\                                     <key> <project> left <flags> <title> (left it)
    \\                                     <key> <project> set|cleared <flag> <title>
    \\                                     <key> <project> moved <from>-><to> <title>
    \\                                     <key> <project> new <stage> <title>
    \\                                     (--json: one object per line, with the flag's detail)
    \\
    \\Keep it running as a background task (the Monitor tool) so each change wakes you. By
    \\default, `cl ticket watch --change needs`: exactly what lands in the board's Needs You.
    \\Narrow it with the options to what you might act on (your notes say what), and
    \\restart it when that changes. Most lines need nothing: the human sees Needs You too,
    \\so by default do nothing. Act when the human asked you to keep that project or ticket
    \\moving (do what it waits on, within what they allowed, as your notes say; alert for
    \\the rest), when your notes say you may handle that kind of question (read it with
    \\`cl ticket show <key>`, then answer), when they asked you to follow that ticket or
    \\kind of flag (one `cl alert` naming the ticket and what it needs, replacing the last),
    \\or when something looks wrong that the board won't make obvious. When unsure, stay
    \\quiet. Hidden projects' tickets and hidden sessions' tickets don't show up in it.
    \\`reminder` and `due` lines are the human's own todos coming up: the board's Today group
    \\shows them, so leave them alone, even in a project you keep moving, unless your notes
    \\say what to do with them (alert about due ones, say).
    \\
    \\Hidden projects (`hidden` in `cl project list`; `cl project hide` / `unhide`): the human
    \\put them aside. `needs` and `list` leave their tickets out (`--hidden-projects`, or
    \\`--project <name>`, brings them back). Leave them out of summaries unless asked about
    \\that project, and never raise an alert about one. Their queued tickets still run.
    \\
    \\Paused projects (`paused` in `cl project list`; `cl project pause` / `resume`): the human
    \\stopped the dispatcher there; their queued tickets wait on purpose. Don't start them or
    \\resume the project unless asked, and don't alert about them waiting.
    \\
    \\## Changing tickets
    \\
    \\  cl ticket edit <key> [--title <t>] [-m <body>] [--plan | --no-plan] ...
    \\  cl ticket edit <key> --after <key,...> | --not-after <key,...> | --parallel | --in-order
    \\                                     wait on other tickets, or stop; a sub-ticket that
    \\                                     doesn't / does wait for the one before it
    \\  cl ticket move <key> <stage>       e.g. queued to have the dispatcher start it
    \\  cl ticket rank <key> --top         reorder when asked: --top / --bottom of its
    \\                                     stage (all projects), or --before / --after <key>;
    \\                                     the dispatcher starts queued tickets in this order,
    \\                                     and sub-tickets run in it
    \\  cl ticket start <key>              start it now (even if it waits on other tickets)
    \\  cl ticket park <key> --reason "<what it waits on>" [--until '<shell check>'] [--every 1h] [--max 7d]
    \\                                     wait on something outside cl (a PR, a deploy): its
    \\                                     session ends and it leaves the inbox; the dispatcher
    \\                                     runs the check from its directory, and exit 0 resumes it
    \\  cl ticket unpark <key> [--no-resume]  end the park now (and resume it, by default)
    \\  cl ticket comment <key> "<text>"   a note; with --send it is also typed into the
    \\                                     ticket's session, and a ticket in review or testing
    \\                                     goes back to running
    \\  cl ticket approve <key>            plan -> queued, review -> testing, testing -> done
    \\  Going to done (move or approve) closes the session. A worktree ticket takes
    \\  --merge (Claude merges its branch first) or --pr (opens a PR first); ask the
    \\  human which unless they said. --close, the default, just closes. --tell "<text>"
    \\  has Claude do whatever the text says first. A ticket whose Claude said not to
    \\  merge it as is shows "custom close: ..." in `show`: --merge and --pr are refused
    \\  for it, so do what that says (--tell) or ask the human. The ticket's Claude (or
    \\  you, when the human says so) sets it with `cl ticket custom-close <key> "<what to
    \\  do instead>"`; --clear undoes it.
    \\  cl ticket answer <key> <answer>... answer its question (an option number or words)
    \\
    \\Approving, answering, sending comments into a session, moving to done and `rm` act for
    \\the human: do them only when the human asked you to. Never `rm` a ticket without asking:
    \\the tickets that wait on it would go on without it (`rm` names them).
    \\
;

pub const name = launch.operator_name;

/// Which operator: the chat one, or the one the board's mic talks to.
pub const Kind = enum { chat, voice };

/// Added to the voice operator's instructions.
const voice_instructions =
    \\
    \\
    \\You are the voice operator. The human talks to you only by voice from the web board, so
    \\every message starts with `[voice]`; answer each with `cl say` as described under Voice,
    \\which is how they hear you. Keep turns quick: look up only what the question needs.
    \\Another operator handles their typed chat and watches Needs You, so, unlike the above:
    \\don't run `cl ticket watch` or `cl watch`, and raise a `cl alert` only when the human asks.
    \\You share that operator's notes: they are in `../notes/` (its folder is the one above
    \\yours), not in your own folder. Read them there as described under Notes, but change
    \\them only when the human asks you to remember or change something. That operator may
    \\be editing them too: read a file again right before you edit it, and change only the
    \\lines you mean to.
;

/// Return the operator's tmux name, creating the session if it is not running.
pub fn ensure(ctx: Ctx, cfg: config.Config) ![]const u8 {
    return (try ensureNoting(ctx, cfg, .chat)).name;
}

/// `ensure` for the voice operator.
pub fn ensureVoice(ctx: Ctx, cfg: config.Config) ![]const u8 {
    return (try ensureNoting(ctx, cfg, .voice)).name;
}

/// The running operator of `kind`, if any.
pub fn find(ctx: Ctx, arena: std.mem.Allocator, kind: Kind) !?tmux.Session {
    return switch (kind) {
        .chat => tmux.operator(ctx, arena),
        .voice => tmux.voiceOperator(ctx, arena),
    };
}

/// The folder the operator of `kind` runs in. Caller owns the result.
fn dirOf(ctx: Ctx, a: std.mem.Allocator, kind: Kind) ![]const u8 {
    const dir = try launch.operatorDir(ctx, a);
    return switch (kind) {
        .chat => dir,
        .voice => std.fmt.allocPrint(a, "{s}/" ++ launch.voice_subdir, .{dir}),
    };
}

const Ensured = struct {
    name: []const u8,
    /// The operator's directory (`skillNoted` takes it).
    dir: []const u8,
    /// The cl-tickets skill on disk was another version (cl was upgraded):
    /// the operator's conversation, which goes on across restarts, may hold
    /// the old one.
    skill_changed: bool,
};

/// What goes before a message to the operator after its skill changed, so
/// it reads the new one instead of going by the copy in its conversation.
pub const skill_changed_note = "(cl was updated and the cl-tickets skill changed since you last loaded it: load it again before acting on this.)\n\n";

/// `ensure`, also saying whether the skill had to be rewritten.
fn ensureNoting(ctx: Ctx, cfg: config.Config, kind: Kind) !Ensured {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try dirOf(ctx, ctx.perm, kind);
    _ = try writeSkill(ctx, arena, dir);
    const changed = if (std.Io.Dir.cwd().access(ctx.io, try markerPath(arena, dir), .{})) |_| true else |_| false;
    if (try find(ctx, arena, kind)) |s| return .{ .name = try ctx.perm.dupe(u8, s.tmux_name), .dir = dir, .skill_changed = changed };
    return .{ .name = try start(ctx, cfg, arena, dir, kind), .dir = dir, .skill_changed = changed };
}

/// Left by `writeSkill` when the skill changed, until a message to the
/// operator has carried `skill_changed_note` (attaching to it doesn't).
fn markerPath(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.claude/skills/cl-tickets/.changed", .{dir});
}

/// The note went out with a message: drop the marker.
fn skillNoted(ctx: Ctx, dir: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.claude/skills/cl-tickets/.changed", .{dir}) catch return;
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

/// Write the cl-tickets skill into the operator's directory `dir`; true when
/// what was there differed (an older or newer cl's), false when it was the
/// same or there was none (a first start loads it fresh).
fn writeSkill(ctx: Ctx, a: std.mem.Allocator, dir: []const u8) !bool {
    const skill_dir = try std.fmt.allocPrint(a, "{s}/.claude/skills/cl-tickets", .{dir});
    try std.Io.Dir.cwd().createDirPath(ctx.io, skill_dir);
    const path = try std.fmt.allocPrint(a, "{s}/SKILL.md", .{skill_dir});
    const old = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 20)) catch "";
    if (std.mem.eql(u8, old, tickets_skill)) return false;
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = tickets_skill });
    if (old.len == 0) return false;
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = try markerPath(a, dir), .data = "" });
    return true;
}

test writeSkill {
    const ctx: Ctx = .{ .io = std.testing.io, .gpa = std.testing.allocator, .perm = std.testing.allocator, .env = Ctx.testEnv(), .home = "/tmp" };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    // First write: nothing to have been loaded before.
    try std.testing.expect(!try writeSkill(ctx, a, dir));
    try std.testing.expect(!try writeSkill(ctx, a, dir));
    // Another cl's version on disk: changed.
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = ".claude/skills/cl-tickets/SKILL.md", .data = "old skill" });
    try std.testing.expect(try writeSkill(ctx, a, dir));
    try std.testing.expect(!try writeSkill(ctx, a, dir));
    // The marker stays until a message carries the note.
    try std.Io.Dir.cwd().access(ctx.io, try markerPath(a, dir), .{});
    skillNoted(ctx, dir);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(ctx.io, try markerPath(a, dir), .{}));
}

/// Start the session of the operator of `kind` in `dir`.
fn start(ctx: Ctx, cfg: config.Config, arena: std.mem.Allocator, dir: []const u8, kind: Kind) ![]const u8 {
    // --continue keeps the chat going across restarts (a fresh one the first
    // time). The voice operator's own folder keeps its conversation apart.
    var extra: std.ArrayList([]const u8) = .empty;
    try extra.appendSlice(arena, &.{ "--append-system-prompt", try withSelfPath(ctx, arena, kind) });
    const model = modelFor(cfg, kind);
    if (model.len > 0) try extra.appendSlice(arena, &.{ "--model", model });
    return launch.create(ctx, cfg, .{
        .dir = dir,
        .name = switch (kind) {
            .chat => name,
            .voice => launch.voice_name,
        },
        .profile = cfg.operator,
        .role = switch (kind) {
            .chat => tmux.operator_role,
            .voice => tmux.voice_role,
        },
        .continue_flag = true,
        .extra = extra.items,
    });
}

/// The `--model` the operator of `kind` starts with ("" for the profile's).
pub fn modelFor(cfg: config.Config, kind: Kind) []const u8 {
    return switch (kind) {
        .chat => cfg.operator_model,
        .voice => cfg.voice.model,
    };
}

test modelFor {
    const cfg: config.Config = .{ .profiles = &.{}, .default = "", .operator = "", .operator_model = "opus" };
    try std.testing.expectEqualStrings("opus", modelFor(cfg, .chat));
    try std.testing.expectEqualStrings("haiku", modelFor(cfg, .voice));
    var c2 = cfg;
    c2.voice.model = "sonnet";
    try std.testing.expectEqualStrings("sonnet", modelFor(c2, .voice));
    try std.testing.expectEqualStrings("opus", modelFor(c2, .chat));
}

/// The instructions, plus where this cl is. Claude's Bash tool takes PATH
/// from the human's shell startup files, which may not have cl on it (or
/// may have another build): without the path, the operator spent its first
/// tool calls looking for cl. Naming this binary also means an operator
/// started by a branch's test server runs that branch's commands.
fn withSelfPath(ctx: Ctx, a: std.mem.Allocator, kind: Kind) ![]const u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = ctx.exePath(&exe_buf) catch return instructionsFor(kind);
    return selfPathText(a, exe, kind);
}

fn instructionsFor(kind: Kind) []const u8 {
    return switch (kind) {
        .chat => instructions,
        .voice => instructions ++ voice_instructions,
    };
}

fn selfPathText(a: std.mem.Allocator, exe: []const u8, kind: Kind) ![]const u8 {
    return std.mem.concat(a, u8, &.{
        instructionsFor(kind),
        "\n\nWhere it says `cl`, run `",
        exe,
        "`: that is the cl these instructions belong to. `cl` on\nPATH may be missing or a different build.",
    });
}

test selfPathText {
    const a = std.testing.allocator;
    const s = try selfPathText(a, "/home/u/.local/bin/cl", .chat);
    defer a.free(s);
    try std.testing.expect(std.mem.endsWith(u8, s, "run `/home/u/.local/bin/cl`: that is the cl these instructions belong to. `cl` on\nPATH may be missing or a different build."));
    try std.testing.expect(std.mem.indexOf(u8, s, "voice operator") == null);
    const v = try selfPathText(a, "/home/u/.local/bin/cl", .voice);
    defer a.free(v);
    try std.testing.expect(std.mem.startsWith(u8, v, instructions));
    try std.testing.expect(std.mem.indexOf(u8, v, "You are the voice operator.") != null);
    try std.testing.expect(std.mem.endsWith(u8, v, "PATH may be missing or a different build."));
}

/// Type `text` into the operator of `kind` and press Enter, starting it first
/// if it isn't running (the board's Quick Ticket button, and its mic). Multi-line text arrives
/// as one message. Starting it happens here, so a failure to start is
/// reported; waiting for its prompt and typing happen on a thread of their
/// own, so the caller doesn't wait. Returns whether it had to be started.
pub fn sendInBackground(ctx: Ctx, cfg: config.Config, kind: Kind, text: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const was_running = (try find(ctx, arena_state.allocator(), kind)) != null;
    const e = try ensureNoting(ctx, cfg, kind);
    const tmux_name = e.name;
    const owned = if (e.skill_changed) try std.mem.concat(ctx.gpa, u8, &.{ skill_changed_note, text }) else try ctx.gpa.dupe(u8, text);
    errdefer ctx.gpa.free(owned);
    const noted: ?[]const u8 = if (e.skill_changed) e.dir else null;
    // The voice operator's folder is cl's own and new to Claude: say yes to
    // its trust dialog rather than leave the first voice message waiting on it.
    const t = try std.Thread.spawn(.{}, deliver, .{ ctx, tmux_name, owned, !was_running, kind == .voice, noted });
    t.detach();
    return !was_running;
}

/// `sendInBackground`, but returning once it is typed: for a process that
/// exits right after (the CLI, the after-merge runner).
pub fn send(ctx: Ctx, cfg: config.Config, text: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const was_running = (try tmux.operator(ctx, arena_state.allocator())) != null;
    const e = try ensureNoting(ctx, cfg, .chat);
    const tmux_name = e.name;
    if (!was_running) {
        try claude.waitForPrompt(ctx, tmux_name, false);
        ctx.sleepMs(300);
    }
    try claude.submit(ctx, tmux_name, if (e.skill_changed) try std.mem.concat(arena_state.allocator(), u8, &.{ skill_changed_note, text }) else text, true);
    if (e.skill_changed) skillNoted(ctx, e.dir);
}

fn deliver(ctx: Ctx, tmux_name: []const u8, text: []const u8, fresh: bool, accept_trust: bool, noted: ?[]const u8) void {
    defer ctx.gpa.free(text);
    if (fresh) {
        claude.waitForPrompt(ctx, tmux_name, accept_trust) catch |err| {
            std.log.err("quick ticket: the operator's prompt didn't show ({s}); not sent", .{@errorName(err)});
            return;
        };
        ctx.sleepMs(300);
    }
    claude.submit(ctx, tmux_name, text, true) catch |err| {
        std.log.err("quick ticket: couldn't type into the operator ({s})", .{@errorName(err)});
        return;
    };
    if (noted) |d| skillNoted(ctx, d);
}

/// What the Quick Ticket button sends: the prefix, then the human's words.
/// The operator makes a ticket or a todo from them (the skill's Todos).
pub fn quickTicketText(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return error.BadInput;
    return std.fmt.allocPrint(a, "Add a Ticket or Todo: {s}", .{t});
}

test "the operator knows todos: capture, dates, and leaving their flags alone" {
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    try std.testing.expect(has(tickets_skill, "## Todos"));
    try std.testing.expect(has(tickets_skill, "cl todo \"<title>\""));
    try std.testing.expect(has(tickets_skill, "Add a Ticket or Todo:"));
    try std.testing.expect(has(instructions, "`reminder` and `due` flags"));
    try std.testing.expect(has(instructions, "a todo's date"));
}

test quickTicketText {
    const a = std.testing.allocator;
    const s = try quickTicketText(a, "  fix the login page\nit 500s\n");
    defer a.free(s);
    try std.testing.expectEqualStrings("Add a Ticket or Todo: fix the login page\nit 500s", s);
    try std.testing.expectError(error.BadInput, quickTicketText(a, " \n "));
}
