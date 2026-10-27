// Offline support for the installed app (iOS and Android home screen).
// Results (data*.js) come from the network first so prices are fresh, falling back to the last copy when offline;
// pages, icons, logos and photos come from the cache first and are refreshed in the background.
// Bump when the pages change a lot, so installed apps drop the old copies at once.
const CACHE = 'stock-radar-v10';
const SHELL = ['./', './index.html', './browse.html', './deals.html', './manifest.webmanifest', './favicon.svg', './icon-192.png', './brand/mark.svg'];

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
  e.respondWith(caches.match(e.request, { ignoreSearch: true }).then(hit => {
    const fresh = fetch(e.request).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
      return res;
    }).catch(() => hit);
    return hit || fresh;
  }));
});
