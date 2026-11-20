// The checks .claude/test-project-combo.sh runs: node test-project-combo.mjs <port> <cdp port> [screenshot dir]
import { writeFileSync } from "node:fs";
const [port, cdpPort, shots] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
let failed = 0;
const check = (ok, what, got) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok || got === undefined ? "" : `\n     got: ${JSON.stringify(got)}`}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const login = await fetch(base + "/login", { method: "POST", body: "password=combo-test-pw", headers: { "content-type": "application/x-www-form-urlencoded" }, redirect: "manual" });
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
const KEYS = { Enter: 13, Escape: 27, ArrowDown: 40, Tab: 9 };
async function press(key) {
  for (const type of ["keyDown", "keyUp"]) await cdp.send("Input.dispatchKeyEvent", { type, key, code: key, windowsVirtualKeyCode: KEYS[key], text: type === "keyDown" && key === "Enter" ? "\r" : undefined });
  await sleep(50);
}
// Focus the box in front of sel (a CSS selector), select what's in it, type text.
async function type(sel, text) {
  await ev(`(() => { const b = document.querySelector(${JSON.stringify(sel)}).previousElementSibling; b.focus(); b.select(); })()`);
  await sleep(50);
  await cdp.send("Input.insertText", { text });
  await sleep(80);
}
const listed = (sel) => ev(`[...document.querySelector(${JSON.stringify(sel)}).nextElementSibling.querySelectorAll("li[data-i]")].map((li) => li.firstChild.textContent)`);
const isOpen = (sel) => ev(`document.querySelector(${JSON.stringify(sel)}).nextElementSibling.matches(":popover-open")`);
const boxText = (sel) => ev(`document.querySelector(${JSON.stringify(sel)}).previousElementSibling.value`);
async function shot(name) { if (!shots) return; const r = await cdp.send("Page.captureScreenshot", { format: "png" }); writeFileSync(`${shots}/${name}.png`, Buffer.from(r.data, "base64")); }

await cdp.send("Page.navigate", { url: base + "/board" });
await until(`state.data?.projects?.length === 5 && document.querySelector("#projectSel option[value=astro]")`, "the board's projects");

const F = "#projectSel";
check(await ev(`document.getElementById("projectSel").hidden && document.querySelector("input.combo[role=combobox][aria-label=Project]") !== null`), "the filter's select is hidden behind a combobox box labeled Project");
check(await boxText(F) === "All projects", "the box shows All projects", await boxText(F));

await type(F, "ep");
check((await listed(F))[0] === "astro", "ep: astro (key prefix EP) first", await listed(F));
await shot("filter-ep");
await press("Enter");
check(await ev(`state.project`) === "astro" && await boxText(F) === "astro" && !(await isOpen(F)), "Enter picks astro: the board filters to it and the list closes", [await ev(`state.project`), await boxText(F)]);

await type(F, "cl");
check((await listed(F))[0] === "cl-wrapper", "cl: cl-wrapper first", await listed(F));
await press("Enter");
check(await ev(`state.project`) === "cl-wrapper", "Enter picks cl-wrapper", await ev(`state.project`));

await type(F, "wrap");
check((await listed(F))[0] === "cl-wrapper", "wrap (part of the name): cl-wrapper first", await listed(F));
await type(F, "backend");
check(JSON.stringify(await listed(F)) === '["cross-current-backend"]', "backend (a word in the name): only cross-current-backend", await listed(F));
await type(F, "ccb");
check((await listed(F))[0] === "cross-current-backend", "ccb: cross-current-backend first", await listed(F));
await type(F, "zzz");
check((await listed(F)).length === 0 && await ev(`document.querySelector("#projectSel + ul li.none")?.textContent`) === "No project matches", "zzz: No project matches");
await press("Escape");
check(!(await isOpen(F)) && await boxText(F) === "cl-wrapper" && await ev(`state.project`) === "cl-wrapper", "Escape closes the list and the box shows the project still picked");
await type(F, "all");
await press("Enter");
check(await ev(`state.project`) === "", "all, Enter: back to All projects", await ev(`state.project`));
await ev(`document.activeElement.blur()`);

// New ticket: Escape closes the list, not the dialog; the change handler sees the pick.
await ev(`openNew()`);
await until(`document.getElementById("newDlg").open && document.querySelector("#newForm select[name=project][data-comboed]")`, "the New ticket dialog's combobox");
const N = "#newForm select[name=project]";
await type(N, "sd");
check((await listed(N))[0] === "screenreader-driver", "New ticket: sd lists screenreader-driver first", await listed(N));
await shot("new-sd");
await press("Escape");
check(await ev(`document.getElementById("newDlg").open`) && !(await isOpen(N)), "Escape closes the list and leaves the dialog open");
await type(N, "chart");
await press("Tab");
check(await ev(`document.querySelector(${JSON.stringify(N)}).value`) === "charts" && await boxText(N) === "charts", "Tab after typing picks charts", await boxText(N));
await ev(`document.querySelector("#newForm [name=title]").value = "Made in the combo test"`);
await ev(`document.querySelector("#newForm").requestSubmit()`);
await until(`state.data.tickets.some((r) => r.ticket.title === "Made in the combo test")`, "the new ticket");
check(await ev(`state.data.tickets.find((r) => r.ticket.title === "Made in the combo test").ticket.project`) === "charts", "the new ticket is in charts");

