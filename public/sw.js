const CACHE = "xixo-shell-2"
const OFFLINE = "/offline.html"
const KEPT = [OFFLINE, "/icon.svg"]

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(KEPT)).then(() => self.skipWaiting()))
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener("fetch", (event) => {
  const { request } = event
  if (request.method !== "GET" || request.mode !== "navigate") return
  if (new URL(request.url).origin !== self.location.origin) return

  event.respondWith(fetch(request).catch(() => caches.match(OFFLINE)))
})
