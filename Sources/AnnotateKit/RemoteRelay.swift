// Remote delivery: the app uploads each session bundle to a relay on the internet, so an agent works
// even when the phone isn't on the same Wi-Fi (cellular, different network, CI machine elsewhere).
// Configured at launch, never compiled in:
//   • launch arguments:  -annotateRelay https://host -annotateRelayKey <key>
//   • environment:       ANNOTATE_RELAY_URL, ANNOTATE_RELAY_KEY
// Without either, nothing changes: the local-file and LAN paths behave exactly as before.
// ponytail: one bundle per upload, no chunked resume — annotation bundles are a few MB at most.

import AnnotateCore
import Foundation

public struct RemoteRelay: Sendable {
    public let baseURL: URL
    public let key: String

    public init?(baseURL: URL, key: String) {
        guard !key.isEmpty else { return nil }
        self.baseURL = baseURL
        self.key = key
    }

    /// Reads the launch configuration; nil when the app wasn't started with a relay.
    public static func fromLaunchArguments(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RemoteRelay? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let urlString = value(after: "-annotateRelay") ?? environment["ANNOTATE_RELAY_URL"]
        let key = value(after: "-annotateRelayKey") ?? environment["ANNOTATE_RELAY_KEY"]
        guard let urlString, let url = URL(string: urlString), let key else { return nil }
        return RemoteRelay(baseURL: url, key: key)
    }

    /// Uploads one bundle: every file under the session directory, base64 in one JSON body.
    public func upload(sessionDirectory: URL, fileManager: FileManager = .default) async throws {
        let id = sessionDirectory.lastPathComponent
        // Collect synchronously: FileManager's enumerator can't be iterated from async contexts.
        var files: [String: String] = [:]
        let collected: [String: Data] = Self.readBundleFiles(in: sessionDirectory, fileManager: fileManager)
        for (relative, data) in collected {
            files[relative] = data.base64EncodedString()
        }
        guard !files.isEmpty else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/sessions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "files": files])
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// The relay's view of a listening agent (agent heartbeat). Decoded loosely: the relay augments
    /// the agent's JSON with an ISO timestamp of its own.
    public struct RemotePresence: Sendable {
        public var agent: String?
        public var mode: String?
        public var via: String?
        public var receivedAt: Date?
    }

    public func presence() async -> RemotePresence? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/presence"))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var presence = RemotePresence(
            agent: object["agent"] as? String,
            mode: object["mode"] as? String,
            via: object["via"] as? String,
            receivedAt: (object["receivedAt"] as? String).flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
        )
        if presence.receivedAt == nil, let epoch = object["receivedAtEpoch"] as? Double {
            presence.receivedAt = Date(timeIntervalSince1970: epoch)
        }
        return presence
    }

    /// Polls the relay and mirrors a live agent into the store's heartbeat file, so the launcher dot
    /// logic works unchanged in relay mode.
    public func bridgePresence(into storeDirectory: URL, interval: Duration = .seconds(5)) async {
        while !Task.isCancelled {
            if let presence = await presence(), let agent = presence.agent, let mode = presence.mode,
               let received = presence.receivedAt, Date().timeIntervalSince(received) < 20 {
                let payload: [String: Any] = [
                    "agent": agent,
                    "mode": mode,
                    "via": presence.via ?? "relay",
                    "updatedAt": Date().timeIntervalSince1970,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
                    try? data.write(to: storeDirectory.appendingPathComponent("agent.json"), options: .atomic)
                }
            }
            try? await Task.sleep(for: interval)
        }
    }

    public func reportStatus(_ status: SessionStatus, sessionDirectory: URL) async {
        let id = sessionDirectory.lastPathComponent
        guard let data = try? JSONEncoder().encode(status) else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/sessions/\(id)/status.json"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func readBundleFiles(in directory: URL, fileManager: FileManager) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return result }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let relative = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            guard relative != "status.json", let data = try? Data(contentsOf: fileURL) else { continue }
            result[relative] = data
        }
        return result
    }
}
