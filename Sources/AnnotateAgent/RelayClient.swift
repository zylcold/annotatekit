// Agent side of the remote delivery mode: pull bundles from a relay published through a tunnel,
// authenticated with the per-run key. Mirrors into the same on-disk layout as the LAN and local
// modes, so watch / MCP tools / headless runs need no changes.
// ponytail: plain polling, whole-bundle fetch; switch to incremental sync if bundles get big.

import AnnotateCore
import Foundation

public struct RelayClient: Sendable {
    public let baseURL: URL
    public let key: String

    public init?(url: String, key: String) {
        guard let baseURL = URL(string: url), !key.isEmpty else { return nil }
        self.baseURL = baseURL
        self.key = key
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    public func sessionIDs() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: request("v1/sessions"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Sessions: Decodable { let sessions: [String] }
        return try JSONDecoder().decode(Sessions.self, from: data).sessions
    }

    public func get(_ path: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    public func post(_ path: String, body: Data) async throws {
        var request = request(path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    /// Mirrors complete remote bundles into `directory`; session.json marks completeness, matching
    /// the local writer, so SessionFeed picks them up unchanged.
    public func mirror(sessions ids: [String], into directory: URL, fileManager: FileManager = .default) async throws -> [String] {
        var pulled: [String] = []
        for id in ids {
            let target = SessionInbox.sessionDirectory(id, in: directory)
            let marker = target.appendingPathComponent("session.json")
            if fileManager.fileExists(atPath: marker.path) { continue }
            let manifest = try await get("v1/sessions/\(id)/session.json")
            let prompt = try await get("v1/sessions/\(id)/prompt.md")
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try manifest.write(to: marker, options: .atomic)
            try prompt.write(to: target.appendingPathComponent("prompt.md"), options: .atomic)

            guard let obj = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
                  let screens = obj["screens"] as? [[String: Any]] else {
                pulled.append(id)
                continue
            }
            for screen in screens {
                for key in ["file", "annotatedFile", "scaleFile"] {
                    guard let rel = screen[key] as? String else { continue }
                    guard let data = try? await get("v1/sessions/\(id)/\(rel)") else { continue }
                    let dest = target.appendingPathComponent(rel)
                    try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: dest, options: .atomic)
                }
            }
            pulled.append(id)
        }
        return pulled
    }
}
