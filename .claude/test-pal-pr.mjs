// The checks .claude/test-pal-pr.sh runs: node test-pal-pr.mjs <port> <cdp port>
const [port, cdpPort] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
let failed = 0;
const check = (ok, what, got) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok || got === undefined ? "" : `\n     got: ${JSON.stringify(got)}`}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const login = await fetch(base + "/login", { method: "POST", body: "password=pal-test-pw", headers: { "content-type": "application/x-www-form-urlencoded" }, redirect: "manual" });
const cookie = (login.headers.get("set-cookie") || "").split(";")[0];
check(cookie.startsWith("cl_session="), "signed in");

const target = (await (await fetch(`http://127.0.0.1:${cdpPort}/json`)).json()).find((x) => x.type === "page");
const cdp = await connect(target.webSocketDebuggerUrl);
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

// The palette's rows for q, as the human sees them: key, title, note.
async function rows(q) {
  await ev(`(() => { const d = document.getElementById("palDlg"); if (!d.open) palOpen();
    const b = document.getElementById("palIn"); b.value = ${JSON.stringify(q)}; b.dispatchEvent(new Event("input")); })()`);
  return ev(`[...document.querySelectorAll("#palList li[data-pal]")].map((li) => [li.querySelector(".k")?.textContent || "", li.querySelector(".l")?.textContent || "", li.querySelector(".n")?.textContent || ""])`);
}
const tickets = (rs) => rs.filter((r) => r[0]);

await cdp.send("Page.navigate", { url: base + "/board" });
await until(`state.data?.tickets?.length === 15`, "the board's tickets");

let rs = tickets(await rows("2738"));
check(rs.length === 2 && rs[0][0] === "QA-1" && rs[1][0] === "WEB-1", "2738 lists the two tickets whose PRs are #2738, the open one first", rs);
check(rs[0]?.[2].startsWith("PR acme/api#2738 · qa"), "QA-1's note names its PR and repo", rs[0]);
check(rs[1]?.[2].startsWith("PR acme/site#2738 · web"), "WEB-1's note names its PR in the other repo", rs[1]);

rs = tickets(await rows("#2738"));
check(rs.length === 2 && rs[0][0] === "QA-1" && rs[1][0] === "WEB-1", "#2738 lists the same two", rs);

rs = tickets(await rows("12"));
check(rs[0]?.[0] === "QA-12" && rs[1]?.[0] === "QA-2" && rs[1][2].startsWith("PR acme/api#12"), "12: the ticket QA-12 first, then QA-2 for its PR #12", rs.slice(0, 2));
check(!rs[0]?.[2].startsWith("PR "), "QA-12's note says nothing of a PR", rs[0]);

rs = tickets(await rows("#12"));
check(rs[0]?.[0] === "QA-2", "#12: QA-2 (the PR) first", rs.slice(0, 2));

rs = tickets(await rows("3"));
const top = rs.slice(0, 2).map((r) => r[0]).sort();
const sc = await ev(`Object.fromEntries(palTickets().filter((x) => /^(QA|WEB)-3$/.test(x.key)).map((x) => [x.key, palTicketScore("3", x).score]))`);
check(sc["QA-3"] === sc["WEB-3"], "3: QA-3 scores as a key match, as WEB-3 does, not lower for its PR", sc);
check(top.join() === "QA-3,WEB-3" && rs.find((r) => r[0] === "QA-3")[2].startsWith("PR acme/api#3"), "3: QA-3 (key and PR #3) ranks with WEB-3 (key), with its PR in the note", rs.slice(0, 3));

rs = tickets(await rows("273"));
check(!rs.some((r) => r[2].startsWith("PR ")), "273 (part of the number) is no PR match", rs);

rs = tickets(await rows("Ticket 4"));
check(rs[0]?.[0] === "QA-4" && !rs[0][2].startsWith("PR "), "a title search is as before", rs[0]);

await until(`state.data.tickets.find((r) => r.ticket.key === "WEB-2")?.ticket.pr_url`, "WEB-2's PR on record (the dispatcher's look)", 20000);
rs = tickets(await rows("2741"));
check(rs.length === 1 && rs[0][0] === "WEB-2" && rs[0][2].startsWith("PR acme/site#2741 · web"), "2741 finds WEB-2, whose PR cl looked up from its branch", rs);

await rows("2738");
await ev(`document.getElementById("palIn").dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }))`);
await until(`state.open === "QA-1" && document.getElementById("ticketDlg").open`, "QA-1's popup");
check(!(await ev(`document.getElementById("palDlg").open`)), "Enter closes Ctrl+K and opens QA-1");

console.log(failed ? `${failed} failed` : "all passed");
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
