// The checks .claude/test-pr-park.sh runs: node test-pr-park.mjs <port> <cdp port> <step script> <tmux socket>
import { execFileSync } from "node:child_process";

const [port, cdpPort, step, sock] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
let failed = 0;
const check = (ok, what, got) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok || got === undefined ? "" : `\n     got: ${JSON.stringify(got)}`}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const run = (what) => execFileSync(step, [what], { encoding: "utf8" });

const login = await fetch(base + "/login", { method: "POST", body: "password=prtest-pw", headers: { "content-type": "application/x-www-form-urlencoded" }, redirect: "manual" });
const cookie = (login.headers.get("set-cookie") || "").split(";")[0];
check(cookie.startsWith("cl_session="), "signed in");

const target = (await (await fetch(`http://127.0.0.1:${cdpPort}/json`)).json()).find((x) => x.type === "page");
const cdp = await connect(target.webSocketDebuggerUrl);
await cdp.send("Network.enable");
await cdp.send("Page.enable");
await cdp.send("Network.setCookie", { name: "cl_session", value: cookie.slice("cl_session=".length), url: base });
const ev = (expr) => cdp.eval(expr);
async function until(expr, what, timeout = 10000) {
  const t0 = performance.now();
  while (performance.now() - t0 < timeout) {
    try { if (await ev(expr)) return; } catch {}
    await sleep(50);
  }
  throw new Error("timed out waiting for " + what);
}
// Where QA-1's card is, and what it says.
const card = `(() => { const c = document.querySelector('.card[data-open="QA-1"]'); return c ? { col: c.closest(".col")?.dataset.drop, text: c.textContent.replace(/\\s+/g, " ").trim() } : null; })()`;
const reload = async () => { await ev("loadBoard()"); await sleep(300); return ev(card); };

try {
  await cdp.send("Page.navigate", { url: base + "/board" });
  await until(`typeof state === "object" && !!state.data && !!document.querySelector('.card[data-open="QA-1"]')`, "the board with QA-1");

  // Opened its PR: still in Review, waiting on it.
  let c = await ev(card);
  check(c.col === "review", "finished with a PR, QA-1 stays in Review", c);
  check(c.text.includes("Waiting on PR #31") && !c.text.includes("Parked: Waiting"), "its card says Waiting on PR #31", c.text);
  check(!c.text.includes("Not merged"), "it isn't flagged Not merged", c.text);

  // Its popup links the PR and says what wakes it.
  await ev(`openTicket("QA-1")`);
  await until(`!!document.querySelector(".parkbox")`, "QA-1's park box");
  const box = await ev(`(() => { const b = document.querySelector(".parkbox"); return { text: b.textContent.replace(/\\s+/g, " "), href: b.querySelector("a")?.href }; })()`);
  check(box.href === "https://github.com/o/r/pull/31", "the park box links the PR", box);
  check(/Finished with o\/r\/pull\/31/.test(box.text) && /wake it to address them/.test(box.text) && /merge moves it to Done/.test(box.text), "the park box says feedback wakes it and the merge moves it to Done", box.text);
  await ev(`document.querySelector("dialog[open]")?.close()`);

  // The Done dialog, for a ticket with a branch in Review: PR keeps it there.
  await ev(`void (window.__finish = chooseFinish("QA-2"))`);
  await until(`document.getElementById("finishDlg").open`, "the Done dialog");
  const dlg = await ev(`document.getElementById("finishBody").textContent.replace(/\\s+/g, " ")`);
  check(dlg.includes("Open a PR") && dlg.includes("Once the PR is open, the ticket stays in Review, parked on it"), "the Done dialog says PR keeps it in Review, parked", dlg);
  await ev(`document.getElementById("finishDlg").close()`);

  // A review comment: it wakes, flagged, its session resumed with the comment.
  console.log("     check: " + run("feedback").trim());
  c = await reload();
  check(!c.text.includes("Waiting on PR"), "a review comment ends the park", c.text);
  check(c.text.includes("Woke from park"), "its card is flagged Woke from park", c.text);
  const sessions = execFileSync("tmux", ["-S", sock, "ls", "-F", "#{session_name}"], { encoding: "utf8" });
  check(/qa/i.test(sessions), "its session resumed", sessions);
  const comments = await (await fetch(base + "/api/ticket/QA-1", { headers: { cookie } })).json();
  const said = JSON.stringify(comments);
  check(said.includes("This fires on adoption too.") && said.includes("src/snapshot.ts:196") && said.includes("Don't merge the PR"), "it was told the comment, its file and line, and not to merge");

  // Its round done: back in Review, waiting on the PR again.
  console.log("     " + run("round").trim());
  c = await reload();
  check(c.col === "review" && c.text.includes("Waiting on PR #31"), "its round's done parks it on the PR again, in Review", c);
  console.log("     check: " + run("check").trim());
  c = await reload();
  check(c.text.includes("Waiting on PR #31"), "the same comment doesn't wake it again", c.text);

  // Merged: Done.
  console.log("     check: " + run("merged").trim());
  await ev(`state.done = true; render()`);
  c = await reload();
  check(c.col === "done" && !c.text.includes("Waiting on PR"), "the merge moves it to Done", c);
} catch (e) {
  check(false, e.message);
}
process.exit(failed ? 1 : 0);

async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let id = 0;
  const waits = new Map();
  ws.onmessage = (m) => {
    const j = JSON.parse(m.data);
    if (j.id && waits.has(j.id)) { const [res, rej] = waits.get(j.id); waits.delete(j.id); j.error ? rej(new Error(j.error.message)) : res(j.result); }
  };
  const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; waits.set(i, [res, rej]); ws.send(JSON.stringify({ id: i, method, params })); });
  return {
    send,
    eval: async (expression) => {
      const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
      return r.result.value;
    },
  };
}
