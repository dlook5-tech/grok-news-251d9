// Service Worker for eXpressO News
// Strategy: always fetch HTML + stories.json from network (never cache).
// Cache images long-term for speed. Auto-take-over on install.
// BUILD: 20260428140806   ← deploy.sh stamps this so browsers detect a new SW each deploy

const BUILD = '20260511165954';
const STATIC_CACHE = 'expresso-static-' + BUILD;

self.addEventListener('install', (event) => {
  // Take over immediately — don't wait for old SW to die
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      // Claim all open pages immediately
      await self.clients.claim();
      // Nuke every cache we previously had. Clean slate.
      const keys = await caches.keys();
      await Promise.all(keys.map(k => caches.delete(k)));
      // Tell every client to reload so they get fresh HTML/JSON.
      const clients = await self.clients.matchAll({ type: 'window' });
      for (const client of clients) {
        client.postMessage({ type: 'SW_UPDATED', build: BUILD });
      }
    })()
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Same-origin only
  if (url.origin !== self.location.origin) return;

  const isHTML = req.mode === 'navigate' || url.pathname === '/' || url.pathname.endsWith('.html');
  const isData = url.pathname.endsWith('/stories.json') || url.pathname.endsWith('/version.txt');

  if (isHTML || isData) {
    // Network-first: never serve stale HTML or data
    event.respondWith(
      fetch(req, { cache: 'reload' }).catch(() => new Response('Offline. Reconnect to see latest.', { status: 503 }))
    );
    return;
  }

  if (url.pathname.startsWith('/images/')) {
    // Images: cache-first for speed
    event.respondWith(
      caches.open(STATIC_CACHE).then(async (cache) => {
        const cached = await cache.match(req);
        if (cached) return cached;
        const resp = await fetch(req);
        if (resp.ok) cache.put(req, resp.clone());
        return resp;
      })
    );
    return;
  }

  // Everything else: network-first with fallback
  event.respondWith(fetch(req).catch(() => caches.match(req)));
});
