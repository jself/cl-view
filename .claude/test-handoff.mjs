// The board checks .claude/test-handoff.sh runs: node test-handoff.mjs <port> <cdp port> <tmux socket> [screenshot dir]
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const [port, cdpPort, sock, shots] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
let failed = 0;
const check = (ok, what, got) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok || got === undefined ? "" : `\n     got: ${JSON.stringify(got)}`}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sessions = () => { try { return execFileSync("tmux", ["-S", sock, "ls", "-F", "#{session_name}"], { encoding: "utf8" }).split("\n"); } catch { return []; } };

const login = await fetch(base + "/login", { method: "POST", body: "password=handoff-pw", headers: { "content-type": "application/x-www-form-urlencoded" }, redirect: "manual" });
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
const shot = async (name) => {
  if (!shots) return;
  const r = await cdp.send("Page.captureScreenshot", { format: "png" });
  writeFileSync(`${shots}/${name}.png`, Buffer.from(r.data, "base64"));
};
const text = (sel) => ev(`document.querySelector(${JSON.stringify(sel)})?.textContent.replace(/\\s+/g, " ").trim() ?? null`);
const tabs = () => ev(`[...document.querySelectorAll('#ticketDlg [role=tab]')].map((b) => b.textContent)`);

try {
  await cdp.send("Page.navigate", { url: base + "/board" });
  await until(`typeof state === "object" && !!state.data && !!document.querySelector('.card[data-open="QA-1"]')`, "the board");

  // QA-1: Test then Demo tabs; Verified on the first step and on Results.
  await ev(`openTicket("QA-1", "test")`);
  await until(`!!document.querySelector("#ticketDlg .wiz")`, "QA-1's Test tab");
  const t1 = await tabs();
  check(t1.includes("Test") && t1.includes("Demo") && t1.indexOf("Demo") === t1.indexOf("Test") + 1, "QA-1 has a Test tab and a Demo tab after it", t1);
  const v = await text("#ticketDlg .wiz .verified");
  check(v?.startsWith("Checked by Claude") && v.includes("all 284 pass"), "step 1 shows Checked by Claude with the Verified list", v);
  check(await ev(`!!document.querySelector("#ticketDlg .wiz .verified strong")`), "the Verified list is rendered as markdown (bold)");
  await shot("test-step1");
  await ev(`document.querySelector('#ticketDlg [data-step-go="1"]').click()`);
  await sleep(100);
  check(await text("#ticketDlg .wiz .verified") === null, "step 2 doesn't repeat it");
  check((await text("#ticketDlg .wiz .check"))?.includes("It looks right"), "step 2 has its check");
  await ev(`document.querySelector('#ticketDlg .dot[title="Results"]').click()`);
  await sleep(100);
  check((await text("#ticketDlg .wiz .verified"))?.startsWith("Checked by Claude"), "Results shows it again");

  // The Demo tab: steps and run buttons, no checks, comments or sending.
  await ev(`document.querySelector('#ticketDlg [data-tab="demo"]').click()`);
  await until(`!!document.querySelector("#ticketDlg .wiz [data-demo-go]")`, "the Demo tab");
  const d1 = await ev(`(() => { const w = document.querySelector("#ticketDlg .wiz"); return { text: w.textContent.replace(/\\s+/g, " "), pf: w.querySelectorAll(".pf, .check, textarea, [data-send]").length, run: w.querySelector("[data-launch]")?.dataset.demo }; })()`);
  check(d1.text.includes("Step 1 of 2") && d1.text.includes("Start the demo") && d1.pf === 0, "the Demo tab shows step 1 without Pass/Fail, comments or Send", d1);
  check(d1.run === "1", "its Run button is the demo's", d1);
  await ev(`document.querySelector('#ticketDlg [data-launch]').click()`);
  for (let i = 0; i < 40 && !sessions().includes("clrun_qa-1_d1"); i++) await sleep(100);
  check(sessions().includes("clrun_qa-1_d1") && !sessions().includes("clrun_qa-1_s1"), "Run starts clrun_qa-1_d1, not the test step's", sessions());
  await until(`(document.querySelector("#ticketDlg .wiz pre.runout")?.textContent || "").includes("demo-run")`, "the demo run's output", 8000).then(() => check(true, "its output shows under it"), (e) => check(false, e.message));
  await shot("demo-step1");
  // N goes to the next step.
  await ev(`document.dispatchEvent(new KeyboardEvent("keydown", { key: "n", bubbles: true }))`);
  await sleep(100);
  const d2 = await text("#ticketDlg .wiz");
  check(d2.includes("Step 2 of 2") && d2.includes("Look at the top"), "n goes to step 2", d2);
  check(await ev(`!![...document.querySelectorAll("#ticketDlg .wiz a.btn")].find((a) => a.href === "http://127.0.0.1:1/board")`), "step 2 has its Open button");
  await shot("demo-step2");
  await ev(`document.querySelector('#ticketDlg [data-tab="test"]').click()`);
  await sleep(100);
  await ev(`document.querySelector("dialog[open]")?.close()`);
  // Its close event comes later and would clear what opens next.
  await until(`!state.open`, "QA-1's popup to close");

  // QA-2: Verified and a start step: "Try it", "Works as expected", no Demo tab.
  await ev(`openTicket("QA-2", "test")`);
  await until(`state.detail?.ticket.key === "QA-2" && !!document.querySelector("#ticketDlg .wiz")`, "QA-2's Test tab");
  check(!(await tabs()).includes("Demo"), "QA-2 has no Demo tab");
  await ev(`document.querySelector('#ticketDlg [data-step-go="1"]').click()`);
  await sleep(100);
  const w2 = await text("#ticketDlg .wiz");
  check(w2.includes("Try it") && w2.includes("Works as expected") && w2.includes("Pass"), "its last step is Try it: Works as expected, with Pass/Fail", w2);
  await shot("try-it");
} catch (e) {
  check(false, e.message, await ev(`({ open: state.open, tab: state.tab, key: state.detail?.ticket.key, tabs: [...document.querySelectorAll("#ticketDlg [role=tab]")].map((b) => b.textContent) })`).catch(() => null));
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
