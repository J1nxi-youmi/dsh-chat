// 最小 service worker：只做「可安装」和外壳缓存。
// 消息、附件一律走网络，不从缓存里糊。
const CACHE = 'dsh-chat-v1';
const SHELL = ['./', './index.html', './app.js', './style.css', './manifest.webmanifest', './icon.svg'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).catch(() => {}));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))),
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== location.origin) return; // 后端请求一律直连
  if (url.pathname.includes('/api/') || url.pathname.includes('/media/')) return;

  event.respondWith(
    caches.match(request).then((hit) => hit || fetch(request).then((response) => {
      const copy = response.clone();
      caches.open(CACHE).then((cache) => cache.put(request, copy)).catch(() => {});
      return response;
    }).catch(() => caches.match('./index.html'))),
  );
});