// A typed project counts without Enter: Ctrl+Enter, or clicking Create, creates the ticket there.
async function newWith(title) {
  await ev(`document.querySelectorAll("dialog[open]").forEach((d) => d.close()); openNew()`);
  await until(`document.getElementById("newDlg").open && document.querySelector("#newForm select[name=project][data-comboed]")`, "the New ticket dialog");
  await ev(`document.querySelector("#newForm [name=title]").value = ${JSON.stringify(title)}`);
}
const projectOf = async (title) => { await until(`state.data.tickets.some((r) => r.ticket.title === ${JSON.stringify(title)})`, title); return ev(`state.data.tickets.find((r) => r.ticket.title === ${JSON.stringify(title)}).ticket.project`); };
await newWith("Made with Ctrl+Enter");
await type(N, "ep");
for (const type of ["keyDown", "keyUp"]) await cdp.send("Input.dispatchKeyEvent", { type, key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, modifiers: 2 });
check(await projectOf("Made with Ctrl+Enter") === "astro", "ep, then Ctrl+Enter: the ticket is created in astro");
await newWith("Made with a click on Create");
await type(N, "cl");
const at = await ev(`(() => { const b = document.querySelector("#newForm [type=submit]"); b.scrollIntoView({ block: "center" }); const r = b.getBoundingClientRect();  return [r.x + r.width / 2, r.y + r.height / 2]; })()`);
for (const type of ["mousePressed", "mouseReleased"]) await cdp.send("Input.dispatchMouseEvent", { type, x: at[0], y: at[1], button: "left", clickCount: 1 });
check(await projectOf("Made with a click on Create") === "cl-wrapper", "cl, then a click on Create: the ticket is created in cl-wrapper");

// Ask: the box shows the project the dialog picked.
await ev(`document.querySelectorAll("dialog[open]").forEach((d) => d.close()); openAsk()`);
await until(`document.getElementById("askDlg").open`, "the Ask dialog");
const A = "#askForm select[name=project]";
check(await boxText(A) === await ev(`document.querySelector(${JSON.stringify(A)}).value`) && await boxText(A) !== "", "Ask: the box shows the picked project", await boxText(A));
// CL-187: the project box has the focus, its name selected, so typing replaces it; Tab goes on to the question.
check(await ev(`document.activeElement === document.querySelector(${JSON.stringify(A)}).previousElementSibling`), "Ask: the project box has the focus when it opens", await ev(`document.activeElement?.outerHTML.slice(0, 80)`));
check(await ev(`(() => { const b = document.activeElement; return b.selectionStart === 0 && b.selectionEnd === b.value.length && b.value.length > 0; })()`), "Ask: its name is selected");
await cdp.send("Input.insertText", { text: "ch" }); await sleep(80);
await press("Tab");
check(await ev(`document.querySelector(${JSON.stringify(A)}).value`) === "charts" && await ev(`document.activeElement === document.querySelector("#askForm [name=text]")`), "Ask: typing ch, then Tab picks charts and moves to the question", [await ev(`document.querySelector(${JSON.stringify(A)}).value`), await ev(`document.activeElement?.name`)]);
await ev(`document.getElementById("askDlg").close(); openAsk()`);
await until(`document.getElementById("askDlg").open`, "the Ask dialog again");
const before = await ev(`document.querySelector(${JSON.stringify(A)}).value`);
await press("Tab");
check(await ev(`document.querySelector(${JSON.stringify(A)}).value`) === before && await ev(`document.activeElement === document.querySelector("#askForm [name=text]")`) && !(await isOpen(A)), "Ask: Tab without typing keeps the project, closes the list and moves to the question");
// Escape: in any text box the first one only leaves the box (the board's capture-phase rule), the second closes the dialog.
// The same two presses as before CL-187, when the question box had the focus.
await press("Escape");
check(await ev(`document.getElementById("askDlg").open`) && await ev(`document.activeElement !== document.querySelector("#askForm [name=text]")`), "Ask: Escape in the question box leaves it; the dialog stays open");
await ev(`document.getElementById("askDlg").close(); openAsk()`);
await until(`document.getElementById("askDlg").open`, "the Ask dialog again");
await press("Escape");
check(await ev(`document.getElementById("askDlg").open`) && !(await isOpen(A)) && await ev(`!document.activeElement?.classList.contains("combo")`), "Ask: the first Escape closes the project list and leaves the box; the dialog stays open");
await press("Escape");
check(!(await ev(`document.getElementById("askDlg").open`)), "Ask: the second Escape closes the dialog");
await ev(`openAsk()`);
await until(`document.getElementById("askDlg").open`, "the Ask dialog again");
await type(A, "ep");
await press("Enter");
check(await ev(`document.querySelector(${JSON.stringify(A)}).value`) === "astro", "Ask: ep, Enter picks astro");
await ev(`document.getElementById("askDlg").close()`);

// Details: the box shows the ticket's project.
const key = await ev(`state.data.tickets.find((r) => r.ticket.title === "A chart ticket").ticket.key`);
await ev(`openTicket(${JSON.stringify(key)}, "details")`);
await until(`document.getElementById("ticketDlg").open`, "the ticket dialog");
await ev(`document.querySelector("#ticketDlg [data-tab=details]")?.click()`);
await until(`document.querySelector("#editForm select[name=project][data-comboed]")`, "the Details tab's combobox", 5000).catch(() => {});
const D = "#editForm select[name=project]";
check(await ev(`!!document.querySelector(${JSON.stringify(D)})`) && await boxText(D) === "charts", "Details: the box shows the ticket's project, charts", await ev(`document.querySelector(${JSON.stringify(D)}) ? 1 : 0`));
await type(D, "cl");
await shot("details-cl");
check((await listed(D))[0] === "cl-wrapper", "Details: cl lists cl-wrapper first", await listed(D));

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
