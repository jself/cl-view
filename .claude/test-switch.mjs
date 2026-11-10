// The checks .claude/test-switch.sh runs: node test-switch.mjs <port> <cdp port> <tmux socket>
import { execFileSync } from "node:child_process";

const [port, cdpPort, sock] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
let failed = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pane = (name) => execFileSync("tmux", ["-S", sock, "capture-pane", "-p", "-t", name], { encoding: "utf8" });

// Sign in.
const login = await fetch(base + "/login", { method: "POST", body: "password=switchtest", headers: { "content-type": "application/x-www-form-urlencoded" }, redirect: "manual" });
const cookie = (login.headers.get("set-cookie") || "").split(";")[0];
check(cookie.startsWith("cl_session="), "signed in");

// The pages: checked every time, 304 while unchanged; the board's data too.
for (const path of ["/board", "/?attach=cl_switch_a"]) {
  const r = await fetch(base + path, { headers: { cookie } });
  const etag = r.headers.get("etag");
  check(r.status === 200 && /no-cache/.test(r.headers.get("cache-control")) && !/no-store/.test(r.headers.get("cache-control")) && !!etag, `${path}: no-cache with an etag`);
  const again = await fetch(base + path, { headers: { cookie, "if-none-match": etag } });
  check(again.status === 304, `${path}: 304 when the page has it`);
}
const api = await fetch(base + "/api/board", { headers: { cookie } });
check(!/no-store/.test(api.headers.get("cache-control")), "/api/board isn't no-store (it would keep the board out of the back/forward cache)");
const signedOut = await fetch(base + "/board", { redirect: "manual" });
check(signedOut.status === 303, "/board still sends a signed-out browser to log in");

// The browser.
const target = (await (await fetch(`http://127.0.0.1:${cdpPort}/json`)).json()).find((x) => x.type === "page");
const cdp = await connect(target.webSocketDebuggerUrl);
await cdp.send("Network.enable");
await cdp.send("Page.enable");
await cdp.send("Network.setCookie", { name: "cl_session", value: cookie.slice("cl_session=".length), url: base });
const notCached = [];
cdp.on("Page.backForwardCacheNotUsed", (p) => { notCached.push(p.notRestoredExplanations.map((e) => e.reason).join(", ")); if (process.env.DEBUG) console.log("  bfcache not used:", JSON.stringify(p)); });

const ev = (expr) => cdp.eval(expr);
async function until(expr, what, timeout = 10000) {
  const t0 = performance.now();
  while (performance.now() - t0 < timeout) {
    try { if (await ev(expr)) return performance.now() - t0; } catch {}
    await sleep(5);
  }
  throw new Error("timed out waiting for " + what);
}
const onBoard = `location.pathname === "/board" && typeof state === "object" && !!state.data && !!document.querySelector(".cols, .needs, main")`;
const termShows = (prompt) => `location.pathname === "/" && (document.querySelector(".xterm-rows")?.textContent || "").includes(${JSON.stringify(prompt)})`;
async function type(text) {
  await cdp.send("Input.insertText", { text });
  for (const type of ["keyDown", "keyUp"]) await cdp.send("Input.dispatchKeyEvent", { type, key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: type === "keyDown" ? "\r" : undefined });
}
async function reaches(session, word) {
  const t0 = performance.now();
  while (performance.now() - t0 < 5000) {
    if (pane(session).split("\n").some((l) => l.trim() === word)) return true;
    await sleep(20);
  }
  return false;
}
const timings = { open: [], reopen: [], back: [] };
// Click like a person (the switch starts in a task of its own, so the timer
// covers all of it).
const click = (js) => ev(`setTimeout(() => { ${js} }), 1`);

