//! `cl ticket ...` and `cl project ...`: the board from the command line.
//! Everything the web board can do to tickets is here too, and inside a
//! ticket's session (CL_TICKET set) the key can be left out.
const std = @import("std");
const Ctx = @import("ctx.zig");
const config = @import("config.zig");
const tmux = @import("tmux.zig");
const claude = @import("claude.zig");
const board = @import("board.zig");
const when = @import("when.zig");
const images = @import("images.zig");
const dispatch = @import("dispatch.zig");
const worktree = @import("worktree.zig");
const actions = @import("actions.zig");
const review = @import("review.zig");
const after_merge = @import("after_merge.zig");
const ci = @import("ci.zig");
const autoreview = @import("autoreview.zig");
const park = @import("park.zig");
const drift = @import("drift.zig");
const ticket_watch = @import("ticket_watch.zig");
const alerts = @import("alerts.zig");

pub const ticket_usage =
    \\usage: cl ticket <command>    (cl t for short)
    \\
    \\  new <project> <title> [-m <body>] [--worktree | --queue] [--target <session>]
    \\      [--plan [--skill <name>]] [--stage <stage>] [--profile <name>] [--parent <key>]
    \\      [--after <key,...>] [--parallel] [--umbrella] [--onto <branch>] [--todo] [--link <url>]
    \\      [--due <when>] [--remind <when>]
    \\                              create a ticket; prints its key. With --parent the
    \\                              project may be left out (it's the parent's). Sub-tickets
    \\                              run in order: each waits for the one ranked before it to
    \\                              be done (--parallel: it doesn't), and for their parent to
    \\                              be done unless it's an umbrella. --after: it waits until
    \\                              those tickets (any project) are done.
    \\                              --umbrella: only a container for sub-tickets; it never
    \\                              runs, and queueing it queues them. Queued, it moves to
    \\                              running when a sub-ticket starts and to done when they
    \\                              all are (in backlog it stays put). Any other parent is
    \\                              flagged ready-to-close.
    \\                              --plan --umbrella: plan, then tickets. Its planning
    \\                              session interviews you, files the sub-tickets (in Backlog)
    \\                              and hands in the plan; approving it queues them, and the
    \\                              umbrella follows them as above. A --plan ticket's session
    \\                              may also make it an umbrella this way when the plan turns
    \\                              out to be only tickets.
    \\                              --onto: it targets that branch (jj bookmark or git branch)
    \\                              instead of trunk: it starts from it, and --merge / --pr go
    \\                              into it. Without it a ticket takes its parent's, else the
    \\                              project's (project set --onto). The after-merge command and
    \\                              steps run only for merges into trunk; merging the branch
    \\                              itself into trunk is yours to do
    \\                              --todo: yours, not Claude's work (cl todo for short): the
    \\                              dispatcher never starts it, it never closes by itself, and
    \\                              it's only in backlog (to do), running (doing) or done;
    \\                              waiting on someone is a park. Its sub-tickets are Claude
    \\                              tasks for it: parallel, they don't wait on it, and each
    \\                              is told the todo's title, body and link. Never --plan or
    \\                              --umbrella. --link: where it came from (a Slack message,
    \\                              an email, a PR); any ticket may have one.
    \\                              A todo's --due: flagged due from that day's morning
    \\                              (board.morning, 08:00) or its time, and again each morning
    \\                              while overdue, until done or moved later. --remind: flagged
    \\                              reminder once, then. Both are in Needs You's Today group.
    \\                              <when>: today, tomorrow, mon (the next one), +3d, +2w, +4h,
    \\                              +30m, now, 2026-11-10 or 11-10, each optionally followed by a
    \\                              time (15:00, 3pm); a time alone; none clears
    \\  sub <title> [-m <body>] [options of new]
    \\                              in a ticket's session: a sub-ticket of $CL_TICKET
    \\  list [--stage <s>] [--project <p>] [--flag <f>] [--needs] [--search <q>] [--open]
    \\      [--top] [--parent <key>] [--parked] [--hidden-projects] [--todo | --no-todo] [--due]
    \\                              tickets, newest first (--needs: oldest ask first;
    \\                              --top: no sub-tickets; --parent: its sub-tickets;
    \\                              --todo: only todos, --no-todo: none; --due: todos with
    \\                              a due date, soonest first). A todo with one says when
    \\  needs [--hidden] [--hidden-projects]
    \\                              tickets with a flag, oldest first (the inbox); a ticket
    \\                              whose session is working on it is left out until it stops,
    \\                              and a hidden one until it raises a new flag (--hidden: those).
    \\                              First the sessions' alerts (cl alert), one line each:
    \\                              alert, from (operator or a session), ticket or -, raised
    \\                              (unix s), text. Last, under "today:", todos asking only
    \\                              with a reminder or due date (they show while parked too),
    \\                              with what it says. --json: {"tickets": [...], "alerts": [...]}
    \\                              list and needs leave out hidden projects' tickets (cl project
    \\                              hide) unless --hidden-projects, --project or --parent names them
    \\  watch [<key>...] [--project <p,...>] [--change set,cleared,moved,new,needs,left]
    \\      [--flag <kind,...>] [--stage <stage,...>] [--json]
    \\                              print a line each time a ticket's flags or stage change,
    \\                              until killed: <key> <project> set|cleared <flag> <title>,
    \\                              moved <from>-><to>, or new <stage>; needs <flags> when it
    \\                              lands in Needs You (or asks something new there), left
    \\                              <flags> when it goes. --change needs: just Needs You.
    \\                              The options narrow it
    \\                              (lists are comma-separated; --flag filters flag lines,
    \\                              --stage moved and new lines by the stage they go to).
    \\                              Hidden projects' and hidden sessions' tickets stay quiet
    \\  hide <key> / unhide <key>   keep it out of the inbox (Needs You) without clearing its
    \\                              flags, or bring it back; a new flag brings it back too
    \\  show <key> [--json | --plan] details, flags, what it waits on and blocks, sub-tickets
    \\                              (in order, how many done), comments and activity;
    \\                              --plan: just the plan its planning session handed in
    \\  edit <key> [--title <t>] [-m <body>] [--project <p>] [--worktree | --queue]
    \\      [--target <session>] [--plan | --no-plan] [--skill <name>] [--profile <name>]
    \\      [--after <key,...>] [--not-after <key,...>] [--parallel | --in-order]
    \\      [--umbrella | --no-umbrella] [--onto <branch>] [--todo | --no-todo] [--link <url>]
    \\      [--due <when>] [--remind <when>]
    \\                              --onto "" goes back to the project's target. --after: the
    \\                              dispatcher doesn't start it until those
    \\                              tickets are done (refused if they wait on it already);
    \\                              --not-after drops the link; --parallel / --in-order: a
    \\                              sub-ticket doesn't / does wait for the one before it;
    \\                              --todo makes it yours (see new), --link "" drops the link,
    \\                              --due none / --remind none drop the date
    \\  move <key> <stage> [--spin-off] [--merge | --pr [--then <steps>] | --tell <text> | --close]
    \\                              backlog planning queued running review testing done
    \\                              (done also closes the ticket's session; it's refused while
    \\                              sub-tickets are unfinished, --spin-off makes them top-level;
    \\                              --merge: Claude first merges the ticket's branch, then it goes
    \\                              to done (a jj change cl merges itself; Claude settles
    \\                              conflicts); --close, the default, and tickets without a branch
    \\                              of their own go straight there; --pr: Claude opens a PR, and
    \\                              the ticket stays in its stage parked on it: review comments
    \\                              wake it, the merge moves it to done (see park);
    \\                              --pr --then: what's left once the PR merges, done by a
    \\                              follow-up sub-ticket after the merge (without --then, Claude's
    \\                              suggestion from custom-close --then, if any; "" for none);
    \\                              --tell: Claude first does what <text> says, branch or not;
    \\                              queued or backlog stops one in progress: its session ends as
    \\                              kill does, and queued it restarts and resumes when its turn
    \\                              comes. Refused while another ticket is in progress there.
    \\                              Queued, a parent that never started queues its backlog
    \\                              sub-tickets and waits for them; it has no work of its own)
    \\  rank <key> --before <key> | --after <key> | --top | --bottom
    \\                              reorder: next to another ticket, as dragging its card on
    \\                              the board does, or first or last in its stage across all
    \\                              projects (the board column). The dispatcher starts queued
    \\                              tickets of a project in this order, and sub-tickets run
    \\                              in it (refused if it would contradict an --after link)
    \\  start <key> [--now]         start it now: a worktree and session, or typed into its
    \\                              queue session (--now even if that session is busy); a ticket
    \\                              that ran before (killed, or its session ended) restarts,
    \\                              resuming its conversation where Claude still has it. A
    \\                              todo gets a session of its own to talk about it in (Talk
    \\                              to Claude), and stays in its stage
    \\  kill <key>                  end its session, as cl kill does; it keeps its stage, raises
    \\                              no flag, and waits for start to restart it. A queue
    \\                              project's session is shared: other tickets on it let go too
    \\  attach <key> <session>      make a running cl session (cl name or tmux name) the ticket's,
    \\                              as if cl had started it there: its status, flags and Needs You
    \\                              follow it. An idle Claude restarts, resuming its conversation,
    \\                              with the ticket's hooks and told the ticket; a busy one is only
    \\                              recorded (attach again once it is idle). Backlog or queued, it
    \\                              moves to running. With no jj change of its own it takes the
    \\                              session's unclaimed working-copy change. Refused if the session
    \\                              is outside its project or another unfinished ticket's, or the
    \\                              ticket has a live session of its own
    \\  park [<key>] --reason <text> [--until <shell command> | --pr <url | #n>] [--every <interval>]
    \\      [--max <time>]
    \\                              wait on something outside cl (a PR review, a deploy): end its
    \\                              session as kill does and keep it out of the inbox. With --until
    \\                              the dispatcher runs the command from the ticket's directory
    \\                              every --every (default 1h; 90s 30m 1h 1d 1w); exit 0 wakes it:
    \\                              flagged unparked, and its session resumes, told so. No pass
    \\                              within --max (default 7d): flagged park-expired, not resumed.
    \\                              --pr: cl writes the check (gh pr view): merged wakes it, closed
    \\                              without merging ends the park, flagged pr-closed. #n is a PR of
    \\                              the ticket's origin remote; --reason defaults to "PR #n: waiting
    \\                              to merge", --max to 14d. A ticket finished with a PR (move
    \\                              --pr) is parked on it so by cl, and its check also wakes it
    \\                              for new reviews or comments from others since the last push,
    \\                              or a failed required check; its round's done parks it on the
    \\                              PR again; the merge moves it to done instead of resuming it.
    \\                              The dispatcher never starts a parked ticket, even in Queued
    \\  snooze <key> <when>          a todo: remind you then (see new's --due for <when>), and
    \\                              out of Needs You until then: its reminder goes, and its due
    \\                              flag hides until the reminder or the next morning
    \\  unpark <key> [--no-resume]   end the park now and resume its session (--no-resume: just
    \\                              end it; the session stays stopped)
    \\  rebase <key>                its change will conflict with its target (the dispatcher test-
    \\                              rebases open tickets' changes as trunk moves; show says so): ask
    \\                              its Claude to rebase onto it and settle the conflicts. Only into
    \\                              an idle session on that ticket; review/testing go back to running
    \\  approve <key> [--spin-off] [--merge | --pr [--then <steps>] | --tell <text> | --close]
    \\                              plan → queued (a new session builds it, told the plan;
    \\                              an umbrella's sub-tickets queue instead), review → testing,
    \\                              testing → done. Leaving planning any way (approve, move)
    \\                              clears the plan's review flag
    \\  answer <key> <answer>...    answer the question (one per question: an option number or
    \\                              your own words) or permission prompt (a number) it waits on;
    \\                              a multi-select question takes several numbers, maybe then
    \\                              your own words: "1,3", "1 3", "2,4,something else" or
    \\                              "1;2 more" (after ";" it's all your own words); a lone one
    \\                              also takes them as separate answers: answer <key> 1 3
    \\  key <key> esc|interrupt|enter|up|down
    \\                              press a key in its session
    \\  gutter <key> [--stop]       review its changes in gutter's window (with Claude's review
    \\                              guide); the review you submit there goes to its session
    \\  autoreview <key> [--stop | --send]
    \\                              automated review: a separate Claude (clrv_<key>, the ticket's
    \\                              profile, read-only) reviews its changes and reports findings,
    \\                              kept on the ticket (show, the board's Review tab); nothing
    \\                              goes to the ticket's session until you --send them (that
    \\                              starts another round, as comment --send does). In review or
    \\                              testing; one at a time. --stop: stop it
    \\  autoreview <key> --findings -
    \\                              by hand, for a running review: take these findings (JSON on
    \\                              stdin, as the reviewer writes them) as its result
    \\  testplan <key> [--json]     what Claude handed over: what it verified, the test plan's
    \\                              steps in order, and the demo's
    \\  testplan --format           how to write one (for Claude)
    \\  launch <key> [--demo] [--step <n>] [--stop]
    \\                              run a step's run: command (the first one by default) in tmux
    \\                              session clrun_<key>_s<n> (a demo step's: _d<n>); --stop: that
    \\                              step's, or all, the demo's too
    \\  test <key>                  walk through the test plan here; failures go back to Claude; s at a check stops and sends what you have
    \\  relocate <key> worktree|queue
    \\                              move it to a worktree of its own, or back to the queue; one
    \\                              under way takes its jj change and conversation along and
    \\                              Claude is told it moved (edit --worktree/--queue does this too)
    \\  cleanup <key> [--branch]    remove its worktree (--branch: and the merged branch)
    \\  dispatch [--once]           start queued tickets as slots and sessions free up
    \\                              (cl web runs this too)
    \\  comment <key> <text> [--send] [--as you|claude]
    \\                              --send also types it into the ticket's session; on a
    \\                              ticket in review or testing that starts another round
    \\  flag <key> <kind> [detail]  set a flag (input question review testing, or your own)
    \\  unflag <key> <kind>
    \\  overview [<key>] [--last <text>] [--next <text>]
    \\                              Claude: the board's Overview, a sentence each: what it did
    \\                              last (or "In progress: ..."), and what comes next; "" clears
    \\                              one. Without either, prints them. done sets Last to its --last
    \\                              (else its summary) and clears Next (what's next is then yours)
    \\  custom-close [<key>] <what to do instead> | --clear
    \\                              Claude: this ticket shouldn't be finished the usual way
    \\                              (merged or a PR); the board offers only this instead
    \\  custom-close [<key>] --then <steps>
    \\                              Claude: what's left to do once its PR merges, should it be
    \\                              finished with one (the board's Done dialog offers it, and
    \\                              move --pr takes it); "" drops it. Not a custom close
    \\  done [<key>] [--last <line>] [--summary <text>] [--test-plan <markdown> | -]
    \\                              Claude: finished, nothing more needed; moves to review.
    \\                              --last: the Overview's Last, what it did and where that
    \\                              leaves you ("Made the review changes; ready for review
    \\                              again"); without it, the summary
    \\                              Refused for a todo: it's yours (move it to done)
    \\                              --test-plan (- reads stdin): the handoff, kept in the ticket:
    \\                              # Verified (what Claude checked itself), # Test plan (only
    \\                              what needs you) and # Demo (optional tour); `testplan
    \\                              --format`. Without it an earlier round's stays, "" drops it
    \\  done [<key>] --summary <text> --plan
    \\                              Claude, planning: the plan is ready for approval; the plan
    \\                              (markdown on stdin) is what the session that builds it gets
    \\  done [<key>] --close [--pr-url <url>]
    \\                              Claude: merged or opened the PR it was asked to. Merged: moves
    \\                              to done and closes the session. A PR (--pr-url required): it
    \\                              stays in its stage, parked on the PR (the link becomes a
    \\                              comment), and the session closes until feedback wakes it
    \\  rm <key>                    (refused while it has sub-tickets); tickets that waited
    \\                              on it (--after) go on without it, and it says which
    \\
    \\  list, needs, show and watch take --json. In a ticket's session ($CL_TICKET) the key
    \\  may be left out.
    \\
;

pub const project_usage =
    \\usage: cl project <command>
    \\
    \\  add <name> <dir> [--prefix <KEY>] [--slots <n>] [--planners <n>] [--mode queue|worktree]
    \\      [--profile <name>] [--after-merge <command>] [--after-merge-claude <steps> | none]
    \\      [--review-skill <skill>] [--auto-review off|on|send] [--push-after-merge <remote>]
    \\      [--no-repo]
    \\  set <name> [--name <new>] [--dir <dir>] [--prefix <KEY>] [--slots <n>] [--planners <n>]
    \\      [--mode queue|worktree] [--profile <name>] [--after-merge <command>]
    \\      [--after-merge-claude <steps> | none] [--onto <branch>] [--review-skill <skill>]
    \\      [--auto-review off|on|send] [--push-after-merge <remote>] [--no-repo | --repo]
    \\  rm <name>                   (refused while it has tickets)
    \\  hide <name> / unhide <name> keep its tickets out of the board's views, Needs You,
    \\                              `cl ticket needs` and `cl ticket list`, or bring them back;
    \\                              only what's shown: its queued tickets still run
    \\  pause <name> | --all [--now]
    \\                              the dispatcher starts nothing new there: queued tickets
    \\                              stay queued in their order, planning waits, and a park
    \\                              whose check passes waits in Queued; what runs finishes.
    \\                              --now also stops its Running tickets and planning sessions
    \\                              (back to Queued or Planning; they resume their conversation)
    \\  resume <name> | --all       start dispatching there again, top of the queue first
    \\  list [--json]
    \\  after-merge <name>          run the after-merge command (and push) now, on trunk as it is
    \\  push <name>                 push trunk to the --push-after-merge remote now and watch its
    \\                              CI, without the after-merge command
    \\
    \\--no-repo: a project that isn't a code repo, for work that isn't about code. add
    \\  makes the directory if it is missing and sets up no jj or git there. Its tickets
    \\  run in the queue only (no worktrees), get no jj change, branch, target branch,
    \\  review guide or automated review, and Done just closes them; it has no --onto,
    \\  --push-after-merge or --after-merge. set --no-repo also sets --mode queue and
    \\  --auto-review off and clears those three (refused while tickets that aren't done
    \\  have a worktree, jj change or branch); --repo makes it a code repo again (jj is
    \\  set up on its next start).
    \\--onto: the branch (jj bookmark or git branch) its tickets start from and merge
    \\  into instead of trunk, like a long-lived feature branch; a ticket's own --onto
    \\  wins. "" (the default): trunk.
    \\--after-merge: a shell command cl runs after it merges a ticket into trunk (not
    \\  into an --onto branch), in a clean checkout of the merged commit (not the
    \\  project's own), detached. It
    \\  gets CL_TICKET, CL_TICKETS, CL_PROJECT, CL_COMMIT, CL_PROJECT_DIR and
    \\  CL_CHECKOUT; output goes to ~/.local/state/cl/after-merge-<name>.log, and a
    \\  failure flags the ticket. "" removes it.
    \\--push-after-merge: the git remote (like origin) cl pushes trunk to after it merges
    \\  a ticket into it, after the --after-merge command, for projects that don't go
    \\  through PRs. Fast-forward only: a remote with commits trunk doesn't have is left
    \\  alone. It then watches the commit's GitHub Actions runs (gh) for up to 3 hours
    \\  and flags the ticket when one fails. "" (the default): no push.
    \\--review-skill: the skill the automated review (cl ticket autoreview) uses
    \\  instead of cl's own instructions; it still reports findings in cl's format.
    \\  "" (the default): cl's own.
    \\--auto-review: run the automated review by itself when a ticket reaches review
    \\  (Claude's `cl ticket done`; only its first time there, not for one without
    \\  changes), so it reaches Needs You with the findings there. send: also send
    \\  what it finds to Claude for one round (like Send findings); the default for
    \\  a new project (off for --no-repo). off: only when you start it. You can
    \\  start one any time either way.
    \\--after-merge-claude: what Claude is asked to do after a merge when there is no
    \\  command (the ticket's Claude, or the operator once its session is gone), and
    \\  what the operator is asked to sort out when the command fails. "" (the
    \\  default): rebuild and restart what runs from the checkout. none: nothing.
    \\
++ std.fmt.comptimePrint("--slots: worktree tickets in progress at once (default {d})\n--planners: planning sessions at once; they don't wait for the queue or a slot (default {d})\n", .{ board.default_slots, board.default_planners });

fn checkRemote(r: ?[]const u8) ?[]const u8 {
    const v = r orelse return null;
    if (v.len > 0 and (v[0] == '-' or std.mem.indexOfAny(u8, v, " \t\n") != null)) fail("--push-after-merge is a git remote's name, like origin (\"\" for none)", .{});
    return v;
}

fn parseAutoReview(args: Args) ?board.AutoReview {
    const v = args.get("--auto-review") orelse return null;
    return board.AutoReview.parse(v) orelse fail("--auto-review is off, on or send", .{});
}

fn out(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), text);
}

fn fail(comptime fmt: []const u8, a: anytype) noreturn {
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "cl: " ++ fmt ++ "\n", a) catch "cl: error\n";
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), msg) catch {};
    std.process.exit(1);
}

/// Positional arguments and --options, in any order. Options listed in
/// `valued` take the next argument as their value; others are switches.
const Args = struct {
    pos: std.ArrayList([]const u8) = .empty,
    opts: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn parse(a: std.mem.Allocator, argv: []const []const u8, valued: []const []const u8, usage: []const u8) !Args {
        var r: Args = .{};
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const s = argv[i];
            if (s.len > 1 and s[0] == '-' and !isNumber(s)) {
                const name = if (std.mem.eql(u8, s, "-m")) "--body" else s;
                const takes = for (valued) |v| {
                    if (std.mem.eql(u8, v, name)) break true;
                } else false;
                if (takes) {
                    i += 1;
                    if (i >= argv.len) fail("{s} needs a value\n{s}", .{ s, usage });
                    try r.opts.put(a, name, argv[i]);
                } else try r.opts.put(a, name, "");
            } else try r.pos.append(a, s);
        }
        return r;
    }

    fn has(self: Args, name: []const u8) bool {
        return self.opts.contains(name);
    }

    fn get(self: Args, name: []const u8) ?[]const u8 {
        return self.opts.get(name);
    }

    /// Fail on any option not in `allowed`.
    fn only(self: Args, allowed: []const []const u8, usage: []const u8) void {
        var it = self.opts.keyIterator();
        while (it.next()) |k| {
            for (allowed) |x| {
                if (std.mem.eql(u8, x, k.*)) break;
            } else fail("unknown option {s}\n{s}", .{ k.*, usage });
        }
    }
};

fn isNumber(s: []const u8) bool {
    _ = std.fmt.parseInt(i64, s, 10) catch return false;
    return true;
}

/// Report a board error and exit.
fn boardFail(db: board.Db, err: anyerror, what: []const u8) noreturn {
    switch (err) {
        error.NotFound => fail("no such {s}", .{what}),
        error.Exists => fail("{s} already exists (or is still in use)", .{what}),
        error.BadInput => fail("invalid {s}", .{what}),
        error.NoSession => fail("its session isn't running, so Claude can't finish it; use --close", .{}),
        error.CustomClose => fail("Claude asked to close it its own way (see custom close in `cl ticket show`); use --tell, or --close, or clear it with `cl ticket custom-close <key> --clear`", .{}),
        error.OpenSubtickets => fail("it has sub-tickets that aren't done yet; finish them, or make them tickets of their own with `cl ticket move <key> done --spin-off`", .{}),
        error.Conflicts => fail("merging it back conflicts (see `cl ticket show`); resolve them in its change, then try again", .{}),
        error.MergeFailed => fail("jj couldn't merge it: {s}", .{worktree.lastError()}),
        error.SharedSession => fail("another ticket is in progress in its session (a shared queue session, or its parent's), so it can't be stopped without cutting that one off; move or finish that ticket first, or end the session for both with `cl ticket kill`", .{}),
        error.Starting => fail("it is starting right now; try again in a moment", .{}),
        error.NoRepo => fail("its project isn't a code repo (cl project add/set --no-repo): no worktrees, target branches, automated reviews, push or after-merge command there; its tickets run in the queue", .{}),
        error.RepoWork => fail("tickets that aren't done have work in the repo (a worktree, jj change or branch): finish them, or move them to the queue with nothing under way, first", .{}),
        error.Todo => fail("{s}", .{board.todo_refused}),
        error.Sqlite => fail("board database: {s}", .{db.message()}),
        else => fail("{s}: {s}", .{ what, @errorName(err) }),
    }
}

fn openBoard(ctx: Ctx, cfg: config.Config) board.Db {
    return board.open(ctx, cfg) catch |err| switch (err) {
        error.Sqlite => fail("cannot open the board database", .{}),
        else => fail("cannot open the board database: {s}", .{@errorName(err)}),
    };
}

fn parseStage(s: []const u8) board.Stage {
    return board.Stage.parse(s) orelse fail("no such stage: {s} (backlog planning queued running review testing done)", .{s});
}

/// Move a ticket to `to` (see `dispatch.relocate`) and say where it went.
fn relocate(ctx: Ctx, cfg: config.Config, db: board.Db, a: std.mem.Allocator, key: []const u8, to: board.Mode) !void {
    const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
    const r = dispatch.relocate(ctx, cfg, db, a, t, to) catch |e| switch (e) {
        error.Busy => fail("{s}: Claude is working in its session or waiting on you; move it once it is idle", .{t.key}),
        error.NoChange => fail("{s} is under way, but its work has no jj change of its own to move with it", .{t.key}),
        error.WorktreeFailed => fail("jj: {s}", .{worktree.lastError()}),
        error.SessionFailed => fail("cannot start the session: {s}", .{dispatch.failureReason(e)}),
        else => boardFail(db, e, "ticket"),
    };
    const after = board.getTicket(db, a, t.key) catch |e| boardFail(db, e, "ticket");
    return out(switch (r) {
        .mode => try std.fmt.allocPrint(a, "{s} runs {s} when it starts\n", .{ t.key, if (to == .worktree) "in a worktree of its own" else "in the queue" }),
        .moved => try std.fmt.allocPrint(a, "{s} moved to {s}{s}{s}\n", .{ t.key, after.tmux, if (after.worktree.len > 0) " at " else "", try ctx.shortenHomeIn(a, after.worktree) }),
        .started => try std.fmt.allocPrint(a, "{s} started in a worktree of its own: {s} at {s}\n", .{ t.key, after.tmux, try ctx.shortenHomeIn(a, after.worktree) }),
        .waiting => try std.fmt.allocPrint(a, "{s} waits in Queued for {s}\n", .{ t.key, if (to == .worktree) "a worktree slot (the project's are all taken)" else "the project's session" }),
    });
}

fn parseMode(args: Args) ?board.Mode {
    if (args.has("--worktree") and args.has("--queue")) fail("--worktree or --queue, not both", .{});
    if (args.has("--worktree")) return .worktree;
    if (args.has("--queue")) return .queue;
    return null;
}

fn parseSlots(args: Args) ?i64 {
    return parseCount(args, "--slots");
}

fn parseCount(args: Args, comptime opt: []const u8) ?i64 {
    const s = args.get(opt) orelse return null;
    const n = std.fmt.parseInt(i64, s, 10) catch fail("not a number: {s}", .{s});
    if (n < 1) fail(opt ++ " must be at least 1", .{});
    return n;
}

/// All of stdin (`what` names it in the error).
fn readStdin(ctx: Ctx, a: std.mem.Allocator, what: []const u8) []const u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(ctx.io, &buf);
    return r.interface.allocRemaining(a, .limited(256 * 1024)) catch fail("cannot read {s} from stdin", .{what});
}

// ---- projects ----

pub fn projectMain(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len == 0) return out(project_usage);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = argv[0];
    const args = try Args.parse(a, argv[1..], &.{ "--prefix", "--slots", "--planners", "--mode", "--profile", "--name", "--dir", "--after-merge", "--after-merge-claude", "--onto", "--review-skill", "--auto-review", "--push-after-merge" }, project_usage);
    const db = openBoard(ctx, cfg);
    defer db.close();

    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        args.only(&.{"--json"}, project_usage);
        const ps = board.listProjects(db, a) catch |e| boardFail(db, e, "project");
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(ps, .{})}));
        var aw: std.Io.Writer.Allocating = .init(a);
        for (ps) |p| try aw.writer.print("{s}\t{s}\t{s}\tslots {d}\tplanners {d}\t{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}\n", .{
            p.name, p.prefix, try ctx.shortenHomeIn(a, p.dir), p.slots, p.planners, @tagName(p.mode),
            if (p.repo) "" else "\tno repo",
            if (p.onto.len > 0) "\tonto " else "", p.onto,
            if (p.hidden) "\thidden" else "",
            if (p.paused) "\tpaused" else "",
            if (p.profile.len > 0) "\t" else "", p.profile,
            if (p.after_merge.len > 0) "\tafter merge: " else "", p.after_merge,
            if (p.after_merge_claude.len > 0) "\tclaude after merge: " else "", p.after_merge_claude,
            if (p.review_skill.len > 0) "\treview skill: " else "", p.review_skill,
            if (p.auto_review != .off) "\tauto review: " else "", if (p.auto_review != .off) @tagName(p.auto_review) else "",
            if (p.push_after_merge.len > 0) "\tpush after merge: " else "", p.push_after_merge,
        });
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "add")) {
        args.only(&.{ "--prefix", "--slots", "--planners", "--mode", "--profile", "--after-merge", "--after-merge-claude", "--onto", "--review-skill", "--auto-review", "--push-after-merge", "--no-repo" }, project_usage);
        if (args.pos.items.len != 2) fail("usage: cl project add <name> <dir> [options]", .{});
        const repo = !args.has("--no-repo");
        var in: board.ProjectInput = .{
            .name = args.pos.items[0],
            .dir = "",
            .prefix = args.get("--prefix"),
            .slots = parseSlots(args),
            .planners = parseCount(args, "--planners"),
            .mode = if (args.get("--mode")) |m| board.Mode.parse(m) orelse fail("--mode is queue or worktree", .{}) else null,
            .profile = args.get("--profile"),
            .after_merge = args.get("--after-merge"),
            .after_merge_claude = args.get("--after-merge-claude"),
            .onto = args.get("--onto"),
            .review_skill = args.get("--review-skill"),
            .auto_review = parseAutoReview(args),
            .push_after_merge = checkRemote(args.get("--push-after-merge")),
            .repo = repo,
        };
        // Everything checked before a directory is made for it.
        try checkProfile(cfg, args.get("--profile"));
        board.checkNewProject(db, in) catch |e| boardFail(db, e, "project (name or prefix)");
        if (!repo) {
            // Its directory may not exist yet: a place for notes, not a checkout.
            const expanded = try ctx.expandHome(args.pos.items[1]);
            defer ctx.gpa.free(expanded);
            std.Io.Dir.cwd().createDirPath(ctx.io, expanded) catch |e| fail("cannot create {s}: {s}", .{ args.pos.items[1], @errorName(e) });
        }
        in.dir = try realDir(ctx, a, args.pos.items[1]);
        if (repo) checkOnto(ctx, a, in.dir, args.get("--onto"));
        board.addProject(db, in) catch |e| boardFail(db, e, "project (name or prefix)");
        const p = board.getProject(db, a, args.pos.items[0]) catch |e| boardFail(db, e, "project");
        const jj = repo and worktree.ensureJj(ctx, a, in.dir);
        return out(try std.fmt.allocPrint(a, "{s}: tickets are {s}-1, {s}-2, ...{s}\n", .{ p.name, p.prefix, p.prefix, if (jj) "\n(set up jj alongside git: jj git init --colocate)" else "" }));
    }
    if (std.mem.eql(u8, cmd, "set")) {
        args.only(&.{ "--prefix", "--slots", "--planners", "--mode", "--profile", "--name", "--dir", "--after-merge", "--after-merge-claude", "--onto", "--review-skill", "--auto-review", "--push-after-merge", "--no-repo", "--repo" }, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project set <name> [options]", .{});
        if (args.has("--no-repo") and args.has("--repo")) fail("--no-repo or --repo, not both", .{});
        try checkProfile(cfg, args.get("--profile"));
        if (args.get("--onto") != null) {
            const cur = board.getProject(db, a, args.pos.items[0]) catch |e| boardFail(db, e, "project");
            // Repo-less, updateProject refuses it: no repo to look the branch up in.
            if ((cur.repo and !args.has("--no-repo")) or args.has("--repo")) checkOnto(ctx, a, cur.dir, args.get("--onto"));
        }
        board.updateProject(db, args.pos.items[0], .{
            .name = args.get("--name") orelse "",
            .dir = if (args.get("--dir")) |d| try realDir(ctx, a, d) else "",
            .prefix = args.get("--prefix"),
            .slots = parseSlots(args),
            .planners = parseCount(args, "--planners"),
            .mode = if (args.get("--mode")) |m| board.Mode.parse(m) orelse fail("--mode is queue or worktree", .{}) else null,
            .profile = args.get("--profile"),
            .after_merge = args.get("--after-merge"),
            .after_merge_claude = args.get("--after-merge-claude"),
            .onto = args.get("--onto"),
            .review_skill = args.get("--review-skill"),
            .auto_review = parseAutoReview(args),
            .push_after_merge = checkRemote(args.get("--push-after-merge")),
            .repo = if (args.has("--no-repo")) false else if (args.has("--repo")) true else null,
        }) catch |e| boardFail(db, e, "project (name or prefix)");
        return;
    }
    if (std.mem.eql(u8, cmd, "after-merge")) {
        args.only(&.{"--run"}, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project after-merge <name>", .{});
        const name = args.pos.items[0];
        // --run: the detached runner cl starts (see after_merge.zig).
        if (args.has("--run")) return after_merge.runLoop(ctx, cfg, db, name);
        const p = board.getProject(db, a, name) catch |e| boardFail(db, e, "project");
        if (!after_merge.runs(p)) fail("{s} has no after-merge command and doesn't push (cl project set {s} --after-merge <command>, or --push-after-merge <remote>)", .{ name, name });
        after_merge.startByHand(ctx, db, name, "-") catch |e| boardFail(db, e, "project");
        return out(try std.fmt.allocPrint(a, "{s}: after-merge run started; log: {s}\n", .{ name, try ctx.shortenHomeIn(a, try after_merge.logPath(ctx, a, cfg, name)) }));
    }
    if (std.mem.eql(u8, cmd, "push")) {
        args.only(&.{}, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project push <name>", .{});
        const name = args.pos.items[0];
        ci.pushByHand(ctx, cfg, db, a, name) catch |e| switch (e) {
            error.NoPush => fail("{s} doesn't push after a merge (cl project set {s} --push-after-merge <remote>)", .{ name, name }),
            else => boardFail(db, e, "project"),
        };
        return out(try std.fmt.allocPrint(a, "{s}: push tried; how it went (and later its CI) is in {s} and on the ticket\n", .{ name, try ctx.shortenHomeIn(a, try ci.logPath(ctx, a, cfg, name)) }));
    }
    // The CI watcher a push after a merge starts (see ci.zig):
    // `ci-watch <name> <commit> [<ticket>...]`.
    if (std.mem.eql(u8, cmd, "ci-watch")) {
        args.only(&.{}, project_usage);
        if (args.pos.items.len < 2) fail("usage: cl project ci-watch <name> <commit> [<ticket>...]", .{});
        return ci.watch(ctx, cfg, db, args.pos.items[0], args.pos.items[1], args.pos.items[2..], .{});
    }
    if (std.mem.eql(u8, cmd, "pause") or std.mem.eql(u8, cmd, "resume")) {
        const pause = std.mem.eql(u8, cmd, "pause");
        args.only(if (pause) &.{ "--all", "--now" } else &.{"--all"}, project_usage);
        const all = args.has("--all");
        if (all == (args.pos.items.len == 1) or args.pos.items.len > 1) fail("usage: cl project {s} <name> | --all{s}", .{ cmd, if (pause) " [--now]" else "" });
        var names: []const []const u8 = undefined;
        if (all) {
            board.setAllPaused(db, pause) catch |e| boardFail(db, e, "project");
            var list: std.ArrayList([]const u8) = .empty;
            for (board.listProjects(db, a) catch |e| boardFail(db, e, "project")) |p| try list.append(a, p.name);
            names = list.items;
        } else {
            board.setProjectPaused(db, args.pos.items[0], pause) catch |e| boardFail(db, e, "project");
            names = args.pos.items;
        }
        var aw: std.Io.Writer.Allocating = .init(a);
        const which = if (all) "every project" else names[0];
        if (!pause) {
            try aw.writer.print("{s} resumed: the dispatcher starts its queued tickets again\n", .{which});
            return out(aw.writer.buffered());
        }
        try aw.writer.print("{s} paused: the dispatcher starts nothing new there; queued tickets keep their place\n", .{which});
        if (args.has("--now")) {
            for (names) |name| {
                const r = dispatch.interrupt(ctx, cfg, db, a, name) catch |e| fail("{s}: couldn't stop what runs: {s}", .{ name, @errorName(e) });
                for (r.queued) |k| try aw.writer.print("{s} stopped and back in Queued; it resumes its conversation when {s} resumes\n", .{ k, name });
                for (r.planning) |k| try aw.writer.print("{s}'s planning session stopped; planning resumes when {s} resumes\n", .{ k, name });
                for (r.left) |k| try aw.writer.print("{s} left running: its session is shared or still starting (move it to Queued once it can stop)\n", .{k});
            }
        } else {
            var running: usize = 0;
            for (names) |name| running += if (board.listTickets(db, a, .{ .project = name, .stage = .running })) |ts| ts.len else |_| 0;
            if (running > 0) try aw.writer.print("{d} running ticket{s} go{s} on to the end of {s} work (--now stops {s})\n", .{ running, if (running == 1) "" else "s", if (running == 1) "es" else "", if (running == 1) "its" else "their", if (running == 1) "it" else "them" });
        }
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "hide") or std.mem.eql(u8, cmd, "unhide")) {
        args.only(&.{}, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project {s} <name>", .{cmd});
        board.setProjectHidden(db, args.pos.items[0], std.mem.eql(u8, cmd, "hide")) catch |e| boardFail(db, e, "project");
        return;
    }
    if (std.mem.eql(u8, cmd, "rm")) {
        args.only(&.{}, project_usage);
        if (args.pos.items.len != 1) fail("usage: cl project rm <name>", .{});
        board.removeProject(db, args.pos.items[0]) catch |e| switch (e) {
            error.Exists => fail("{s} still has tickets; remove or move them first", .{args.pos.items[0]}),
            else => boardFail(db, e, "project"),
        };
        return;
    }
    fail("unknown project command: {s}\n{s}", .{ cmd, project_usage });
}

fn realDir(ctx: Ctx, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const expanded = try ctx.expandHome(path);
    defer ctx.gpa.free(expanded);
    return std.Io.Dir.cwd().realPathFileAlloc(ctx.io, expanded, a) catch fail("no such directory: {s}", .{path});
}

fn checkProfile(cfg: config.Config, name: ?[]const u8) !void {
    const n = name orelse return;
    if (n.len > 0 and cfg.find(n) == null) fail("no such profile: {s}", .{n});
}

// ---- todos ----

const todo_usage =
    \\usage: cl todo <title> [-p <project>] [-m <body>] [--link <url>] [--parent <key>]
    \\                [--due <when>] [--remind <when>] [--json]
    \\
    \\A todo of yours on the board (cl ticket new <project> <title> --todo): the dispatcher
    \\never starts it and it never closes by itself. Prints its key. The project is -p, else
    \\board.todo_project in the config, else the only project that isn't a code repo.
    \\Done: cl ticket move <key> done. Waiting on someone: cl ticket park <key> --reason ...
    \\Talk to Claude about it: cl ticket start <key> (a session of its own; it keeps its stage).
    \\A Claude task for it: cl ticket new --parent <key> "<task>".
    \\--due: in Needs You's Today group from that day's morning (board.morning, 08:00) or
    \\time on, and each morning while overdue. --remind: in Today then, once.
    \\Snooze: cl ticket snooze <key> <when>. <when>: today, tomorrow, mon, +3d, +2w, +4h,
    \\+30m, now, 2026-11-10 or 11-10, each optionally followed by a time (15:00, 3pm).
    \\
;

pub fn todoMain(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len == 0) return out(todo_usage);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var expanded: std.ArrayList([]const u8) = .empty;
    for (argv) |s| try expanded.append(a, if (std.mem.eql(u8, s, "-p")) "--project" else s);
    const args = try Args.parse(a, expanded.items, &.{ "--body", "--project", "--link", "--parent", "--due", "--remind" }, todo_usage);
    args.only(&.{ "--body", "--project", "--link", "--parent", "--json", "--due", "--remind" }, todo_usage);
    if (args.pos.items.len != 1) fail("{s}", .{todo_usage});
    const db = openBoard(ctx, cfg);
    defer db.close();
    const parent = args.get("--parent");
    const project = args.get("--project") orelse if (parent != null) "" else try todoProject(db, a, cfg);
    checkLink(args.get("--link"));
    const key = board.createTicket(ctx, db, a, .{
        .project = project,
        .parent = parent,
        .title = args.pos.items[0],
        .body = args.get("--body"),
        .todo = true,
        .link = args.get("--link"),
        .due = parseWhen(ctx, cfg, db, "--due", args.get("--due")),
        .remind = if (parseWhen(ctx, cfg, db, "--remind", args.get("--remind"))) |w| w.at else null,
    }) catch |e| boardFail(db, e, if (parent != null) "parent ticket or project" else "project");
    if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .key = key }, .{})}));
    return out(try std.fmt.allocPrint(a, "{s}\n", .{key}));
}

/// `--due` / `--remind` read (when.parse); null when not given.
fn parseWhen(ctx: Ctx, cfg: config.Config, db: board.Db, opt: []const u8, text: ?[]const u8) ?when.When {
    const t = text orelse return null;
    return when.parse(db, ctx.nowSeconds(), cfg.board.morning, t) catch |e| switch (e) {
        error.BadWhen => fail("{s} {s}: not a date I know. It takes {s}", .{ opt, t, when.forms }),
        else => boardFail(db, e, "date"),
    };
}

/// Said from now, for a todo's dates in `show` and `list`.
fn dueLine(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) ![]const u8 {
    return when.dueText(db, a, ctx.nowSeconds(), .{ .at = t.due_at, .has_time = t.due_time });
}



fn checkLink(link: ?[]const u8) void {
    if (!board.validLink(link orelse "")) fail("--link is a web page (https://...), a mail (mailto:...) or a Slack link (slack://...)", .{});
}

/// The project `cl todo` uses when not given one: board.todo_project, else
/// the only project that isn't a code repo.
fn todoProject(db: board.Db, a: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    if (cfg.board.todo_project.len > 0) return cfg.board.todo_project;
    var only: ?[]const u8 = null;
    for (board.listProjects(db, a) catch |e| boardFail(db, e, "project")) |p| if (!p.repo) {
        if (only != null) fail("which project? pass -p <project>, or set board.todo_project in ~/.config/cl/config (more than one project isn't a code repo)", .{});
        only = p.name;
    };
    return only orelse fail("which project? pass -p <project>, or set board.todo_project in ~/.config/cl/config (a project for todos: cl project add me ~/todo --no-repo)", .{});
}

// ---- tickets ----

pub fn ticketMain(ctx: Ctx, cfg: config.Config, argv: []const []const u8) !void {
    if (argv.len == 0) return out(ticket_usage);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = argv[0];
    const valued = [_][]const u8{
        "--body", "--target", "--stage", "--profile", "--project", "--flag", "--search", "--title", "--as", "--summary", "--test-plan", "--step", "--parent", "--skill", "--pr-url", "--before", "--after", "--tell", "--then",
        "--reason", "--until", "--every", "--max", "--at", "--change", "--not-after", "--onto", "--findings", "--link",
        "--last", "--next",
    };
    // park's --pr names the PR; elsewhere (move, approve) it's a finish.
    // list's --due is a switch (todos with a due date); new's and edit's
    // take a date.
    const listing = std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls") or std.mem.eql(u8, cmd, "needs");
    const args = try Args.parse(a, argv[1..], if (std.mem.eql(u8, cmd, "park")) &(valued ++ [_][]const u8{"--pr"}) else if (listing) &valued else &(valued ++ [_][]const u8{ "--due", "--remind" }), ticket_usage);
    const env_key = ctx.env.get("CL_TICKET");
    const db = openBoard(ctx, cfg);
    defer db.close();
    const pos = args.pos.items;

    if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "sub")) {
        args.only(&.{ "--body", "--worktree", "--queue", "--target", "--plan", "--skill", "--stage", "--profile", "--parent", "--json", "--after", "--parallel", "--umbrella", "--onto", "--todo", "--link", "--due", "--remind" }, ticket_usage);
        if (!args.has("--todo") and (args.get("--due") != null or args.get("--remind") != null)) fail("--due and --remind are for todos: add --todo (or use cl todo)", .{});
        const is_sub = std.mem.eql(u8, cmd, "sub");
        const parent = args.get("--parent") orelse if (is_sub) (env_key orelse fail("cl ticket sub runs in a ticket's session ($CL_TICKET); elsewhere use new --parent <key>", .{})) else null;
        // With a parent, the project is optional: new --parent QA-2 "title".
        const project, const title = if (pos.len == 2) .{ pos[0], pos[1] } else if (pos.len == 1 and parent != null) .{ "", pos[0] } else fail("usage: cl ticket {s}", .{if (is_sub) "sub <title> [options]" else "new <project> <title> [options]"});
        try checkProfile(cfg, args.get("--profile"));
        // Checked first, so a mistyped key doesn't leave a ticket behind.
        for (try ticket_watch.splitList(a, args.get("--after"))) |k| {
            _ = board.getTicket(db, a, k) catch |e| boardFail(db, e, try std.fmt.allocPrint(a, "ticket {s}", .{k}));
        }
        if (args.get("--onto") != null) {
            const pname = if (project.len > 0) project else (board.getTicket(db, a, parent.?) catch |e| boardFail(db, e, "parent ticket")).project;
            checkProjectOnto(ctx, a, board.getProject(db, a, pname) catch |e| boardFail(db, e, "project"), args.get("--onto"));
        }
        checkLink(args.get("--link"));
        const key = board.createTicket(ctx, db, a, .{
            .project = project,
            .parent = parent,
            .title = title,
            .body = args.get("--body"),
            .mode = parseMode(args),
            .target = args.get("--target"),
            .plan = args.has("--plan") or args.has("--skill"),
            .skill = args.get("--skill"),
            .stage = if (args.get("--stage")) |s| parseStage(s) else null,
            .profile = args.get("--profile"),
            .umbrella = args.has("--umbrella"),
            .onto = args.get("--onto"),
            .todo = args.has("--todo"),
            .link = args.get("--link"),
            .due = parseWhen(ctx, cfg, db, "--due", args.get("--due")),
            .remind = if (parseWhen(ctx, cfg, db, "--remind", args.get("--remind"))) |w| w.at else null,
        }) catch |e| boardFail(db, e, if (parent != null) "parent ticket or project" else "project");
        try applyDeps(ctx, db, a, key, args);
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .key = key }, .{})}));
        return out(try std.fmt.allocPrint(a, "{s}\n", .{key}));
    }
    if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls") or std.mem.eql(u8, cmd, "needs")) {
        args.only(&.{ "--stage", "--project", "--flag", "--needs", "--hidden", "--search", "--open", "--top", "--parent", "--parked", "--hidden-projects", "--json", "--todo", "--no-todo", "--due" }, ticket_usage);
        if (args.has("--todo") and args.has("--no-todo")) fail("--todo or --no-todo, not both", .{});
        if (pos.len != 0) fail("{s} takes no arguments\n{s}", .{ cmd, ticket_usage });
        const needs = args.has("--needs") or args.has("--hidden") or std.mem.eql(u8, cmd, "needs");
        // A review whose reviewer died mustn't keep its ticket out of the
        // inbox when cl web (and its sweep) isn't running.
        if (needs) _ = autoreview.checkAll(ctx, db, a) catch {};
        const ts = board.listTickets(db, a, .{
            .stage = if (args.get("--stage")) |s| parseStage(s) else null,
            .project = args.get("--project"),
            .flag = args.get("--flag"),
            .needs = needs,
            .hidden = args.has("--hidden"),
            // Tickets Claude is working on aren't waiting on the human.
            .busy = if (needs) claude.busySessions(ctx, a, cfg) catch &.{} else &.{},
            .search = args.get("--search"),
            .done = !args.has("--open"),
            .top = args.has("--top"),
            .parent = args.get("--parent"),
            .parked = args.has("--parked"),
            .todo = if (args.has("--todo")) true else if (args.has("--no-todo")) false else null,
            .due = args.has("--due"),
            // Hidden projects stay out unless asked for, by name or flag.
            .shown = !args.has("--hidden-projects") and args.get("--project") == null and args.get("--parent") == null,
        }) catch |e| boardFail(db, e, "ticket");
        // `needs` is all of Needs You: the sessions' alerts (cl alert) too.
        const with_alerts = std.mem.eql(u8, cmd, "needs") and for ([_][]const u8{ "--hidden", "--stage", "--project", "--flag", "--search", "--parent", "--parked" }) |o| {
            if (args.has(o)) break false;
        } else true;
        const als: []const alerts.Alert = if (with_alerts) alerts.list(ctx, db, a, args.has("--hidden-projects")) catch &.{} else &.{};
        if (args.has("--json")) {
            if (with_alerts) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .tickets = ts, .alerts = als }, .{})}));
            return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(ts, .{})}));
        }
        var aw: std.Io.Writer.Allocating = .init(a);
        // alert, from, ticket, raised (unix s), text
        for (als) |al| try aw.writer.print("alert\t{s}\t{s}\t{d}\t{s}\n", .{ al.from, if (al.ticket.len > 0) al.ticket else "-", al.at, al.text });
        // key, stage, project, flags, parent, title, then todo, its due
        // date and its park. In needs, the Today group goes last.
        for ([_]bool{ false, true }) |today| {
            var heading = false;
            for (ts) |t| {
                if (needs and board.todayOnly(t) != today) continue;
                if (!needs and today) break;
                if (today and !heading) {
                    try aw.writer.writeAll("today:\n");
                    heading = true;
                }
                const due = if (t.todo and t.due_at != 0 and t.stage != .done) try std.fmt.allocPrint(a, "\t{s}", .{try dueLine(ctx, db, a, t)}) else "";
                const remind = if (today) for (t.flags) |f| {
                    if (std.mem.eql(u8, f.kind, board.flag_reminder)) break try std.fmt.allocPrint(a, "\t{s}", .{f.detail});
                } else "" else "";
                try aw.writer.print("{s}\t{s}\t{s}\t{s}\t{s}\t{s}{s}{s}{s}{s}{s}\n", .{ t.key, @tagName(t.stage), t.project, try flagList(a, t.flags), if (t.parent.len > 0) t.parent else "-", t.title, if (t.todo) "\ttodo" else "", due, remind, if (t.park != null) "\tparked: " else "", if (t.park) |p| p.reason else "" });
            }
        }
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "watch")) {
        args.only(&.{ "--json", "--project", "--change", "--flag", "--stage" }, ticket_usage);
        var changes: std.ArrayList(ticket_watch.Kind) = .empty;
        for (try ticket_watch.splitList(a, args.get("--change"))) |c|
            try changes.append(a, std.meta.stringToEnum(ticket_watch.Kind, c) orelse fail("--change takes set, cleared, moved, new, needs, left (got {s})", .{c}));
        const stages = try ticket_watch.splitList(a, args.get("--stage"));
        for (stages) |st| _ = parseStage(st);
        return ticket_watch.run(ctx, cfg, db, args.has("--json"), .{
            .keys = pos,
            .projects = try ticket_watch.splitList(a, args.get("--project")),
            .changes = changes.items,
            .flags = try ticket_watch.splitList(a, args.get("--flag")),
            .stages = stages,
        });
    }
    if (std.mem.eql(u8, cmd, "show")) {
        args.only(&.{ "--json", "--plan" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket show <key>");
        var t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        if (args.has("--plan")) {
            const md = std.mem.trim(u8, t.plan_md, " \t\r\n");
            if (md.len == 0) fail("{s} has no plan{s}", .{ t.key, if (t.plan) " handed in yet (its summary is under comments in `cl ticket show`)" else "" });
            return out(try std.fmt.allocPrint(a, "{s}\n", .{md}));
        }
        // A review whose reviewer died or ran too long reads as failed.
        if (t.autoreview.len > 0) if (autoreview.check(ctx, db, a, t) catch null) |_| {
            t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        };
        const cs = board.comments(db, a, t.id) catch |e| boardFail(db, e, "ticket");
        const evs = board.events(db, a, t.id) catch |e| boardFail(db, e, "ticket");
        const subs = board.listTickets(db, a, .{ .parent = t.key }) catch |e| boardFail(db, e, "ticket");
        const blocks = board.dependents(db, a, t.id) catch |e| boardFail(db, e, "ticket");
        const dates = try todoDates(ctx, db, a, t);
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .ticket = t, .dates = dates, .blocks = blocks, .subtickets = subs, .comments = cs, .events = evs }, .{})}));
        return out(try showText(ctx, a, t, dates, blocks, subs, cs, evs));
    }
    if (std.mem.eql(u8, cmd, "edit")) {
        args.only(&.{ "--title", "--body", "--project", "--worktree", "--queue", "--target", "--plan", "--no-plan", "--skill", "--profile", "--after", "--not-after", "--parallel", "--in-order", "--umbrella", "--no-umbrella", "--onto", "--todo", "--no-todo", "--link", "--due", "--remind" }, ticket_usage);
        if (args.has("--todo") and args.has("--no-todo")) fail("--todo or --no-todo, not both", .{});
        const key = keyArg(pos, 0, env_key, "cl ticket edit <key> [options]");
        try checkProfile(cfg, args.get("--profile"));
        checkLink(args.get("--link"));
        if (args.has("--todo")) {
            const cur = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
            if (!cur.todo and cur.stage != .done and (cur.tmux.len > 0 or cur.worktree.len > 0 or cur.change.len > 0 or cur.branch.len > 0))
                fail("{s} is Claude's work under way (a session, worktree or jj change), which a todo can't finish; finish or kill it first, or make a new todo", .{cur.key});
        }
        if (args.get("--onto") != null) {
            const cur = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
            checkProjectOnto(ctx, a, board.getProject(db, a, args.get("--project") orelse cur.project) catch |e| boardFail(db, e, "project"), args.get("--onto"));
        }
        const due = parseWhen(ctx, cfg, db, "--due", args.get("--due"));
        const remind = parseWhen(ctx, cfg, db, "--remind", args.get("--remind"));
        if ((due orelse when.When{}).at != 0 or (remind orelse when.When{}).at != 0) {
            const cur = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
            if (args.has("--no-todo") or (!cur.todo and !args.has("--todo"))) fail("--due and --remind are for todos: {s} isn't one (--todo makes it one)", .{cur.key});
        }
        board.updateTicket(ctx, db, a, key, .{
            .project = args.get("--project") orelse "",
            .title = args.get("--title"),
            .body = args.get("--body"),
            .plan = if (args.has("--plan")) true else if (args.has("--no-plan")) false else null,
            .target = args.get("--target"),
            .profile = args.get("--profile"),
            .skill = args.get("--skill"),
            .umbrella = if (args.has("--umbrella")) true else if (args.has("--no-umbrella")) false else null,
            .onto = args.get("--onto"),
            .todo = if (args.has("--todo")) true else if (args.has("--no-todo")) false else null,
            .link = args.get("--link"),
            .due = due,
            .remind = if (remind) |w| w.at else null,
        }) catch |e| boardFail(db, e, "ticket or project");
        try applyDeps(ctx, db, a, key, args);
        if (parseMode(args)) |m| return relocate(ctx, cfg, db, a, key, m);
        return;
    }
    if (std.mem.eql(u8, cmd, "relocate")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 2) fail("usage: cl ticket relocate <key> worktree|queue", .{});
        return relocate(ctx, cfg, db, a, pos[0], board.Mode.parse(pos[1]) orelse fail("worktree or queue", .{}));
    }
    if (std.mem.eql(u8, cmd, "move") or std.mem.eql(u8, cmd, "mv")) {
        args.only(&.{ "--spin-off", "--merge", "--pr", "--then", "--tell", "--close" }, ticket_usage);
        if (pos.len != 2) fail("usage: cl ticket move <key> <stage> [--spin-off] [--merge | --pr [--then <steps>] | --tell <text> | --close]", .{});
        const finish = finishArg(args);
        const stage = parseStage(pos[1]);
        if (args.has("--then") and stage != .done) fail("--then goes with done --pr: the steps for after the PR merges", .{});
        const old = try setThen(ctx, db, a, pos[0], args);
        actions.move(ctx, cfg, db, a, pos[0], stage, args.has("--spin-off"), finish) catch |e| {
            restoreThen(ctx, db, a, pos[0], old);
            boardFail(db, e, "ticket");
        };
        return finishNote(db, a, pos[0]);
    }
    if (std.mem.eql(u8, cmd, "rank")) {
        const usage = "usage: cl ticket rank <key> --before <key> | --after <key> | --top | --bottom";
        args.only(&.{ "--before", "--after", "--top", "--bottom" }, ticket_usage);
        if (pos.len != 1) fail("{s}", .{usage});
        const before = args.get("--before");
        const after = args.get("--after");
        var places: u8 = 0;
        for ([_]bool{ before != null, after != null, args.has("--top"), args.has("--bottom") }) |b| places += @intFromBool(b);
        if (places != 1) fail("give one of --before, --after, --top or --bottom\n{s}", .{usage});
        for ([_]?[]const u8{ pos[0], before, after }) |k| if (k) |key| {
            _ = board.getTicket(db, a, key) catch |e| boardFail(db, e, try std.fmt.allocPrint(a, "ticket {s}", .{key}));
        };
        if (before orelse after) |ref| if (std.mem.eql(u8, ref, pos[0])) fail("can't rank {s} next to itself", .{ref});
        (if (before != null or after != null)
            board.rankTicket(db, a, pos[0], after, before)
        else
            board.rankInStage(db, a, pos[0], args.has("--top"))) catch |e| boardFail(db, e, "ticket");
        return;
    }
    if (std.mem.eql(u8, cmd, "comment")) {
        args.only(&.{ "--send", "--as" }, ticket_usage);
        // One argument inside a ticket's session: just the text.
        const key, const text = if (pos.len == 1 and env_key != null) .{ env_key.?, pos[0] } else if (pos.len == 2) .{ pos[0], pos[1] } else fail("usage: cl ticket comment <key> <text> [--send] [--as you|claude]", .{});
        const author = args.get("--as") orelse (if (env_key != null) "claude" else "you");
        if (!std.mem.eql(u8, author, "you") and !std.mem.eql(u8, author, "claude")) fail("--as is you or claude", .{});
        const r = actions.comment(ctx, db, a, key, author, text, args.has("--send")) catch |e| boardFail(db, e, "ticket or comment");
        if (r.unsent) std.Io.File.stderr().writeStreamingAll(ctx.io, "cl: the ticket has no session yet; saved without sending\n") catch {};
        if (r.sent_back) return out(try std.fmt.allocPrint(a, "{s} is back in running (round {d})\n", .{ key, r.round }));
        return;
    }
    if (std.mem.eql(u8, cmd, "overview")) {
        args.only(&.{ "--last", "--next" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket overview [<key>] [--last <text>] [--next <text>]");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        const last = overviewArg(args.get("--last"));
        const next = overviewArg(args.get("--next"));
        if (last == null and next == null) return out(try overviewText(a, t));
        board.setOverview(ctx, db, t.id, last, next) catch |e| boardFail(db, e, "ticket");
        return;
    }
    if (std.mem.eql(u8, cmd, "custom-close") and args.has("--then")) {
        // Claude's suggestion for after the PR merges, should it be finished
        // with one: the board offers it, and `move done --pr` takes it.
        args.only(&.{"--then"}, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket custom-close [<key>] --then <steps once its PR merges>");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        const text = std.mem.trim(u8, args.get("--then").?, " \t\r\n");
        board.setPrThen(ctx, db, t.id, text) catch |e| boardFail(db, e, "ticket");
        return out(try std.fmt.allocPrint(a, "{s}: {s}\n", .{ t.key, if (text.len == 0) "no steps for after a PR any more" else "if it's finished with a PR, a follow-up ticket does that once the PR merges (the board offers it)" }));
    }
    if (std.mem.eql(u8, cmd, "custom-close")) {
        args.only(&.{"--clear"}, ticket_usage);
        const clear = args.has("--clear");
        const with_key = pos.len == @as(usize, if (clear) 1 else 2);
        const key = if (with_key) pos[0] else (env_key orelse fail("usage: cl ticket custom-close [<key>] <what to do instead> | --clear", .{}));
        const rest = if (with_key) pos[1..] else pos;
        if (clear != (rest.len == 0) or rest.len > 1) fail("usage: cl ticket custom-close [<key>] <what to do instead> | --clear", .{});
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        const text = if (clear) "" else std.mem.trim(u8, rest[0], " \t\r\n");
        if (!clear and text.len == 0) fail("say what to do instead", .{});
        board.setCustomClose(ctx, db, t.id, text) catch |e| boardFail(db, e, "ticket");
        return out(try std.fmt.allocPrint(a, "{s}: {s}\n", .{ t.key, if (clear) "back to the usual finish" else "the board offers only this close instead of merge or PR" }));
    }
    if (std.mem.eql(u8, cmd, "flag") or std.mem.eql(u8, cmd, "unflag")) {
        args.only(&.{}, ticket_usage);
        const setting = std.mem.eql(u8, cmd, "flag");
        // Inside a ticket's session the key may be left out.
        const with_key = pos.len >= 2 and !(env_key != null and setting and pos.len == 2 and isFlagWord(pos[0]) and !looksLikeKey(pos[0]));
        const key = if (with_key) pos[0] else (env_key orelse fail("usage: cl ticket {s} <key> <kind>{s}", .{ cmd, if (setting) " [detail]" else "" }));
        const rest = if (with_key) pos[1..] else pos;
        if (rest.len == 0 or rest.len > @as(usize, if (setting) 2 else 1)) fail("usage: cl ticket {s} <key> <kind>{s}", .{ cmd, if (setting) " [detail]" else "" });
        if (setting) {
            const source = if (env_key != null) "auto" else "manual";
            board.setFlag(ctx, db, a, key, rest[0], source, if (rest.len == 2) rest[1] else "") catch |e| boardFail(db, e, "ticket or flag (lower case letters, digits, -)");
        } else board.clearFlag(ctx, db, a, key, rest[0]) catch |e| boardFail(db, e, "ticket");
        return;
    }
    if (std.mem.eql(u8, cmd, "done")) {
        args.only(&.{ "--summary", "--last", "--test-plan", "--close", "--pr-url", "--plan" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket done [<key>] [--last <line>] [--summary <text>] [--test-plan <markdown> | -] [--plan] [--close [--pr-url <url>]]");
        const t0 = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        if (t0.todo) fail("{s} is a todo: it's yours, and it closes when you move it to Done (`cl ticket move {s} done`)", .{ t0.key, t0.key });
        // The Overview's Last: what Claude did and where that leaves the human, in a line.
        const last = overviewArg(args.get("--last"));
        // While finishing, a plain `done` means the merge or PR is done too.
        if (args.has("--close") or t0.finishing.len > 0) {
            if (t0.finishing.len == 0) fail("{s} isn't finishing (--close is for after a merge or PR the board asked for); use done without it", .{t0.key});
            // Settled conflicts merge first, so a refusal comes before the message.
            const merged_now = actions.mergeSettled(ctx, db, a, t0) catch |e| boardFail(db, e, "ticket");
            // Just merged, with no after-merge command: Claude does the steps first.
            if (merged_now) if (actions.stepsAfterSettled(ctx, db, a, t0) catch |e| boardFail(db, e, "ticket")) |steps| {
                if (args.get("--summary")) |sum| _ = board.addComment(ctx, db, a, key, "claude", sum, false) catch {};
                return out(try std.fmt.allocPrint(a, "{s}: {s}\n", .{ t0.key, steps }));
            };
            const pr_url = args.get("--pr-url") orelse "";
            const on_pr = std.mem.eql(u8, t0.finishing, "pr");
            if (on_pr) {
                if (pr_url.len == 0) fail("{s} is finishing with a PR: give it with --pr-url <url>, so cl can park the ticket on it", .{t0.key});
                _ = park.parsePr(a, pr_url, null) catch fail("--pr-url takes the PR's URL (https://github.com/<owner>/<repo>/pull/<n>): {s}", .{pr_url});
            }
            if (last) |l| if (l.len > 0) board.setOverview(ctx, db, t0.id, l, null) catch |e| boardFail(db, e, "ticket");
            // Printed first: closing kills the session this may be running in.
            if (on_pr)
                try out(try std.fmt.allocPrint(a, "{s}: the PR is open; it stays in {s}, parked on the PR, and its session closes now (its conversation resumes if the PR gets review comments). The merge moves it to Done{s}.\n", .{ t0.key, @tagName(t0.stage), if (std.mem.trim(u8, t0.pr_then, " \t\r\n").len > 0) ", and a follow-up sub-ticket does what's left then" else "" }))
            else
                try out(try std.fmt.allocPrint(a, "{s}: done; its session closes now.\n", .{t0.key}));
            actions.finished(ctx, cfg, db, a, key, args.get("--summary") orelse "", pr_url) catch |e| boardFail(db, e, "ticket");
            return;
        }
        if (args.get("--pr-url") != null) fail("--pr-url goes with --close", .{});
        // A planning session hands its plan in: the session that builds the
        // ticket gets only that.
        if (t0.stage == .planning and !args.has("--plan")) fail("{s} is in planning: give the plan as markdown on stdin with --plan (a heredoc); the session that builds it sees only that", .{t0.key});
        if (t0.stage != .planning and args.has("--plan")) fail("--plan is for a ticket in planning; {s} is in {s}", .{ t0.key, @tagName(t0.stage) });
        var test_plan = args.get("--test-plan");
        if (test_plan != null and std.mem.eql(u8, test_plan.?, "-")) test_plan = readStdin(ctx, a, "the handoff");
        const plan = if (args.has("--plan")) readStdin(ctx, a, "the plan") else null;
        review.done(ctx, db, a, key, args.get("--summary") orelse "", test_plan, plan) catch |e| switch (e) {
            error.BadTestPlan => fail("{s}", .{if (t0.stage == .planning) "a plan being approved has no test plan yet" else "the handoff is empty: give # Verified, # Test plan or # Demo (cl ticket testplan --format), or --test-plan \"\" to drop it"}),
            error.TextOutsideSteps => fail("text under # Test plan or # Demo before its first \"## \" step would be dropped: put it in a step (\"## <title>\", then its lines; cl ticket testplan --format)", .{}),
            error.DemoChecks => fail("a demo has no checks (\"- [ ] ...\"); put them in # Test plan (cl ticket testplan --format)", .{}),
            error.BadPlan => fail("the plan on stdin is empty", .{}),
            else => boardFail(db, e, "ticket"),
        };
        // Its line replaces the summary `done` put in Last.
        if (last) |l| if (l.len > 0) board.setOverview(ctx, db, t0.id, l, null) catch |e| boardFail(db, e, "ticket");
        // Findings sent to it are handled now (before a new review replaces them).
        if (t0.stage != .planning) autoreview.answered(ctx, db, a, key, args.get("--summary") orelse "") catch {};
        // A round on its PR's feedback: back where it waited, parked on the
        // PR again (a push may need a new approval). Its work goes to the
        // PR's reviewers, not through the board's stages (or review) again.
        if (t0.stage != .planning) if (park.reparkOnPr(ctx, db, a, key) catch |e| boardFail(db, e, "ticket")) |_| {
            const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
            // Said first: from inside the session, this process goes with it.
            try out(try std.fmt.allocPrint(a, "{s}: back in {s}, parked on {s} again; its session closes now. New feedback on the PR wakes it again; the merge moves it to Done.\n", .{ t.key, @tagName(t.stage), t.pr_url }));
            actions.stopForPark(ctx, cfg, db, a, key) catch |e| boardFail(db, e, "ticket");
            return;
        };
        // The project reviews what reaches Review by itself (--auto-review).
        const auto: []const u8 = if (t0.stage == .planning) "" else switch (autoreview.startOnReview(ctx, cfg, db, a, key)) {
            .off, .skipped => "",
            .started => |m| if (m == .send)
                "\nAn automated review of your changes runs now. If it finds problems, they're sent to you here for one more round: check them, then finish the same way."
            else
                "\nAn automated review of your changes runs now; the human gets its findings with your work.",
        };
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        // Said when Claude finishes, as that's when it knows: its work has a
        // branch the human will be offered to merge.
        const hint = if (t.stage != .planning and (t.branch.len > 0 or t.change.len > 0) and t.custom_close.len == 0)
            try std.fmt.allocPrint(a, "\nIf its work shouldn't be merged (or made a PR) as it is, say so now: `cl ticket custom-close {s} \"<what to do with it instead>\"`.", .{t.key})
        else
            "";
        return out(try std.fmt.allocPrint(a, "{s}: {s}. The board shows it to the human; nothing more to do.{s}{s}\n", .{
            t.key, if (t.stage == .planning) "plan ready for approval" else "moved to review", auto, hint,
        }));
    }
    if (std.mem.eql(u8, cmd, "rm")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket rm <key>", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        const freed = actions.remove(ctx, db, a, t.key) catch |e| switch (e) {
            error.Exists => fail("{s} has sub-tickets; remove them first", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        images.removeTicket(ctx, a, cfg, t.key);
        var aw: std.Io.Writer.Allocating = .init(a);
        for (freed) |k| try aw.writer.print("{s} no longer waits on {s}\n", .{ k, t.key });
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "start")) {
        args.only(&.{"--now"}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket start <key> [--now]", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        // By hand it starts anyway, as in a paused project; say what it skips.
        // (An umbrella doesn't start at all: error.Umbrella below.)
        if (board.hold(t) == .blocked) std.Io.File.stderr().writeStreamingAll(ctx.io, try std.fmt.allocPrint(a, "cl: {s} waits on {s}, not done yet; starting it anyway\n", .{ t.key, (try board.waitingOn(a, t))[0].key })) catch {};
        dispatch.start(ctx, cfg, db, a, t, args.has("--now")) catch |e| switch (e) {
            error.AlreadyStarted => fail("{s} already has a session: {s}", .{ t.key, t.tmux }),
            error.Umbrella => fail("{s} is an umbrella: its sub-tickets run, not it (`cl ticket edit {s} --no-umbrella` makes it a ticket of its own)", .{ t.key, t.key }),
            error.TodoDone => fail("{s} is a done todo: move it back to backlog (to do) or running (doing) to talk about it", .{t.key}),
            error.TargetBusy => fail("{s}'s session is busy or has another ticket in progress; it waits in Queued (--now types it in anyway)", .{t.key}),
            error.WorktreeFailed => fail("cannot make the worktree: {s}", .{worktree.lastError()}),
            error.SessionFailed => fail("cannot start the session: {s}", .{dispatch.failureReason(e)}),
            else => boardFail(db, e, "ticket"),
        };
        const after = board.getTicket(db, a, t.key) catch |e| boardFail(db, e, "ticket");
        if (after.todo) return out(try std.fmt.allocPrint(a, "{s}: talking to Claude about it in {s} (still {s})\n", .{ after.key, after.tmux, todoStageName(after.stage) }));
        return out(try std.fmt.allocPrint(a, "{s} started in {s}{s}{s}\n", .{
            after.key, after.tmux, if (after.worktree.len > 0) " at " else "", try ctx.shortenHomeIn(a, after.worktree),
        }));
    }
    if (std.mem.eql(u8, cmd, "kill")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket kill <key>", .{});
        const r = actions.kill(ctx, cfg, db, a, pos[0]) catch |e| switch (e) {
            error.NoSession => fail("{s} has no live session", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        var aw: std.Io.Writer.Allocating = .init(a);
        try aw.writer.print("killed {s}; {s} stays in {s}. `cl ticket start {s}` restarts it{s}.\n", .{
            r.session, t.key, @tagName(t.stage), t.key, if (r.resumes) ", resuming its conversation" else "",
        });
        if (r.others.len > 0) try aw.writer.print("it was shared: {s} let go of it too\n", .{try std.mem.join(a, ", ", r.others)});
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "attach")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 2) fail("usage: cl ticket attach <key> <session>", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        const r = dispatch.attach(ctx, cfg, db, a, t, pos[1]) catch |e| switch (e) {
            error.NoSuchSession => fail("no running cl session named {s} (`cl ls --plain` lists them)", .{pos[1]}),
            error.PaneDead => fail("{s}'s pane is dead; there's no Claude there to attach", .{pos[1]}),
            error.OtherProject => fail("{s} runs in {s}, not in {s}'s project {s} ({s})", .{ pos[1], sessionDir(ctx, a, pos[1]), t.key, t.project, projectDir(db, a, t.project) }),
            error.Finished => fail("{s} is done; there's nothing to attach", .{t.key}),
            error.Planning => fail("{s} is being planned; its planning session is cl's own", .{t.key}),
            error.Umbrella => fail("{s} is an umbrella: its sub-tickets run, not it", .{t.key}),
            error.Starting => fail("{s} is starting right now; try again in a moment", .{t.key}),
            error.AlreadyStarted => fail("{s} already has a live session: {s} (`cl ticket kill {s}` ends it)", .{ t.key, t.tmux, t.key }),
            error.SessionTaken => fail("{s} belongs to {s}, which isn't done; finish or move it first", .{ pos[1], takenBy(ctx, db, a, pos[1], t.id) }),
            error.SessionFailed => fail("cannot restart Claude there: {s}", .{dispatch.failureReason(e)}),
            else => boardFail(db, e, "ticket"),
        };
        const after = board.getTicket(db, a, t.key) catch |e| boardFail(db, e, "ticket");
        var aw: std.Io.Writer.Allocating = .init(a);
        try aw.writer.print("{s} attached to {s} ({s})\n", .{ t.key, r.session, @tagName(after.stage) });
        if (r.adopted.len > 0) try aw.writer.print("its jj change is now {s}{s}{s}, the one the session works in\n", .{ r.adopted[0..@min(r.adopted.len, 12)], if (after.branch.len > 0) ", bookmark " else "", after.branch });
        if (r.restarted)
            try aw.writer.print("Claude restarted there with {s}'s hooks, {s}, and was told the ticket\n", .{ t.key, if (r.resumed) "resuming its conversation" else "in a new conversation (its own had nothing in it yet)" })
        else if (r.told)
            try aw.writer.print("it was {s}'s session already, with its hooks, and Claude knows the ticket: nothing to restart\n", .{t.key})
        else if (r.again)
            try aw.writer.print("it was {s}'s session already; Claude {s}, so it was left as it is (try again once it is idle to restart it with the ticket's hooks)\n", .{ t.key, attachStatus(r.status) })
        else
            try aw.writer.print("Claude {s}, so it was left as it is: it has no hooks for {s} and wasn't told the ticket. `cl ticket attach {s} {s}` again once it is idle adds them\n", .{ attachStatus(r.status), t.key, t.key, pos[1] });
        if (after.change.len == 0 and after.branch.len == 0)
            try aw.writer.print("note: {s} has no change or branch of its own (the session's working copy isn't one cl can take: described, in trunk, another ticket's, or not jj), so finishing it only closes it; merge its work yourself\n", .{t.key});
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "park")) {
        args.only(&.{ "--reason", "--until", "--pr", "--every", "--max" }, ticket_usage);
        const usage = "cl ticket park [<key>] --reason <text> [--until <shell command> | --pr <url | #n>] [--every <interval>] [--max <time>]";
        const key = keyArg(pos, 0, env_key, usage);
        const pr = args.get("--pr") orelse "";
        const reason = args.get("--reason") orelse if (pr.len > 0) "" else fail("say what it waits on: --reason <text>\nusage: {s}", .{usage});
        const until = args.get("--until") orelse "";
        if (until.len > 0 and pr.len > 0) fail("give --until or --pr, not both: --pr writes the check itself", .{});
        if (until.len == 0 and pr.len == 0 and (args.has("--every") or args.has("--max"))) fail("--every and --max go with --until or --pr (a check to run)", .{});
        const every = durationArg(args, "--every", park.default_every);
        if (every < 60) fail("--every is at least 1m", .{});
        const max: ?i64 = if (args.has("--max")) durationArg(args, "--max", park.default_max) else null;
        const r = park.park(ctx, db, a, key, .{ .reason = reason, .until = until, .pr = pr, .every = every, .max = max }) catch |e| switch (e) {
            error.Finished => fail("{s} is done; there's nothing to park", .{key}),
            error.BadInput => fail("say what it waits on: --reason <text>", .{}),
            error.BadPr => fail("--pr takes the PR's URL (https://github.com/<owner>/<repo>/pull/<n>), #<n>, or <owner>/<repo>#<n>: {s}", .{pr}),
            error.NoRemote => fail("{s}'s checkout has no GitHub origin remote to find PR {s} in; give the PR's URL", .{ key, pr }),
            else => boardFail(db, e, "ticket"),
        };
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        var aw: std.Io.Writer.Allocating = .init(a);
        try aw.writer.print("{s} parked: {s}\n", .{ t.key, t.park.?.reason });
        // A todo has no session: the wait ends, flagged in Needs You.
        const resumes = if (t.todo) "the wait ends and it shows in Needs You (unparked)" else "its session resumes";
        if (t.park.?.pr.len > 0) {
            try aw.writer.print("The dispatcher (cl web, or cl ticket dispatch) checks {s} now and every {s} for up to {s}: merged, {s}; closed without merging, the park ends with a pr-closed flag.\n", .{ t.park.?.pr, try park.formatDuration(a, every), try park.formatDuration(a, t.park.?.deadline - t.park.?.at), resumes });
        } else if (until.len > 0) {
            try aw.writer.print("The dispatcher (cl web, or cl ticket dispatch) checks it now and every {s} for up to {s}; when the check passes, {s}.\n", .{ try park.formatDuration(a, every), try park.formatDuration(a, t.park.?.deadline - t.park.?.at), resumes });
        } else try aw.writer.print("Nothing checks it: `cl ticket unpark {s}` {s}.\n", .{ t.key, if (t.todo) "ends the wait" else "resumes it" });
        // A todo's talk session isn't stopped (park.park).
        if (t.todo and t.tmux.len > 0 and t.tmux[0] != '(') try aw.writer.print("Its talk session {s} stays open.\n", .{t.tmux});
        if (r.session) |s| {
            try aw.writer.print("Its session {s} closes now{s}.\n", .{ s, if (t.session_id.len == 36) "; its conversation resumes when it wakes" else "" });
            if (r.others.len > 0) try aw.writer.print("It was shared: {s} let go of it too.\n", .{try std.mem.join(a, ", ", r.others)});
        }
        // Said first: from inside the session, this process goes with it.
        try out(aw.writer.buffered());
        park.stopSession(ctx, cfg, db, a, t.key) catch |e| boardFail(db, e, "ticket");
        return;
    }
    if (std.mem.eql(u8, cmd, "rebase")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket rebase <key>", .{});
        const was = (board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket")).stage;
        drift.rebase(ctx, cfg, db, a, pos[0]) catch |e| switch (e) {
            error.NoDrift => fail("{s}'s change doesn't conflict with its target (as of the dispatcher's last check, a minute apart)", .{pos[0]}),
            error.NoSession => fail("{s} has no live session; start it again first", .{pos[0]}),
            error.SessionElsewhere => fail("{s}'s session is on another ticket now; try again once it is back on this one", .{pos[0]}),
            error.Working => fail("Claude is working in {s}'s session or waiting on you; try again once it is idle", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        return out(try std.fmt.allocPrint(a, "{s}: asked Claude to rebase onto {s} and settle the conflicts{s}\n", .{ t.key, if (t.drift) |d| d.onto else "its target", if (was == .review or was == .testing) "; it went back to running" else "" }));
    }
    if (std.mem.eql(u8, cmd, "snooze")) {
        args.only(&.{}, ticket_usage);
        if (pos.len < 2) fail("usage: cl ticket snooze <key> <when>  ({s})", .{when.forms});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        if (!t.todo) fail("{s} isn't a todo: only todos have reminders", .{t.key});
        if (t.stage == .done) fail("{s} is done", .{t.key});
        const text = try std.mem.join(a, " ", pos[1..]);
        const w = parseWhen(ctx, cfg, db, "snooze", text).?;
        if (w.at == 0) fail("snooze until when? ({s})", .{when.forms});
        const said = try when.label(db, a, ctx.nowSeconds(), .{ .at = w.at, .has_time = true });
        board.snooze(ctx, db, a, t.key, w.at, try when.format(db, a, ctx.nowSeconds(), .{ .at = w.at, .has_time = true })) catch |e| boardFail(db, e, "ticket");
        return out(try std.fmt.allocPrint(a, "{s} snoozed: a reminder {s}, and out of Needs You until then\n", .{ t.key, said }));
    }
    if (std.mem.eql(u8, cmd, "unpark")) {
        args.only(&.{"--no-resume"}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket unpark <key> [--no-resume]", .{});
        const r = park.unpark(ctx, cfg, db, a, pos[0], !args.has("--no-resume")) catch |e| switch (e) {
            error.NotParked => fail("{s} isn't parked", .{pos[0]}),
            error.WorktreeFailed => fail("unparked, but its worktree couldn't be made: {s}", .{worktree.lastError()}),
            error.SessionFailed => fail("unparked, but its session didn't start: {s}", .{dispatch.failureReason(e)}),
            else => boardFail(db, e, "ticket"),
        };
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        return out(if (r.resumed) |how| switch (how) {
            .started => try std.fmt.allocPrint(a, "{s} unparked; resumed in {s}\n", .{ t.key, t.tmux }),
            .waiting => try std.fmt.allocPrint(a, "{s} unparked; its session is busy with another ticket, so it waits in Queued and resumes there\n", .{t.key}),
            .running => try std.fmt.allocPrint(a, "{s} unparked; it already has a session ({s})\n", .{ t.key, t.tmux }),
        } else if (t.todo)
            try std.fmt.allocPrint(a, "{s}: done waiting ({s})\n", .{ t.key, if (t.stage == .running) "doing" else "to do" })
        else
            try std.fmt.allocPrint(a, "{s} unparked; its session stays stopped (`cl ticket start {s}` restarts it)\n", .{ t.key, t.key }));
    }
    if (std.mem.eql(u8, cmd, "park-check")) {
        // The dispatcher's detached check (park.zig).
        args.only(&.{"--at"}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket park-check <key> --at <when>", .{});
        const at = std.fmt.parseInt(i64, args.get("--at") orelse fail("--at <when>", .{}), 10) catch fail("--at takes the park's time", .{});
        park.runCheck(ctx, cfg, db, pos[0], at);
        return;
    }
    if (std.mem.eql(u8, cmd, "hide") or std.mem.eql(u8, cmd, "unhide")) {
        args.only(&.{}, ticket_usage);
        const key = keyArg(pos, 0, env_key, try std.fmt.allocPrint(a, "cl ticket {s} <key>", .{cmd}));
        const any = board.hideNeeds(ctx, db, a, key, std.mem.eql(u8, cmd, "hide")) catch |e| boardFail(db, e, "ticket");
        if (!any) fail("{s} has no flag, so it isn't in the inbox", .{key});
        return;
    }
    if (std.mem.eql(u8, cmd, "approve")) {
        args.only(&.{ "--spin-off", "--merge", "--pr", "--then", "--tell", "--close" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket approve <key>");
        if (args.has("--then") and (board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket")).stage != .testing)
            fail("--then goes with approving out of testing (to done) with --pr", .{});
        const old = try setThen(ctx, db, a, key, args);
        _ = actions.approve(ctx, db, a, key, args.has("--spin-off"), finishArg(args)) catch |e| {
            restoreThen(ctx, db, a, key, old);
            switch (e) {
                error.BadInput => fail("only a ticket in planning, review or testing can be approved", .{}),
                error.NoSubtickets => fail("{s}: {s}", .{ key, actions.no_subtickets }),
                else => boardFail(db, e, "ticket"),
            }
        };
        return finishNote(db, a, key);
    }
    if (std.mem.eql(u8, cmd, "answer")) {
        args.only(&.{}, ticket_usage);
        if (pos.len < 2) fail("usage: cl ticket answer <key> <answer>...", .{});
        actions.answer(ctx, cfg, db, a, pos[0], pos[1..]) catch |e| switch (e) {
            error.NoSession => fail("{s} has no live session", .{pos[0]}),
            error.NothingAsked => fail("{s} isn't waiting on a question or permission prompt", .{pos[0]}),
            error.BadAnswer => fail("give one answer per question: an option number or your own words; for a multi-select one, option numbers like 1,3 (permission prompts take a number)", .{}),
            error.NotDelivered => fail("{s}: the answer was typed, but Claude is still waiting on the same thing; check the session", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "key")) {
        args.only(&.{}, ticket_usage);
        if (pos.len != 2) fail("usage: cl ticket key <key> esc|interrupt|enter|up|down", .{});
        const k = std.meta.stringToEnum(actions.Key, pos[1]) orelse fail("keys: esc interrupt enter up down", .{});
        actions.press(ctx, db, a, pos[0], k) catch |e| switch (e) {
            error.NoSession => fail("{s} has no live session", .{pos[0]}),
            else => boardFail(db, e, "ticket"),
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "gutter")) {
        args.only(&.{ "--stop", "--submitted" }, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket gutter <key> [--stop]");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        if (args.has("--stop")) return review.stopGutter(ctx, a, t.key);
        if (args.has("--submitted")) {
            const r = actions.gutterSubmitted(ctx, db, a, t.key) catch |e| switch (e) {
                error.NoReview => fail("no review from gutter for {s}", .{t.key}),
                else => boardFail(db, e, "ticket"),
            };
            if (r.unsent) fail("{s} has no session to send the review to; it is kept as a comment", .{t.key});
            return out(if (r.sent) "Sent the review to the session.\n" else "No comments; nothing sent.\n");
        }
        const port = review.startGutter(ctx, cfg, db, a, t) catch |e| switch (e) {
            error.GutterMissing => fail("{s}", .{review.not_installed}),
            error.NoRepo => fail("{s}'s project isn't a code repo, so there is no diff to review in gutter", .{t.key}),
            else => fail("gutter didn't start", .{}),
        };
        return out(try std.fmt.allocPrint(a, "gutter's window is open (http://127.0.0.1:{d}); the review you submit goes to the session\n", .{port}));
    }
    if (std.mem.eql(u8, cmd, "autoreview")) {
        args.only(&.{ "--stop", "--send", "--findings", "--accept-trust", "--stop-hook" }, ticket_usage);
        // The reviewer has no CL_TICKET; it is told its key.
        const key = keyArg(pos, 0, ctx.env.get("CL_AUTOREVIEW"), "cl ticket autoreview <key> [--stop | --send]");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        if (args.has("--stop")) return autoreview.stop(ctx, db, a, t.key) catch |e| boardFail(db, e, "ticket");
        // Internal: the helper autoreview.start runs, detached.
        if (args.has("--accept-trust")) return autoreview.acceptTrust(ctx, a, t.key);
        // Internal: the reviewer's Stop hook (Claude Code's hook JSON on stdin).
        if (args.has("--stop-hook")) {
            const In = struct { stop_hook_active: bool = false };
            const in = std.json.parseFromSliceLeaky(In, a, readStdin(ctx, a, "the hook's input"), .{ .ignore_unknown_fields = true }) catch In{};
            switch (autoreview.stopHook(ctx, cfg, db, a, t.key, in.stop_hook_active) catch |e| boardFail(db, e, "ticket")) {
                .ignore => return,
                // Claude goes on, told why.
                .retry => |why| return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .decision = "block", .reason = why }, .{})})),
                // Last: it is the session this runs in.
                .done => {
                    actions.afterAutoreview(ctx, db, a, t.key);
                    return autoreview.killSession(ctx, a, t.key) catch {};
                },
                .failed => return autoreview.killSession(ctx, a, t.key) catch {},
            }
        }
        if (args.has("--send")) {
            const r = actions.autoreviewSend(ctx, db, a, t.key) catch |e| switch (e) {
                error.NoFindings => fail("{s} has no automated review findings to send", .{t.key}),
                error.OldFindings => fail("{s}'s automated review findings are from before Claude's last changes; run it again (cl ticket autoreview {s})", .{ t.key, t.key }),
                error.NoSession => fail("{s} has no live session to send them to; start it again first", .{t.key}),
                else => boardFail(db, e, "ticket"),
            };
            return out(if (r.sent_back) try std.fmt.allocPrint(a, "Sent the findings; {s} is back in running (round {d})\n", .{ t.key, r.round }) else "Sent the findings to the session.\n");
        }
        if (args.has("--findings")) {
            const cur = autoreview.load(a, t) orelse fail("{s} has no automated review running", .{t.key});
            if (!std.mem.eql(u8, cur.status, "running")) fail("{s}'s automated review isn't running ({s})", .{ t.key, cur.status });
            const r = autoreview.submit(ctx, db, a, t.key, if (std.mem.eql(u8, args.get("--findings").?, "-")) readStdin(ctx, a, "the findings") else args.get("--findings").?) catch |e| switch (e) {
                error.BadFindings => fail("the findings weren't taken: {s}. Fix the JSON and run this again.", .{autoreview.lastError()}),
                error.NotRunning => fail("{s}'s automated review stopped meanwhile; the findings weren't taken", .{t.key}),
                else => boardFail(db, e, "ticket"),
            };
            try out(try std.fmt.allocPrint(a, "Took {d} finding{s} for {s}; its reviewer is closed.\n", .{ r.findings.len, if (r.findings.len == 1) "" else "s", t.key }));
            actions.afterAutoreview(ctx, db, a, t.key);
            // The review is over. Last: this may run in its session.
            autoreview.killSession(ctx, a, t.key) catch {};
            return;
        }
        tmux.requireServer(ctx);
        const r = autoreview.start(ctx, cfg, db, a, t) catch |e| switch (e) {
            error.NotInReview => fail("{s} is in {s}: only a ticket in review or testing gets an automated review", .{ t.key, @tagName(t.stage) }),
            error.NoChanges => fail("{s} has no changes to review", .{t.key}),
            error.NoRepo => fail("{s}'s project isn't a code repo (cl project set --repo), so there are no changes to review", .{t.key}),
            error.AlreadyRunning => fail("{s}'s automated review is running already (--stop stops it)", .{t.key}),
            error.StartFailed => fail("couldn't start the reviewer: {s}", .{tmux.lastError()}),
            else => boardFail(db, e, "ticket"),
        };
        const name = try autoreview.sessionName(a, t.key);
        return out(try std.fmt.allocPrint(a, "Reviewing {s} in tmux session {s} (profile {s}; tmux attach -t {s} to watch). The findings show on the board and in `cl ticket show {s}`.\n", .{ t.key, name, r.profile, name, t.key }));
    }
    if (std.mem.eql(u8, cmd, "testplan")) {
        args.only(&.{ "--json", "--format" }, ticket_usage);
        if (args.has("--format")) return out(review.format_help);
        const key = keyArg(pos, 0, env_key, "cl ticket testplan <key> [--json] | --format");
        const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
        const plan = review.ticketTestPlan(a, t) orelse fail("{s} has no test plan", .{t.key});
        const demo = review.ticketDemo(a, t);
        if (args.has("--json")) return out(try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .verified = t.verified, .steps = plan.steps, .demo = if (demo) |d| d.steps else &.{} }, .{})}));
        var aw: std.Io.Writer.Allocating = .init(a);
        try printVerified(&aw.writer, t.verified);
        for (plan.steps, 1..) |st, i| try printStep(&aw.writer, st, i, plan.steps.len);
        if (demo) |d| {
            try aw.writer.writeAll("\nDemo\n");
            for (d.steps, 1..) |st, i| try printStep(&aw.writer, st, i, d.steps.len);
        }
        return out(aw.writer.buffered());
    }
    if (std.mem.eql(u8, cmd, "launch")) {
        args.only(&.{ "--stop", "--step", "--demo" }, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket launch <key> [--demo] [--step <n>] [--stop]", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        const step: ?usize = if (args.get("--step")) |v| std.fmt.parseInt(usize, v, 10) catch fail("--step takes a step number", .{}) else null;
        const kind: review.Kind = if (args.has("--demo")) .demo else .test_plan;
        if (args.has("--stop")) return review.stopLaunch(ctx, a, t.key, kind, step);
        const i = review.launch(ctx, db, a, t, kind, step) catch |e| switch (e) {
            error.NoTestPlan => fail("{s} has no test plan", .{t.key}),
            error.NoDemo => fail("{s} has no demo", .{t.key}),
            error.NoLaunch => fail("{s}", .{if (step != null) "that step has no run: command" else if (kind == .demo) "the demo has no run: command" else "the test plan has no run: command"}),
            else => boardFail(db, e, "ticket"),
        };
        const name = try std.fmt.allocPrint(a, "clrun_{s}_{s}{d}", .{ try std.ascii.allocLowerString(a, t.key), if (kind == .demo) "d" else "s", i });
        return out(try std.fmt.allocPrint(a, "step {d} running in tmux session {s} (tmux attach -t {s})\n", .{ i, name, name }));
    }
    if (std.mem.eql(u8, cmd, "test")) {
        args.only(&.{}, ticket_usage);
        const key = keyArg(pos, 0, env_key, "cl ticket test <key>");
        return walkTest(ctx, db, a, key);
    }
    if (std.mem.eql(u8, cmd, "cleanup")) {
        args.only(&.{"--branch"}, ticket_usage);
        if (pos.len != 1) fail("usage: cl ticket cleanup <key> [--branch]", .{});
        const t = board.getTicket(db, a, pos[0]) catch |e| boardFail(db, e, "ticket");
        if (t.worktree.len == 0) fail("{s} has no worktree", .{t.key});
        const p = board.getProject(db, a, t.project) catch |e| boardFail(db, e, "project");
        worktree.remove(ctx, a, p.dir, .{ .path = t.worktree, .branch = t.branch }, args.has("--branch")) catch
            fail("cannot remove the worktree: {s}", .{worktree.lastError()});
        board.setSession(ctx, db, t.id, t.tmux, t.session_id, "", if (args.has("--branch")) "" else t.branch) catch |e| boardFail(db, e, "ticket");
        board.logEvent(ctx, db, t.id, "worktree removed", t.worktree) catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "dispatch")) {
        args.only(&.{"--once"}, ticket_usage);
        tmux.requireServer(ctx);
        if (args.has("--once")) {
            const n = dispatch.tick(ctx, cfg, db) catch |e| boardFail(db, e, "ticket");
            drift.once(ctx, cfg);
            return out(try std.fmt.allocPrint(a, "started {d}\n", .{n}));
        }
        dispatch.loop(ctx, cfg, &logLine);
        return;
    }
    if (std.mem.eql(u8, cmd, "hook")) {
        if (pos.len != 1) return;
        var buf: [4096]u8 = undefined;
        var r = std.Io.File.stdin().reader(ctx.io, &buf);
        const input = r.interface.allocRemaining(a, .limited(4 * 1024 * 1024)) catch "";
        dispatch.hook(ctx, cfg, pos[0], input);
        return;
    }
    if (std.mem.eql(u8, cmd, "help")) return out(ticket_usage);
    fail("unknown ticket command: {s}\n{s}", .{ cmd, ticket_usage });
}

/// `cl t test`: the test plan as a walk-through in the terminal.
fn walkTest(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
    const plan = review.ticketTestPlan(a, t) orelse fail("{s} has no test plan", .{t.key});
    var in_buf: [4096]u8 = undefined;
    var in = std.Io.File.stdin().reader(ctx.io, &in_buf);
    const ask = struct {
        fn line(r: *std.Io.File.Reader, al: std.mem.Allocator, prompt: []const u8) ![]const u8 {
            try out(prompt);
            const l = r.interface.takeDelimiterExclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return "",
                else => return e,
            };
            r.interface.toss(1);
            return al.dupe(u8, std.mem.trim(u8, l, " \r"));
        }
    };
    try out(try std.fmt.allocPrint(a, "Testing {s}: {s}\n", .{ t.key, t.title }));
    if (t.verified.len > 0) {
        var vw: std.Io.Writer.Allocating = .init(a);
        try vw.writer.writeAll("\n");
        try printVerified(&vw.writer, t.verified);
        try out(vw.writer.buffered());
    }
    var results: std.ArrayList(review.StepResult) = .empty;
    const yes = struct {
        fn of(s: []const u8) bool {
            return s.len == 0 or s[0] == 'y' or s[0] == 'Y';
        }
    }.of;
    // "s" at a check stops there: what's left goes as not tested.
    var stopped = false;
    for (plan.steps, 1..) |st, i| {
        if (stopped) {
            var rest: std.ArrayList(review.Check) = .empty;
            for (st.checks) |c| try rest.append(a, .{ .text = c });
            try results.append(a, .{ .title = st.title, .checks = rest.items });
            continue;
        }
        var aw: std.Io.Writer.Allocating = .init(a);
        try aw.writer.writeAll("\n");
        try printStep(&aw.writer, st, i, plan.steps.len);
        try out(aw.writer.buffered());
        // Like the board's buttons: nothing runs or opens without a yes.
        if (st.run.len > 0 and yes(try ask.line(&in, a, "  Run it? [Y/n] "))) {
            _ = review.launch(ctx, db, a, t, .test_plan, i) catch |e| fail("launch failed: {s}", .{@errorName(e)});
            const name = try std.ascii.allocLowerString(a, t.key);
            try out(try std.fmt.allocPrint(a, "  running in tmux session clrun_{s}_s{d}\n", .{ name, i }));
        }
        for (st.open) |url| if (yes(try ask.line(&in, a, try std.fmt.allocPrint(a, "  Open {s}? [Y/n] ", .{url})))) openUrl(ctx, url);
        var checks: std.ArrayList(review.Check) = .empty;
        for (st.checks) |c| {
            if (stopped) {
                try checks.append(a, .{ .text = c });
                continue;
            }
            const ans = try ask.line(&in, a, try std.fmt.allocPrint(a, "  Check: {s}\n  Pass? [y/n, s to stop and send what you have] ", .{c}));
            if (ans.len > 0 and (ans[0] == 's' or ans[0] == 'S')) {
                stopped = true;
                try checks.append(a, .{ .text = c });
                continue;
            }
            const pass = ans.len > 0 and (ans[0] == 'y' or ans[0] == 'Y');
            const note = if (pass) "" else try ask.line(&in, a, "  What happened? ");
            try checks.append(a, .{ .text = c, .pass = pass, .note = note });
        }
        const comment = try ask.line(&in, a, "  Comment on this step? (Enter to skip) ");
        try results.append(a, .{ .title = st.title, .comment = comment, .checks = checks.items });
    }
    const note = try ask.line(&in, a, "\nAnything else for Claude? (Enter to skip) ");
    var finish: actions.Finish = .close;
    const cur = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
    const res = review.recordResults(a, results.items, note) catch |e| boardFail(db, e, "ticket");
    // Comments with everything passing: send them, or finish without.
    var send = !res.passed;
    if (res.passed and res.commented) send = yes(try ask.line(&in, a, "\nAll passed, with comments. Send them to Claude for another round? [Y/n] "));
    if (res.passed and !send and cur.stage == .testing and (cur.branch.len > 0 or cur.change.len > 0)) {
        const main = worktree.mergeBranch(ctx, a, (board.getProject(db, a, cur.project) catch |e| boardFail(db, e, "project")).dir, cur.onto);
        const ans = try ask.line(&in, a, try std.fmt.allocPrint(a, "\nAll passed. [m]erge {s} into {s}, open a [p]R, or just [c]lose? ", .{ if (cur.branch.len > 0) cur.branch else "its change", main }));
        if (ans.len > 0) finish = switch (std.ascii.toLower(ans[0])) {
            'm' => .merge,
            'p' => .pr,
            else => .close,
        };
    }
    const o = actions.testResults(ctx, db, a, key, results.items, note, send, false, finish) catch |e| boardFail(db, e, "ticket");
    try out(if (o.sent)
        "\nSent the results to Claude for another round.\n"
    else if (o.unsent)
        "\nIt has no session to send them to; they're kept as a comment.\n"
    else if (!o.approved)
        "\nAll passed; kept on the ticket (it isn't in testing, so nothing moved).\n"
    else if (finish != .close)
        "\nAll passed: Claude is finishing it; it goes to done when that's through.\n"
    else
        "\nAll passed: the ticket is done.\n");
}

/// What Claude verified itself, before the steps: `cl t testplan` and `cl t test`.
fn printVerified(w: *std.Io.Writer, md: []const u8) !void {
    if (md.len == 0) return;
    try w.writeAll("Checked by Claude:\n");
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |l| try w.print("  {s}\n", .{std.mem.trimEnd(u8, l, "\r")});
    try w.writeAll("\n");
}

/// A test plan step as text: `cl t testplan` and `cl t test`.
fn printStep(w: *std.Io.Writer, st: review.Step, i: usize, n: usize) !void {
    try w.print("Step {d}/{d}: {s}\n", .{ i, n, st.title });
    for (st.do) |x| try w.print("  {s}\n", .{x});
    if (st.run.len > 0) try w.print("  run: {s}\n", .{st.run});
    if (st.wait.len > 0) try w.print("  wait: {s}\n", .{st.wait});
    for (st.open) |x| try w.print("  open: {s}\n", .{x});
    for (st.checks) |x| try w.print("  [ ] {s}\n", .{x});
}

/// Open a URL in the browser, as the wizard does; say it when that fails.
fn openUrl(ctx: Ctx, url: []const u8) void {
    for ([_][]const u8{ "xdg-open", "open", "wslview" }) |cmd| {
        var child = std.process.spawn(ctx.io, .{ .argv = &.{ cmd, url }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch continue;
        _ = child.wait(ctx.io) catch continue;
        return;
    }
    out("  couldn't open a browser; visit it by hand\n") catch {};
}

/// A duration option ("1h", "7d"), or `default` without it.
fn durationArg(args: Args, name: []const u8, default: i64) i64 {
    const s = args.get(name) orelse return default;
    return park.parseDuration(s) orelse fail("{s}: not a duration: {s} (like 90s, 30m, 1h, 1d, 1w, 1h30m)", .{ name, s });
}

/// --merge, --pr, --tell <text> or --close (the default).
fn finishArg(args: Args) actions.Finish {
    const n = @as(u8, @intFromBool(args.has("--merge"))) + @intFromBool(args.has("--pr")) + @intFromBool(args.has("--tell")) + @intFromBool(args.has("--close"));
    if (n > 1) fail("pick one of --merge, --pr, --tell and --close", .{});
    if (args.get("--tell")) |text| return actions.Finish.told(text) orelse fail("--tell needs what Claude should do", .{});
    return if (args.has("--merge")) .merge else if (args.has("--pr")) .pr else .close;
}

/// `--then <steps>` (with --pr): what the follow-up does once the PR
/// merges, replacing Claude's suggestion ("" drops it). Without it,
/// Claude's suggestion (`custom-close --then`) stands.
/// Returns what it replaced (null when it set nothing), for `restoreThen`
/// should the move be refused.
fn setThen(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, args: Args) !?[]const u8 {
    const then = args.get("--then") orelse return null;
    if (!args.has("--pr")) fail("--then goes with --pr: the steps for after the PR merges", .{});
    const t = board.getTicket(db, a, key) catch |e| boardFail(db, e, "ticket");
    board.setPrThen(ctx, db, t.id, std.mem.trim(u8, then, " \t\r\n")) catch |e| boardFail(db, e, "ticket");
    return t.pr_then;
}

/// Put back what `setThen` replaced: the move it was for didn't happen.
fn restoreThen(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, old: ?[]const u8) void {
    const o = old orelse return;
    const t = board.getTicket(db, a, key) catch return;
    board.setPrThen(ctx, db, t.id, o) catch {};
}

/// Say so when a move left the ticket finishing rather than done.
fn finishNote(db: board.Db, a: std.mem.Allocator, key: []const u8) !void {
    const t = board.getTicket(db, a, key) catch return;
    if (t.finishing.len == 0) return;
    try out(try std.fmt.allocPrint(a, "{s}: Claude is {s}; it moves to done when that's through.{s}\n", .{
        t.key, finishingWhat(t.finishing), if (std.mem.eql(u8, t.finishing, "pr")) " With a PR, it waits on the PR parked instead, until it merges." else "",
    }));
}

const finishingWhat = actions.finishingWhat;

fn logLine(text: []const u8) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{text}) catch return;
    std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line) catch {};
}

/// The unfinished ticket session `name` belongs to, for attach's refusal.
fn takenBy(ctx: Ctx, db: board.Db, a: std.mem.Allocator, name: []const u8, id: i64) []const u8 {
    const s = (tmux.find(ctx, a, name) catch null) orelse return "another ticket";
    return (dispatch.attachOwner(db, a, s.tmux_name, id) catch null) orelse "another ticket";
}

/// Session `name`'s directory, for attach's refusal.
fn sessionDir(ctx: Ctx, a: std.mem.Allocator, name: []const u8) []const u8 {
    const s = (tmux.find(ctx, a, name) catch null) orelse return "another directory";
    return ctx.shortenHomeIn(a, s.dir) catch s.dir;
}

/// Project `name`'s checkout, for attach's refusal.
fn projectDir(db: board.Db, a: std.mem.Allocator, name: []const u8) []const u8 {
    const p = board.getProject(db, a, name) catch return "?";
    return p.dir;
}

/// Why attach left Claude as it was, by its status there.
fn attachStatus(st: claude.Status) []const u8 {
    return switch (st) {
        .shell => "is idle there with a background task running, which a restart would end",
        .blocked, .waiting => "is waiting on something there",
        .idle => "is idle there, but cl can't tell which conversation it has",
        .starting => "is starting there",
        .busy => "is working there",
        .gone, .unknown => "is running there, but cl can't tell what it is doing (no status from Claude)",
    };
}

/// The key at `pos[i]`, or $CL_TICKET when it is missing.
/// --after / --not-after <key,...> (links to wait on, any project) and
/// --parallel / --in-order (a sub-ticket waits for the one before it, or not).
fn applyDeps(ctx: Ctx, db: board.Db, a: std.mem.Allocator, key: []const u8, args: Args) !void {
    if (args.has("--parallel") and args.has("--in-order")) fail("--parallel or --in-order, not both", .{});
    if (args.has("--parallel") or args.has("--in-order")) board.setParallel(ctx, db, a, key, args.has("--parallel")) catch |e| switch (e) {
        error.Cycle => fail("{s} can't run in order: the sub-ticket before it waits on {s} (through --after links), so neither would start; drop the link or rank them differently", .{ key, key }),
        else => boardFail(db, e, "ticket"),
    };
    for (try ticket_watch.splitList(a, args.get("--not-after"))) |b| {
        const had = board.removeBlocker(ctx, db, a, key, b) catch |e| boardFail(db, e, try std.fmt.allocPrint(a, "ticket {s}", .{b}));
        if (!had) std.Io.File.stderr().writeStreamingAll(ctx.io, try std.fmt.allocPrint(a, "cl: {s} wasn't linked to wait on {s}\n", .{ key, b })) catch {};
    }
    for (try ticket_watch.splitList(a, args.get("--after"))) |b| {
        _ = board.addBlocker(ctx, db, a, key, b) catch |e| switch (e) {
            error.Cycle => if (std.ascii.eqlIgnoreCase(key, b))
                fail("a ticket can't wait on itself", .{})
            else
                fail("{s} can't wait on {s}: {s} already waits on {s} (directly, through other tickets, or as a later sub-ticket), so neither would start", .{ key, b, b, key }),
            else => boardFail(db, e, try std.fmt.allocPrint(a, "ticket {s}", .{b})),
        };
    }
}

/// The Overview's Last: Claude's line, else (a ticket from before the
/// Overview) its `done` summary.
fn overviewLast(t: board.Ticket) []const u8 {
    return if (t.overview_last.len > 0) t.overview_last else t.summary;
}

/// An option of `cl ticket overview`, trimmed; null when not given ("" clears the line).
fn overviewArg(x: ?[]const u8) ?[]const u8 {
    return if (x) |v| std.mem.trim(u8, v, " \t\r\n") else null;
}

/// What `cl ticket overview` prints with neither option.
fn overviewText(a: std.mem.Allocator, t: board.Ticket) ![]const u8 {
    return std.fmt.allocPrint(a, "last: {s}\nnext: {s}\n", .{ overviewLast(t), t.overview_next });
}

test "cl ticket overview: trims, clears with \"\", and prints Last falling back to the summary" {
    try std.testing.expectEqual(@as(?[]const u8, null), overviewArg(null));
    try std.testing.expectEqualStrings("Wire the tab", overviewArg("  Wire the tab\n").?);
    try std.testing.expectEqualStrings("", overviewArg("").?);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var t = std.mem.zeroInit(board.Ticket, .{ .key = "CL-1", .title = "t", .summary = "Fixed it" });
    try std.testing.expectEqualStrings("last: Fixed it\nnext: \n", try overviewText(arena_state.allocator(), t));
    t.overview_last = "In progress: tests";
    t.overview_next = "The guide";
    try std.testing.expectEqualStrings("last: In progress: tests\nnext: The guide\n", try overviewText(arena_state.allocator(), t));
}

fn keyArg(pos: []const []const u8, i: usize, env_key: ?[]const u8, usage: []const u8) []const u8 {
    if (pos.len == i + 1) return pos[i];
    if (pos.len == i) if (env_key) |k| return k;
    fail("usage: {s}", .{usage});
}

fn looksLikeKey(s: []const u8) bool {
    const dash = std.mem.lastIndexOfScalar(u8, s, '-') orelse return false;
    return dash > 0 and isNumber(s[dash + 1 ..]);
}

fn isFlagWord(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    return s.len > 0;
}

/// Refuse an --onto that names no branch (jj bookmark or git branch) in the
/// project's repo at `dir`, so a typo doesn't make every start fail. ""
/// (back to the default) is fine.
/// `checkOnto` in `p`'s repo; a project that isn't one has no target branches.
fn checkProjectOnto(ctx: Ctx, a: std.mem.Allocator, p: board.Project, onto: ?[]const u8) void {
    const name = onto orelse return;
    if (!p.repo and name.len > 0) fail("--onto: {s} isn't a code repo, so its tickets have no target branch", .{p.name});
    if (p.repo) checkOnto(ctx, a, p.dir, onto);
}

fn checkOnto(ctx: Ctx, a: std.mem.Allocator, dir: []const u8, onto: ?[]const u8) void {
    const name = onto orelse return;
    if (name.len == 0 or worktree.branchExists(ctx, a, dir, name)) return;
    fail("--onto: {s} has no branch or bookmark {s} (create it first)", .{ dir, name });
}

fn flagList(a: std.mem.Allocator, flags: []const board.Flag) ![]const u8 {
    if (flags.len == 0) return "-";
    var out_buf: std.ArrayList(u8) = .empty;
    for (flags, 0..) |f, i| {
        if (i > 0) try out_buf.append(a, ',');
        try out_buf.appendSlice(a, f.kind);
    }
    return out_buf.items;
}

fn stamp(a: std.mem.Allocator, t: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(t, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}Z", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
}

/// What `show` says after the stage of a ticket that plans first (see
/// board.planState): " (plan first)", " (planned)" or " (planned, now an
/// umbrella)".
fn planNote(a: std.mem.Allocator, t: board.Ticket) ![]const u8 {
    return switch (board.planState(t)) {
        .none => "",
        .plan_first => if (t.skill.len > 0) try std.fmt.allocPrint(a, " (plan first, {s})", .{t.skill}) else " (plan first)",
        .planned => " (planned)",
        .planned_umbrella => " (planned, now an umbrella)",
    };
}

test planNote {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t: board.Ticket = .{
        .id = 1, .key = "QA-3", .project = "qa", .title = "Ideate", .body = "", .stage = .planning,
        .mode = .queue, .plan = true, .skill = "grilling", .target = "", .worktree = "", .branch = "", .profile = "",
        .tmux = "", .session_id = "", .summary = "", .round = 1, .created = 0, .updated = 0, .parent = "", .children = 0,
    };
    try std.testing.expectEqualStrings(" (plan first, grilling)", try planNote(a, t));
    t.umbrella = true;
    t.plan_md = "## Sub-tickets\n";
    t.stage = .running;
    try std.testing.expectEqualStrings(" (planned, now an umbrella)", try planNote(a, t));
    t.umbrella = false;
    try std.testing.expectEqualStrings(" (planned)", try planNote(a, t));
    // Dragged out of Planning without a plan: it says neither.
    t.plan_md = "";
    try std.testing.expectEqualStrings("", try planNote(a, t));
}

/// A todo's dates as `show` gives them: local ISO (2026-11-10T15:00, or
/// just the date when no time was given) and said from now.
const TodoDates = struct {
    due: ?[]const u8 = null,
    due_time: bool = false,
    due_text: ?[]const u8 = null,
    remind: ?[]const u8 = null,
    remind_text: ?[]const u8 = null,
};

fn todoDates(ctx: Ctx, db: board.Db, a: std.mem.Allocator, t: board.Ticket) !TodoDates {
    const now = ctx.nowSeconds();
    var d: TodoDates = .{};
    if (t.due_at != 0) {
        const w: when.When = .{ .at = t.due_at, .has_time = t.due_time };
        d.due = try when.iso(db, a, w);
        d.due_time = t.due_time;
        d.due_text = if (t.stage == .done) try std.fmt.allocPrint(a, "due {s}", .{try when.format(db, a, now, w)}) else try dueLine(ctx, db, a, t);
    }
    if (t.remind_at != 0) {
        const w: when.When = .{ .at = t.remind_at, .has_time = true };
        d.remind = try when.iso(db, a, w);
        d.remind_text = try when.label(db, a, now, w);
    }
    return d;
}

fn showText(ctx: Ctx, a: std.mem.Allocator, t: board.Ticket, dates: TodoDates, blocks: []const []const u8, subs: []const board.Ticket, cs: []const board.Comment, evs: []const board.Event) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.print("{s}  {s}\n", .{ t.key, t.title });
    try w.print("stage: {s}{s}   round: {d}   project: {s}   mode: {s}{s}\n", .{
        @tagName(t.stage), try planNote(a, t), t.round, t.project, @tagName(t.mode),
        if (t.mode == .queue and t.target.len > 0) try std.fmt.allocPrint(a, " in {s}", .{t.target}) else "",
    });
    if (t.onto.len > 0) try w.print("onto: {s}{s} (starts from it and merges into it, not trunk)\n", .{ t.onto, if (t.onto_own.len == 0) ", the project's" else "" });
    if (t.parent.len > 0) try w.print("sub-ticket of: {s}{s}\n", .{ t.parent, if (t.parallel) " (parallel: doesn't wait for the one before it)" else "" });
    if (t.umbrella) try w.writeAll("umbrella: only a container for its sub-tickets; it never runs\n");
    if (t.todo) try w.print("todo: yours ({s}){s}\n", .{ todoStageName(t.stage), if (t.stage == .done) "" else "; nothing runs it, and it closes when you move it to done" });
    if (t.link.len > 0) try w.print("link: {s}\n", .{t.link});
    if (dates.due_text) |d| try w.print("due: {s}\n", .{if (std.mem.startsWith(u8, d, "due ")) d[4..] else d});
    if (dates.remind_text) |r| try w.print("reminder: {s}\n", .{r});
    if (std.mem.trim(u8, t.plan_md, " \t\r\n").len > 0) try w.print("plan: {s}; `cl ticket show {s} --plan` prints it\n", .{ if (t.stage == .planning) "handed in" else "kept from its planning", t.key });
    if (t.children > 0) try w.print("sub-tickets: {d}/{d} done\n", .{ t.children_done, t.children });
    try writeDeps(w, a, t, blocks);
    if (t.tmux.len > 0) try w.print("session: {s}\n", .{t.tmux});
    if (t.park) |p| {
        try w.print("parked: {s} (since {s}; `cl ticket unpark {s}` resumes it)\n", .{ p.reason, try stamp(a, p.at), t.key });
        if (p.pr.len > 0 and p.review) try w.print("  pr: {s} (finished with it: new review comments wake it; merged moves it to done; closed without merging ends the park)\n", .{p.pr}) else if (p.pr.len > 0) try w.print("  pr: {s} (merged wakes it; closed without merging ends the park)\n", .{p.pr});
        if (p.until.len > 0) {
            try w.print("  until: {s}\n  every {s}, until {s}\n", .{ p.until, try park.formatDuration(a, p.every), try stamp(a, p.deadline) });
            if (p.checked > 0) try w.print("  last check: {s}: {s}\n", .{ try stamp(a, p.checked), p.result }) else try w.writeAll("  last check: none yet\n");
            try w.print("  next check: {s}\n", .{try stamp(a, p.next)});
        }
    } else if (t.killed) try w.print("session: killed; `cl ticket start {s}` restarts it\n", .{t.key});
    if (overviewLast(t).len > 0) try w.print("last: {s}\n", .{overviewLast(t)});
    if (t.overview_next.len > 0) try w.print("next: {s}\n", .{t.overview_next});
    if (t.custom_close.len > 0) try w.print("custom close: {s}\n", .{t.custom_close});
    if (t.pr_then.len > 0 and t.stage != .done) try w.print("after its PR merges: {s}\n", .{t.pr_then});
    if (t.pr_url.len > 0) try w.print("pull request: {s}{s}\n", .{ t.pr_url, if (board.prStage(t) != null) " (it waits on it; the merge moves it to done)" else "" });
    if (t.finishing.len > 0) try w.print("finishing: {s} (Claude is {s}; it goes to done after)\n", .{ t.finishing, finishingWhat(t.finishing) });
    if (t.worktree.len > 0) try w.print("worktree: {s}   branch: {s}\n", .{ try ctx.shortenHomeIn(a, t.worktree), t.branch });
    if (t.change.len > 0) try w.print("change: {s}{s}{s}\n", .{ t.change[0..@min(t.change.len, 12)], if (t.branch.len > 0) "   bookmark: " else "", t.branch });
    if (t.drift) |d| try w.print("will conflict with {s}: {s} (found {s}; `cl ticket rebase {s}` asks Claude to rebase and settle it)\n", .{ d.onto, try drift.oneLine(a, d.files), try stamp(a, d.at), t.key });
    for (t.flags) |f| try w.print("flag: {s} ({s}, {s}){s}{s}\n", .{ f.kind, f.source, try stamp(a, f.at), if (f.detail.len > 0) ": " else "", f.detail });
    if (t.body.len > 0) try w.print("\n{s}\n", .{t.body});
    if (subs.len > 0) {
        try w.writeAll(if (t.umbrella) "\nsub-tickets, in order (it has no work of its own: it runs as them):\n" else if (t.todo) "\nsub-tickets (Claude tasks for it; they don't wait on it):\n" else "\nsub-tickets, in order (they wait for it to be done):\n");
        for (subs) |c| try w.print("  {s}\t{s}\t{s}\t{s}{s}\n", .{ c.key, @tagName(c.stage), try flagList(a, c.flags), c.title, try waitNote(a, c) });
    }
    if (autoreview.load(a, t)) |r| try writeAutoreview(w, a, t, r);
    if (cs.len > 0) {
        try w.writeAll("\ncomments:\n");
        for (cs) |c| try w.print("  {s} · {s}{s}\n    {s}\n", .{ c.author, try stamp(a, c.at), if (c.sent) " · sent" else "", c.body });
    }
    if (evs.len > 0) {
        try w.writeAll("\nactivity:\n");
        for (evs) |e| try w.print("  {s}  {s}{s}{s}\n", .{ try stamp(a, e.at), e.kind, if (e.detail.len > 0) " " else "", e.detail });
    }
    return aw.writer.buffered();
}

/// Where you are with a todo, by its stage.
fn todoStageName(s: board.Stage) []const u8 {
    return switch (s) {
        .running => "doing",
        .done => "done",
        else => "to do",
    };
}

/// The automated review, under `show`.
fn writeAutoreview(w: *std.Io.Writer, a: std.mem.Allocator, t: board.Ticket, r: autoreview.Review) !void {
    const old = if (r.round > 0 and r.round < t.round) try std.fmt.allocPrint(a, ", of round {d} (before Claude's last changes)", .{r.round}) else "";
    try w.print("\nautomated review ({s}, {s}, profile {s}{s}{s}):\n", .{ r.status, try stamp(a, r.started), r.profile, old, if (r.auto.len > 0) ", started by itself" else "" });
    if (std.mem.eql(u8, r.status, "running")) try w.print("  reviewing in tmux session {s}\n", .{try autoreview.sessionName(a, t.key)});
    if (std.mem.eql(u8, r.status, "failed")) try w.print("  failed: {s}\n", .{r.@"error"});
    if (!std.mem.eql(u8, r.status, "done")) return;
    if (r.summary.len > 0) try w.print("  {s}\n", .{r.summary});
    if (r.findings.len == 0) try w.writeAll("  no findings\n");
    for (r.findings, 1..) |f, i| {
        try w.print("  {d}. [{s}] {s}", .{ i, f.severity, f.title });
        if (i <= r.answers.len) try w.print(" — {s}", .{r.answers[i - 1]});
        if (f.path.len > 0) try w.print(" ({s}{s})", .{ f.path, if (f.line > 0) try std.fmt.allocPrint(a, ":{d}", .{f.line}) else "" });
        try w.writeAll("\n");
        var lines = std.mem.splitScalar(u8, f.body, '\n');
        while (lines.next()) |l| try w.print("     {s}\n", .{l});
    }
    // Edited on the board: that is what --send sends.
    if (r.edited.len > 0) {
        try w.writeAll("  edited on the board; --send sends this instead of the findings:\n");
        var lines = std.mem.splitScalar(u8, r.edited, '\n');
        while (lines.next()) |l| try w.print("     {s}\n", .{l});
    }
    if (r.sent > 0) try w.print("  sent to the session {s}\n", .{try stamp(a, r.sent)}) else if (autoreview.usable(r)) try w.print("  not sent to the session (cl ticket autoreview {s} --send)\n", .{t.key});
    if (r.handled > 0) {
        try w.print("  handled by Claude {s}{s}{s}\n", .{ try stamp(a, r.handled), if (r.answers.len > 0) ": " else "", if (r.answers.len > 0) try autoreview.answersLine(a, r.answers) else "" });
        var lines = std.mem.splitScalar(u8, r.reply, '\n');
        if (r.reply.len > 0) while (lines.next()) |l| try w.print("     {s}\n", .{l});
    }
}

/// What `t` waits on and what waits on it, a line each.
fn writeDeps(w: *std.Io.Writer, a: std.mem.Allocator, t: board.Ticket, blocks: []const []const u8) !void {
    if (t.blocked_by.len > 0) {
        try w.writeAll("waits on:");
        for (t.blocked_by, 0..) |d, i| try w.print("{s} {s} ({s}{s})", .{ if (i > 0) "," else "", d.key, @tagName(d.stage), if (d.order) ", the sub-ticket before it" else if (d.parent) ", its parent" else "" });
        try w.writeAll(if (t.stage == .queued and board.hold(t) == .blocked) "; the dispatcher starts it once they're done\n" else "\n");
    }
    if (blocks.len > 0) try w.print("blocks: {s}\n", .{try std.mem.join(a, ", ", blocks)});
}

/// "  (waits on QA-3)" for a sub-ticket line, "" when nothing holds it.
fn waitNote(a: std.mem.Allocator, t: board.Ticket) ![]const u8 {
    const left = try board.waitingOn(a, t);
    var keys: std.ArrayList([]const u8) = .empty;
    for (left) |d| try keys.append(a, d.key);
    const par = if (t.parallel) "  (parallel)" else "";
    if (keys.items.len == 0 or t.stage == .done) return par;
    return std.fmt.allocPrint(a, "{s}  (waits on {s})", .{ par, try std.mem.join(a, ", ", keys.items) });
}

test looksLikeKey {
    try std.testing.expect(looksLikeKey("QA-12"));
    try std.testing.expect(!looksLikeKey("needs-review"));
}
