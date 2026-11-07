// cl's service worker: shows push notifications (src/push.zig) and opens the
// board on the ticket when one is tapped. It caches nothing and has no fetch
// handler: the app is still the page served live.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

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
    data: m,
  }));
});

// Tapped: an open board shows the ticket; otherwise the board opens on it.
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const m = e.notification.data || {};
  const url = new URL(m.url || "/board", self.location.origin).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const open = wins.find((c) => new URL(c.url).pathname === "/board");
    if (open) {
      await open.focus();
      open.postMessage({ type: "open", key: m.key || "", tab: new URL(url).searchParams.get("tab") || "" });
      return;
    }
    await self.clients.openWindow(url);
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
