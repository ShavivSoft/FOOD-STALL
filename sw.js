// Service worker: shows the "order ready" push even when the page is closed.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { title: 'Your order is ready!', body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Your order is ready!', {
    body: d.body || 'Please collect your food at the counter.',
    tag: d.tag || 'order', renotify: true, requireInteraction: true,
    vibrate: [300, 100, 300, 100, 300],
    icon: 'icon-192.png', badge: 'icon-192.png',
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = e.notification.data && e.notification.data.url || './';
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) if (c.url === url && 'focus' in c) return c.focus();
    return self.clients.openWindow(url);
  })());
});