try {
  await cdp.send("Page.navigate", { url: base + "/board" });
  await until(onBoard, "the board");
  // This browser profile is new: the board installs its service worker now,
  // and for a few seconds after, Chrome flushes its back/forward cache
  // ("CacheFlushed"). A browser that has used the board before doesn't, so
  // let it settle first.
  await until(`!("serviceWorker" in navigator) || !!navigator.serviceWorker.controller`, "the service worker", 5000).catch(() => {});
  await sleep(3000);
  await ev(`window.boardMark = 1`);

  // Open session a's terminal from the board.
  let t0 = performance.now();
  await click(`openTerm("/?attach=cl_switch_a")`);
  await until(termShows("a$"), "session a's terminal");
  timings.open.push(performance.now() - t0);
  await type("echo first-$((40+2))");
  check(await reaches("cl_switch_a", "first-42"), "typing in the terminal reaches the session");
  await ev(`window.termMark = 1`);

  for (let round = 0; round < 3; round++) {
    // X: back to the board, as it was.
    await sleep(400);
    t0 = performance.now();
    await click(`document.getElementById("close").click()`);
    await until(onBoard, "the board again");
    timings.back.push(performance.now() - t0);
    if (round === 0) check(await ev(`window.boardMark === 1`), "X shows the board from the back/forward cache (not loaded again)");

    // Open the same terminal again: forward to it, connected again.
    await sleep(400);
    t0 = performance.now();
    await click(`openTerm("/?attach=cl_switch_a")`);
    await until(termShows("a$"), "session a's terminal again");
    timings.reopen.push(performance.now() - t0);
    if (round === 0) {
      check(await ev(`window.termMark === 1`), "reopening it shows the same page from the back/forward cache");
      await type("echo again-$((40+2))");
      check(await reaches("cl_switch_a", "again-42"), "after coming back, what's typed reaches the session (it connected again)");
    }
  }

  // Ctrl-Q goes back the same way.
  await sleep(400);
  await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: "q", code: "KeyQ", windowsVirtualKeyCode: 81, modifiers: 2 });
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: "q", code: "KeyQ", windowsVirtualKeyCode: 81, modifiers: 2 });
  await until(onBoard, "the board after Ctrl-Q");
  check(await ev(`window.boardMark === 1`), "Ctrl-Q shows the board from the back/forward cache too");

  // Another session's terminal: loaded afresh, and it's that session.
  await sleep(400);
  await click(`openTerm("/?attach=cl_switch_b")`);
  await until(termShows("b$"), "session b's terminal");
  check(await ev(`window.termMark === undefined`), "another session's terminal loads afresh");
  await type("echo other-$((40+2))");
  check(await reaches("cl_switch_b", "other-42"), "and what's typed reaches that session");
  await sleep(400);
  await click(`document.getElementById("close").click()`);
  await until(onBoard, "the board after session b");
  check(await ev(`window.boardMark === 1`), "back from it, the board is still the kept one");

  // Session a's terminal was dropped from history by opening b: the board opens it afresh.
  await sleep(400);
  await click(`openTerm("/?attach=cl_switch_a")`);
  await until(termShows("a$"), "session a's terminal, after b");
  check(await ev(`window.termMark === undefined`), "a terminal no longer next in history loads afresh");

  // A terminal opened on its own (a new tab): its X loads the board.
  const tab = await cdp.send("Target.createTarget", { url: base + "/?attach=cl_switch_a" });
  const tabInfo = (await (await fetch(`http://127.0.0.1:${cdpPort}/json`)).json()).find((x) => x.id === tab.targetId);
  const cdp2 = await connect(tabInfo.webSocketDebuggerUrl);
  const ev2 = (expr) => cdp2.eval(expr);
  for (let i = 0; i < 400 && !(await ev2(termShows("a$")).catch(() => false)); i++) await sleep(25);
  await ev2(`setTimeout(() => document.getElementById("close").click()), 1`);
  for (let i = 0; i < 400 && !(await ev2(onBoard).catch(() => false)); i++) await sleep(25);
  check(await ev2(onBoard), "a terminal opened in a new tab: X opens the board");
  await cdp.send("Target.closeTarget", { targetId: tab.targetId });
} catch (e) {
  check(false, e.message);
}

if (notCached.length) console.log("not from the back/forward cache: " + notCached.join(" | "));
const med = (a) => a.length ? Math.round([...a].sort((x, y) => x - y)[a.length >> 1]) + " ms" : "-";
console.log(`board → terminal (first open): ${med(timings.open)}; reopened: ${med(timings.reopen)}; terminal → board: ${med(timings.back)}`);
console.log(failed ? `${failed} check(s) failed` : "all checks passed");
process.exit(failed ? 1 : 0);

// A minimal CDP client (Node's global WebSocket).
async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let id = 0;
  const waits = new Map(), handlers = new Map();
  ws.onmessage = (m) => {
    const j = JSON.parse(m.data);
    if (j.id && waits.has(j.id)) { const [res, rej] = waits.get(j.id); waits.delete(j.id); j.error ? rej(new Error(j.error.message)) : res(j.result); }
    else if (j.method && handlers.has(j.method)) handlers.get(j.method)(j.params);
  };
  const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; waits.set(i, [res, rej]); ws.send(JSON.stringify({ id: i, method, params })); });
  return {
    send,
    on: (m, f) => handlers.set(m, f),
    eval: async (expression) => {
      const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
      return r.result.value;
    },
  };
}
