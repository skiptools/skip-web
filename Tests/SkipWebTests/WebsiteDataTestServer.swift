// Copyright 2026-2026 Skip
// SPDX-License-Identifier: MPL-2.0
import Foundation
#if !SKIP && os(iOS)
import Network
#endif

#if SKIP || os(iOS)
/// On-device loopback fixture shared by website-data tests. Each instance owns an ephemeral
/// port and request counters, so tests need neither a host process nor Android port forwarding.
// Request counts/errors use `lock`; Apple connections and startup state use `queue`.
// Android socket operations are thread-safe; only the test owner starts/stops the worker.
final class WebsiteDataTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var servingError: String?
    #if SKIP
    private let socket: java.net.ServerSocket
    private var worker: java.lang.Thread?
    #else
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SkipWebTests.WebsiteDataTestServer")
    private var connections: [NWConnection] = []
    private var startupContinuation: CheckedContinuation<URL, Error>?
    #endif

    init() throws {
        #if SKIP
        socket = java.net.ServerSocket(0, 16, java.net.InetAddress.getByName("127.0.0.1"))
        #else
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receiveRequest(connection, received: Data())
        }
        #endif
    }

    /// Starts listening before returning the fixture URL. Apple startup has a five-second limit.
    func start() async throws -> URL {
        #if SKIP
        let worker = java.lang.Thread { self.serveAndroidConnections() }
        worker.setDaemon(true)
        self.worker = worker
        worker.start()
        return URL(string: "http://127.0.0.1:\(socket.localPort)/fixture")!
        #else
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startupContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.finishStarting(.success(URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/fixture")!))
                    case .failed(let error):
                        self.finishStarting(.failure(error))
                    default:
                        break
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.startupContinuation != nil else { return }
                    self.listener.cancel()
                    self.finishStarting(.failure(URLError(.timedOut)))
                }
                self.listener.start(queue: self.queue)
            }
        }
        #endif
    }

    /// Closes the listening socket and connections before the test releases the fixture.
    func stop() {
        #if SKIP
        socket.close()
        worker?.join(6_000)
        #else
        queue.sync {
            listener.cancel()
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
        #endif
    }

    /// Counts actual network requests, independently of the value returned by the page's cache.
    func requestCount(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path] ?? 0
    }

    var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        let requests = counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ", ")
        return "requests=[\(requests)] serverError=\(servingError ?? "none")"
    }

    private func response(for requestLine: String) -> String {
        let parts = requestLine.components(separatedBy: " ")
        let path = parts.count > 1 ? parts[1] : "/"
        lock.lock()
        let count = (counts[path] ?? 0) + 1
        counts[path] = count
        lock.unlock()
        let body: String
        let mime: String
        let cacheControl: String
        if path.hasPrefix("/cache?") || path.hasPrefix("/http-cache") {
            body = String(count)
            mime = "text/plain"
            cacheControl = "public, max-age=3600"
        } else if path == "/worker.js" {
            body = "self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));"
            mime = "text/javascript"
            cacheControl = "no-store"
        } else {
            body = Self.document
            mime = "text/html"
            cacheControl = "no-store"
        }
        return "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: \(cacheControl)\r\nConnection: close\r\n\r\n\(body)"
    }

    #if SKIP
    private func serveAndroidConnections() {
        while !socket.isClosed {
            do {
                let connection = socket.accept()
                try respondToAndroidConnection(connection)
            } catch {
                if !socket.isClosed {
                    lock.lock()
                    servingError = String(describing: error)
                    lock.unlock()
                }
                return
            }
        }
    }

    private func respondToAndroidConnection(_ connection: java.net.Socket) throws {
        defer { connection.close() }
        connection.soTimeout = 5_000
        let reader = java.io.BufferedReader(java.io.InputStreamReader(connection.getInputStream()))
        let requestLine = reader.readLine() ?? ""
        while let header = reader.readLine(), !header.isEmpty { }
        let bytes = response(for: requestLine).toByteArray(java.nio.charset.StandardCharsets.UTF_8)
        connection.getOutputStream().write(bytes)
    }
    #else
    /// Called only on `queue`, consuming readiness or timeout exactly once.
    private func finishStarting(_ result: Result<URL, Error>) {
        let continuation = startupContinuation
        startupContinuation = nil
        continuation?.resume(with: result)
    }

    private func receiveRequest(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = received
            if let data { request.append(data) }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil || request.count > 16_384 {
                    self.close(connection)
                } else {
                    self.receiveRequest(connection, received: request)
                }
                return
            }
            let requestLine = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0]
            let response = self.response(for: requestLine)
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                self?.close(connection)
            })
        }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }
    #endif

    private static let document = """
    <!doctype html><html><body>Clear Data fixture<script>
    function fixtureEvent(message) {
      window.fixtureEvents.push(Math.round(performance.now() - window.fixtureStarted) + 'ms ' + message);
    }
    async function fixtureAwait(stage, action) {
      fixtureEvent('BEGIN ' + stage);
      try {
        const result = await action();
        fixtureEvent('END ' + stage);
        return result;
      } catch (error) {
        fixtureEvent('ERROR ' + stage + ': ' + String(error));
        throw error;
      }
    }
    function database() {
      return new Promise((resolve, reject) => {
        const request = indexedDB.open('clear-data-fixture', 1);
        request.onupgradeneeded = () => {
          fixtureEvent('database upgrade needed');
          request.result.createObjectStore('values');
        };
        request.onblocked = () => fixtureEvent('database open blocked');
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
    }
    async function seed(value, key) {
      fixtureEvent('seed cookie/localStorage/sessionStorage');
      document.cookie = 'fixture=' + value + '; path=/';
      localStorage.setItem('fixture', value);
      sessionStorage.setItem('fixture', value);
      const db = await fixtureAwait('database open', () => database());
      await fixtureAwait('seed transaction complete', () => new Promise((resolve, reject) => {
        const tx = db.transaction('values', 'readwrite');
        tx.objectStore('values').put(value, 'fixture');
        tx.oncomplete = resolve; tx.onerror = () => reject(tx.error);
        tx.onabort = () => fixtureEvent('seed transaction aborted: ' + String(tx.error));
      }));
      db.close();
      fixtureEvent('database close');
      await cachedValue(key);
    }
    async function cachedValue(key) {
      const response = await fixtureAwait('cache fetch headers', () => fetch('/cache?key=' + key));
      fixtureEvent('cache HTTP status=' + response.status);
      return await fixtureAwait('cache response text', () => response.text());
    }
    async function read(key) {
      const db = await fixtureAwait('database open', () => database());
      const indexed = await fixtureAwait('read indexed value', () => new Promise((resolve, reject) => {
        const tx = db.transaction('values');
        tx.onabort = () => fixtureEvent('read transaction aborted: ' + String(tx.error));
        const request = tx.objectStore('values').get('fixture');
        request.onsuccess = () => resolve(request.result || '');
        request.onerror = () => reject(request.error);
      }));
      db.close();
      fixtureEvent('database close; read cookie/localStorage/sessionStorage');
      return { cookie: document.cookie, local: localStorage.getItem('fixture') || '',
        session: sessionStorage.getItem('fixture') || '', indexed: indexed,
        cache: await cachedValue(key) };
    }
    </script></body></html>
    """
}
#endif
