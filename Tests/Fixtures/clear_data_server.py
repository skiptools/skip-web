#!/usr/bin/env python3
"""Deterministic website fixture for profile-specific Clear Data instrumentation.

Run on the host, then adb reverse tcp:18769 tcp:18769 for Android.
Each cache URL returns an increasing number only when it reaches the server.
"""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import urlsplit

counts = Counter()
lock = Lock()
DOCUMENT = b'''<!doctype html><html><body>Clear Data fixture<script>
function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('clear-data-fixture', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('values');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function seed(value, key) {
  document.cookie = 'fixture=' + value + '; path=/';
  localStorage.setItem('fixture', value);
  sessionStorage.setItem('fixture', value);
  const db = await database();
  await new Promise((resolve, reject) => {
    const tx = db.transaction('values', 'readwrite');
    tx.objectStore('values').put(value, 'fixture');
    tx.oncomplete = resolve; tx.onerror = () => reject(tx.error);
  });
  db.close();
  await fetch('/cache?key=' + key).then(r => r.text());
}
async function read(key) {
  const db = await database();
  const indexed = await new Promise((resolve, reject) => {
    const request = db.transaction('values').objectStore('values').get('fixture');
    request.onsuccess = () => resolve(request.result || '');
    request.onerror = () => reject(request.error);
  });
  db.close();
  return { cookie: document.cookie, local: localStorage.getItem('fixture') || '',
    session: sessionStorage.getItem('fixture') || '', indexed: indexed,
    cache: await fetch('/cache?key=' + key).then(r => r.text()) };
}
</script></body></html>'''

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if urlsplit(self.path).path == '/cache':
            with lock:
                counts[self.path] += 1
                body = str(counts[self.path]).encode()
            mime, cache = 'text/plain', 'public, max-age=3600'
        else:
            body, mime, cache = DOCUMENT, 'text/html', 'no-store'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', cache)
        self.end_headers()
        self.wfile.write(body)

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 18769), Handler).serve_forever()
