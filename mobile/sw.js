'use strict';

const CACHE_NAME = 'codex-usage-shell-v1';
const SHELL = [
  './', './index.html', './styles.css', './crypto.js', './model.js', './app.js', './manifest.webmanifest',
  './icons/icon-192.png', './icons/icon-512.png', './icons/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((names) => Promise.all(names.filter((name) => name !== CACHE_NAME).map((name) => caches.delete(name)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return; // Never cache ntfy responses or relay data.
  const shellUrl = new URL(url.href);
  shellUrl.search = '';
  shellUrl.hash = '';
  const isShell = SHELL.some((path) => new URL(path, self.location.href).href === shellUrl.href);
  if (!isShell) return;
  event.respondWith(caches.match(event.request, { ignoreSearch: true }).then((cached) => cached || fetch(event.request)));
});
