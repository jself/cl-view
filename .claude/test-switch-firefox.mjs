// The Firefox checks .claude/test-switch.sh runs: node test-switch-firefox.mjs <port> <bidi port> <tmux socket>
// Firefox shows the board from its back/forward cache with the sessionStorage
// it had when it left, and keeps a terminal page only when its WebSocket has
// closed before it goes (CL-177). Both used to make every reopened terminal
// load afresh in Firefox.
import { execFileSync } from "node:child_process";

const [port, bidiPort, sock] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
let failed = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} firefox: ${what}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pane = (name) => execFileSync("tmux", ["-S", sock, "capture-pane", "-p", "-t", name], { encoding: "utf8" });

const ws = new WebSocket(`ws://127.0.0.1:${bidiPort}/session`);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let id = 0;
const waits = new Map();
ws.onmessage = (m) => { const j = JSON.parse(m.data); if (j.id && waits.has(j.id)) { const [res, rej] = waits.get(j.id); waits.delete(j.id); j.type === "error" ? rej(new Error(j.error + ": " + j.message)) : res(j.result); } };
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; waits.set(i, [res, rej]); ws.send(JSON.stringify({ id: i, method, params })); });
await send("session.new", { capabilities: {} });
const ctx = (await send("browsingContext.getTree", {})).contexts[0].context;
const ev = async (expression) => { const r = await send("script.evaluate", { expression, target: { context: ctx }, awaitPromise: true }); if (r.type === "exception") throw new Error(r.exceptionDetails?.text); return r.result?.value; };
const nav = (url) => send("browsingContext.navigate", { context: ctx, url, wait: "complete" });
async function until(expr, what, timeout = 10000) {
  const t0 = performance.now();
  while (performance.now() - t0 < timeout) { try { if (await ev(expr)) return performance.now() - t0; } catch {} await sleep(5); }
  throw new Error("timed out waiting for " + what);
}
async function type(text) {
  await send("input.performActions", { context: ctx, actions: [{ type: "key", id: "kb", actions: [...[...text].flatMap((c) => [{ type: "keyDown", value: c }, { type: "keyUp", value: c }]), { type: "keyDown", value: "" }, { type: "keyUp", value: "" }] }] });
}
async function reaches(session, word) {
  const t0 = performance.now();
  while (performance.now() - t0 < 5000) { if (pane(session).split("\n").some((l) => l.trim() === word)) return true; await sleep(20); }
  return false;
}
const onBoard = `location.pathname === "/board" && typeof state === "object" && !!state.data && !!document.querySelector(".cols, .needs, main")`;
const termShows = (prompt) => `location.pathname === "/" && (document.querySelector(".xterm-rows")?.textContent || "").includes(${JSON.stringify(prompt)})`;
const click = (js) => ev(`setTimeout(() => { ${js} }); 1`);
const timings = { reopen: [], back: [] };

try {
  await nav(base + "/");
  await ev(`document.querySelector("input[name=password]").value = "switchtest"; document.querySelector("form").submit(); 1`);
  await until(`!document.querySelector("input[name=password]")`, "signing in");
  await nav(base + "/board");
  await until(onBoard, "the board");
  await sleep(1500);
  await ev(`window.boardMark = 1; 1`);
  await click(`openTerm("/?attach=cl_switch_a")`);
  await until(termShows("a$"), "session a's terminal");
  await ev(`window.termMark = 1; 1`);
  for (let round = 0; round < 3; round++) {
    await sleep(400);
    let t0 = performance.now();
    await click(`document.getElementById("close").click()`);
    await until(onBoard, "the board again");
    timings.back.push(performance.now() - t0);
    if (round === 0) check(await ev(`window.boardMark === 1`), "X shows the board from the back/forward cache");
    await sleep(400);
    t0 = performance.now();
    await click(`openTerm("/?attach=cl_switch_a")`);
    await until(termShows("a$"), "session a's terminal again");
    timings.reopen.push(performance.now() - t0);
    if (round === 0) {
      check(await ev(`window.termMark === 1`), "reopening the terminal goes forward to the kept page, not a fresh load");
      await type("echo ff-$((40+2))");
      // Typed at once, while it connects again: kept until it has.
      check(await reaches("cl_switch_a", "ff-42"), "after coming back, what's typed at once reaches the session (it connected again)");
    }
  }
  // Another session's terminal is still its own page.
  await sleep(400);
  await click(`document.getElementById("close").click()`);
  await until(onBoard, "the board before session b");
  await click(`openTerm("/?attach=cl_switch_b")`);
  await until(termShows("b$"), "session b's terminal");
  check(await ev(`window.termMark === undefined`), "another session's terminal loads afresh");
} catch (e) {
  check(false, e.message);
}
const med = (a) => a.length ? Math.round([...a].sort((x, y) => x - y)[a.length >> 1]) + " ms" : "-";
console.log(`firefox: terminal reopened: ${med(timings.reopen)}; terminal → board: ${med(timings.back)}`);
await send("session.end", {}).catch(() => {});
process.exit(failed ? 1 : 0);
