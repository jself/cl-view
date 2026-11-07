// cl's service worker: shows push notifications (src/push.zig), acts on
// their buttons, and opens the board's compact view of the item when one is
// tapped. It caches nothing and has no fetch handler: the app is still the
// page served live.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

// The buttons: as many as the phone shows (Chrome on Android: two; iOS: none).
const buttons = (m) => (m.actions || []).slice(0, self.Notification?.maxActions ?? 2);

self.addEventListener("push", (e) => {
  let m;
  try { m = e.data.json(); } catch { m = { title: "cl", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(m.title || "cl", {
    body: m.body || "",
    // One per ticket: a newer one replaces it, and buzzes again.
    tag: m.tag || undefined,
    renotify: !!m.tag,
    icon: "/icon-192.png",
    timestamp: m.at ? m.at * 1000 : Date.now(),
    actions: buttons(m),
    data: m,
  }));
});

// What a button is doing, then what it did, in place of the notification
// (same tag, no buzz). Tapping it opens the item, as the first one did.
// `acted` marks these, so the cleanup below never closes a newer notification for the ticket.
const say = (m, body) => self.registration.showNotification(m.title || "cl", {
  body, tag: m.tag || undefined, renotify: false, silent: true, icon: "/icon-192.png", data: { ...m, actions: [], acted: true } });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// A button: do it now with the board's login (its cookie goes with the
// request), say so at once, then say how it went. Open boards refresh.
async function act(m, action) {
  const label = (m.actions || []).find((x) => x.action === action)?.title || action;
  await say(m, `${label}…`);
  let msg, ok = false;
  try {
    const r = await fetch("/api/needs/act", { method: "POST", credentials: "same-origin", headers: { "content-type": "application/json" },
      body: JSON.stringify({ item: m.item, action, ask: m.ask || "" }) });
    const j = await r.json().catch(() => ({}));
    if (r.status === 401) msg = "Not signed in on this phone: tap to open the board and sign in, then try again there";
    else if (!r.ok) msg = `Couldn't ${label.toLowerCase()}: ${j.error || r.statusText}. Tap to open it`;
    else { msg = `✓ ${j.message || label}`; ok = true; }
  } catch { msg = `Couldn't reach cl (offline?). Tap to open it`; }
  await say(m, msg);
  for (const c of await self.clients.matchAll({ type: "window", includeUncontrolled: true })) c.postMessage({ type: "refresh" });
  // Done: it clears itself after a moment, unless a newer one for the
  // ticket (Claude's next question) has replaced it. Failed: it stays to be tapped.
  if (ok) {
    await wait(4000);
    for (const n of await self.registration.getNotifications({ tag: m.tag })) if (n.data?.acted && n.data.item === m.item) n.close();
  }
}

// Tapped: an open board shows the item's compact view; otherwise the board
// opens on it.
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const m = e.notification.data || {};
  if (e.action) { e.waitUntil(act(m, e.action)); return; }
  const url = new URL(m.url || "/board", self.location.origin);
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const open = wins.find((c) => new URL(c.url).pathname === "/board");
    if (open) {
      await open.focus();
      open.postMessage({ type: "open", key: m.key || "", tab: url.searchParams.get("tab") || "", focus: url.searchParams.get("focus") === "1" });
      return;
    }
    await self.clients.openWindow(url.href);
  })());
});

// The browser renewed the subscription by itself: tell cl the new one, in
// place of the old (it keeps that device's name and on/off switch).
self.addEventListener("pushsubscriptionchange", (e) => {
  e.waitUntil((async () => {
    let sub = e.newSubscription;
    if (!sub) {
      const info = await (await fetch("/api/push", { cache: "no-store" })).json();
      sub = await self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: info.key });
    }
    const j = sub.toJSON();
    const r = await fetch("/api/push/subscribe", { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ endpoint: j.endpoint, keys: j.keys, name: "", old_endpoint: e.oldSubscription?.endpoint || "", tz_offset: -new Date().getTimezoneOffset() }) });
    // Removed from the list on the board: stay off.
    if (r.status === 410) await sub.unsubscribe();
  })().catch(() => {}));
});
