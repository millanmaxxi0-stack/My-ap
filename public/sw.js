// Service worker: enables REAL push notifications even when PeyamApp / the browser
// tab is completely closed. The browser itself wakes this worker up when a push
// arrives from the server (via the Push API), independent of any open page.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

// Legacy path: lets an open/foregrounded page ask the SW to show a notification directly.
self.addEventListener('message', (event) => {
  if (event.data && event.data.title) {
    self.registration.showNotification(event.data.title, {
      body: event.data.body || '',
      icon: '/icon.png',
      tag: event.data.tag || undefined,
      data: event.data
    });
  }
});

// Real push path: fired by the browser's push service when the server sends a
// notification, whether or not PeyamApp is open.
self.addEventListener('push', (event) => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch (e) { payload = { title: 'PeyamApp', body: event.data ? event.data.text() : '' }; }
  const title = payload.title || 'PeyamApp';
  const options = {
    body: payload.body || '',
    icon: '/icon.png',
    badge: '/icon.png',
    tag: payload.tag,
    data: payload,
    vibrate: [120, 60, 120],
    requireInteraction: !!payload.call
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

// Tapping the notification focuses (or opens) the app.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const clientsList = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of clientsList) {
      if ('focus' in client) { client.focus(); return; }
    }
    if (self.clients.openWindow) return self.clients.openWindow('/');
  })());
});
