// The checks .claude/test-stages.sh runs: node test-stages.mjs <port> <cdp port>
const [port, cdpPort] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
let failed = 0;
const check = (ok, what, got) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok || got === undefined ? "" : `\n     got: ${JSON.stringify(got)}`}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const login = await fetch(base + "/login", { method: "POST", body: "password=stages-pw", headers: { "content-type": "application/x-www-form-urlencoded" }, redirect: "manual" });
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
const card = (k) => ev(`(() => { const c = document.querySelector('#main .card[data-open="${k}"]'); return c ? { col: c.closest(".col")?.dataset.drop, text: c.textContent.replace(/\\s+/g, " ").trim() } : null; })()`);
const closeDlg = () => ev(`document.querySelectorAll("dialog[open]").forEach((d) => d.close())`);
// The ticket's approve button in its popup (the action bar).
async function approveButton(k) {
  await closeDlg();
  // The popup's close handler runs after close(): let it settle, and open
  // again if it undid the open.
  await until(`!document.querySelector("dialog[open]")`, "the popup closed");
  await sleep(200);
  for (let i = 0; i < 3; i++) {
    await ev(`openTicket("${k}")`);
    try { await until(`state.detail?.ticket.key === "${k}" && !!document.querySelector('#ticketBody [data-act="approve"]')`, `${k}'s approve button`, 4000); break; }
    catch (e) { if (i === 2) throw e; }
  }
  return ev(`document.querySelector('#ticketBody [data-act="approve"]').textContent.trim()`);
}

try {
  await cdp.send("Page.navigate", { url: base + "/board" });
  await ev(`localStorage.setItem("cl-view", "board")`);
  await cdp.send("Page.navigate", { url: base + "/board" });
  await until(`typeof state === "object" && !!state.data && !!document.querySelector('#main .card[data-open="QA-3"]')`, "the board");

  // The columns, in Board and Lanes.
  const cols = await ev(`[...document.querySelectorAll("#main .col")].map((c) => c.dataset.drop).join(" ")`);
  check(/running testing review/.test(cols), "Board's columns go Running, Testing, Review", cols);
  await ev(`state.view = "lanes"; render()`);
  await until(`!!document.querySelector("#main .lanes")`, "Lanes");
  const heads = await ev(`[...document.querySelectorAll("#main .lhd h2")].map((h) => h.childNodes[1]?.textContent || h.textContent).join(" ")`);
  check(/Running Testing Review/.test(heads), "Lanes' columns go Running, Testing, Review", heads);
  await ev(`state.view = "board"; render()`);
  await until(`!!document.querySelector('#main .col[data-drop="testing"]')`, "Board again");

  // Claude finished with a test plan: Testing, ready to test, with its summary.
  let c = await card("QA-1");
  check(c?.col === "testing" && c.text.includes("Ready to test"), "QA-1 (a test plan) is in Testing, Ready to test", c);
  const ask = await ev(`(() => { const r = state.data.tickets.find((x) => x.ticket.key === "QA-1"); return askText(r.ticket, r.ticket.flags.find((f) => f.kind === "testing")); })()`);
  check(ask === "Members can be assigned from the card", "its Needs you card has Claude's summary", ask);
  // No test plan: straight to Review.
  c = await card("QA-2");
  check(c?.col === "review" && c.text.includes("Ready for review"), "QA-2 (no test plan) went straight to Review, Ready for review", c);
  // Held for its automated review: Running, reviewing, not in Needs You.
  c = await card("QA-3");
  check(c?.col === "running" && c.text.includes("reviewing"), "QA-3, held for its automated review, is in Running, reviewing", c);
  const needs = await ev(`state.data.tickets.filter(needsMe).map((r) => r.ticket.key).join(" ")`);
  check(needs.includes("QA-1") && needs.includes("QA-2") && !needs.includes("QA-3"), "QA-3 isn't in Needs You (QA-1 and QA-2 are)", needs);

  // The approve buttons.
  check((await approveButton("QA-1")) === "Tested, to review", "Testing approves as Tested, to review");
  check((await approveButton("QA-2")) === "Approve, finish…", "Review approves as Approve, finish…");
  // Approving out of Review opens the Done dialog.
  await ev(`document.querySelector('#ticketBody [data-act="approve"]').click()`);
  await until(`document.getElementById("finishDlg").open`, "the Done dialog");
  const dlg = await ev(`document.getElementById("finishBody").textContent.replace(/\\s+/g, " ")`);
  check(dlg.includes("Merge") && dlg.includes("Open a PR"), "Approve, finish… opens the Done dialog (Merge, PR)", dlg);
  await ev(`document.getElementById("finishDlg").close()`);
  await sleep(200);
  c = await card("QA-2");
  check(c?.col === "review", "cancelled, QA-2 stays in Review", c);

  // Tested, to review: QA-1 moves on to Review, flagged.
  await approveButton("QA-1");
  await ev(`document.querySelector('#ticketBody [data-act="approve"]').click()`);
  await sleep(500);
  await ev("loadBoard()");
  await sleep(300);
  c = await card("QA-1");
  check(c?.col === "review" && c.text.includes("Ready for review"), "Tested, to review moves QA-1 on to Review, Ready for review", c);
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
