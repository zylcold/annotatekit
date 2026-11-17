// LAN delivery on the agent side: discover AnnotateKit's in-app service with Bonjour
// (NWBrowser, `_annotatekit._tcp`) and talk to it over HTTP instead of reading files. `pull`
// mirrors complete session bundles into a local directory in exactly the layout `SessionWriter`
// produces, so every existing consumer (watch, MCP tools, headless run) keeps working unchanged.
// ponytail: plain HTTP, first service wins; add service selection + pairing when several apps run.

import AnnotateCore
import Foundation
import Network

public struct LanService: Sendable, Equatable {
    public let name: String
    public let host: String
    public let port: UInt16
}

public actor LanServiceRegistry {
    private var services: [LanService] = []
    private var finished = false
    private var continuation: CheckedContinuation<[LanService], Never>?

    func add(_ service: LanService) {
        guard !services.contains(service) else { return }
        services.append(service)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: services)
        continuation = nil
    }

    func awaitResult() async -> [LanService] {
        if finished { return services }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if self.finished { continuation.resume(returning: self.services) }
        }
    }
}

public enum LanDiscovery {
    /// Browses for `timeout` seconds and returns every AnnotateKit service found on the LAN.
    public static func browse(timeout: TimeInterval = 2, type: String = SessionHTTP.bonjourType) async -> [LanService] {
        let registry = LanServiceRegistry()
        let queue = DispatchQueue(label: "annotate.lan.browse")
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                resolve(endpoint: result.endpoint, name: name, queue: queue) { service in
                    Task { if let service { await registry.add(service) } }
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { Task { await registry.finish() } }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            browser.cancel()
            Task { await registry.finish() }
        }
        return await registry.awaitResult()
    }

    private static func resolve(endpoint: NWEndpoint, name: String, queue: DispatchQueue, onResolved: @escaping @Sendable (LanService?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let inner = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = inner {
                    onResolved(LanService(name: name, host: hostString(host), port: port.rawValue))
                } else {
                    onResolved(nil)
                }
                connection.cancel()
            case .failed, .cancelled:
                onResolved(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }
}

public struct LanSessionClient: Sendable {
    public let service: LanService
    private let session: URLSession

    public init(service: LanService) {
        self.service = service
        self.session = URLSession(configuration: .ephemeral)
    }

    private func url(_ path: String) -> URL {
        URL(string: "http://\(service.host):\(service.port)\(path)")!
    }

    public func health() async throws -> Bool {
        let (data, response) = try await session.data(from: url("/health"))
        return (response as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty
    }

    public struct RemoteSession: Codable, Sendable {
        public let sessions: [String]
    }

    public func sessionIDs() async throws -> [String] {
        let (data, _) = try await session.data(from: url("/sessions"))
        return try JSONDecoder().decode(RemoteSession.self, from: data).sessions
    }

    public func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(from: url(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func post(_ path: String, body: Data) async throws {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// Mirrors complete remote bundles into `directory` in the SessionWriter layout, skipping ones
    /// already present (session.json is the completeness marker, same as locally written bundles).
    public func mirror(sessions ids: [String], into directory: URL, fileManager: FileManager = .default) async throws -> [String] {
        var pulled: [String] = []
        for id in ids {
            let target = SessionInbox.sessionDirectory(id, in: directory)
            let marker = target.appendingPathComponent("session.json")
            if fileManager.fileExists(atPath: marker.path) { continue }
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

            let manifest = try await get("/sessions/\(id)/manifest")
            let prompt = try await get("/sessions/\(id)/prompt")
            try manifest.write(to: marker, options: .atomic)
            try prompt.write(to: target.appendingPathComponent("prompt.md"), options: .atomic)

            for path in imagePaths(in: manifest) {
                let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
                guard let data = try? await get("/sessions/\(id)/files/\(rel)") else { continue }
                let dest = target.appendingPathComponent(rel)
                try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
            }
            pulled.append(id)
        }
        return pulled
    }

    private func imagePaths(in manifest: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else { return [] }
        var paths: [String] = []
        if let screens = obj["screens"] as? [[String: Any]] {
            for screen in screens {
                for key in ["file", "annotatedFile", "scaleFile"] {
                    if let f = screen[key] as? String { paths.append(f) }
                }
            }
        }
        return paths
    }
}
