// Offline support for the installed app (iOS and Android home screen).
// Results (data*.js) and pages come from the network first, so prices and new versions show at once, falling back to
// the last copy when offline; icons, logos and photos come from the cache first and are refreshed in the background.
// Bump when the pages change a lot, so installed apps drop the old copies at once.
const CACHE = 'stock-radar-v13';
const SHELL = ['./', './index.html', './browse.html', './deals.html', './radar3d.js', './manifest.webmanifest', './favicon.svg', './icon-192.png', './brand/mark.svg'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;   // store links and images elsewhere: untouched
  if (/\/data(-\w+)?\.js$/.test(url.pathname)) {
    // Only good answers are kept; a failed one falls back to the last good copy.
    e.respondWith(fetch(e.request).then(res => {
      if (!res.ok) return caches.match(url.pathname).then(hit => hit || res);
      const copy = res.clone(); caches.open(CACHE).then(c => c.put(url.pathname, copy)); return res;
    }).catch(() => caches.match(url.pathname)));
    return;
  }
  // Pages come from the network first too, so a new version shows at once (no-cache asks GitHub each time instead of
  // using the browser's 10-minute copy); the cached copy, one per page, is for offline use.
  if (e.request.mode === 'navigate' || /\.html$|\/$/.test(url.pathname)) {
    e.respondWith(fetch(url.href, { cache: 'no-cache' }).then(res => {
      if (res.redirected) return fetch(e.request);   // a navigation may not be answered with a redirected response
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(url.pathname, copy)); }
      return res;
    }).catch(() => caches.match(url.pathname, { ignoreSearch: true })));
    return;
  }
  e.respondWith(caches.match(e.request, { ignoreSearch: true }).then(hit => {
    const fresh = fetch(e.request).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
      return res;
    }).catch(() => hit);
    return hit || fresh;
  }));
});
