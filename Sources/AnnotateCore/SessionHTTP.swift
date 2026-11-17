// HTTP surface of the annotation store, shared by the in-app service (AnnotateKit.SessionServer)
// and LAN clients. Pure request/response bytes so it is unit-testable without sockets:
//   GET  /health
//   GET  /sessions                       → {"sessions":["<id>", …]} newest first, complete only
//   GET  /sessions/<id>/manifest         → session.json bytes
//   GET  /sessions/<id>/prompt           → prompt.md bytes
//   GET  /sessions/<id>/files/<rel>      → any file in the bundle (screens, crops, replies.json)
//   POST /sessions/<id>/status           → body is a SessionStatus JSON; written as status.json
//   POST /sessions/<id>/replies          → body is one Reply JSON; appended to replies.json
// Paths are validated against traversal (".." and absolute segments are rejected).

import Foundation

public enum SessionHTTP {
    public static let bonjourType = "_annotatekit._tcp"

    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var body: Data
        public init(method: String, path: String, body: Data = Data()) {
            self.method = method
            self.path = path
            self.body = body
        }
    }

    public struct Response: Sendable, Equatable {
        public var status: Int
        public var contentType: String
        public var body: Data
        public init(status: Int, contentType: String = "application/json; charset=utf-8", body: Data = Data()) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }
        public static func json(_ value: some Encodable, status: Int = 200) -> Response {
            guard let data = try? JSONEncoder().encode(value) else {
                return Response(status: 500, body: Data("{\"error\":\"encode failed\"}".utf8))
            }
            return Response(status: status, body: data)
        }
        public static let notFound = Response(status: 404, body: Data("{\"error\":\"not found\"}".utf8))
        public static let badRequest = Response(status: 400, body: Data("{\"error\":\"bad request\"}".utf8))
        public static let methodNotAllowed = Response(status: 405, body: Data("{\"error\":\"method not allowed\"}".utf8))
        public static let ok = Response(status: 200, body: Data("{\"ok\":true}".utf8))
    }

    private struct SessionList: Encodable { let sessions: [String] }

    /// Routes one request against the annotation store at `storeDirectory`.
    public static func respond(to request: Request, storeDirectory: URL, fileManager: FileManager = .default) -> Response {
        let segments = request.path.split(separator: "/").map(String.init)
        guard !segments.contains(where: { $0 == ".." || $0.hasPrefix("/") }) else { return .badRequest }

        if segments == ["health"] {
            guard request.method == "GET" else { return .methodNotAllowed }
            return .ok
        }
        if segments == ["sessions"] {
            guard request.method == "GET" else { return .methodNotAllowed }
            let ids = SessionInbox.sessionIDs(in: storeDirectory).filter {
                fileManager.fileExists(atPath: SessionInbox.sessionDirectory($0, in: storeDirectory)
                    .appendingPathComponent("session.json").path)
            }
            return .json(SessionList(sessions: ids.reversed()))
        }
        guard segments.count >= 2, segments[0] == "sessions" else { return .notFound }
        let id = segments[1]
        let sessionDir = SessionInbox.sessionDirectory(id, in: storeDirectory)
        let sessionMarker = sessionDir.appendingPathComponent("session.json")

        switch (request.method, segments[2]) {
        case ("GET", "manifest"):
            return fileResponse(at: sessionMarker)
        case ("GET", "prompt"):
            return fileResponse(at: sessionDir.appendingPathComponent("prompt.md"), contentType: "text/markdown; charset=utf-8")
        case ("GET", "files"):
            let rest = segments.dropFirst(3)
            guard !rest.isEmpty else { return .badRequest }
            let url = sessionDir.appendingPathComponent(rest.joined(separator: "/"))
            return fileResponse(at: url)
        case ("POST", "status"):
            guard request.method == "POST" else { return .methodNotAllowed }
            let decoder = JSONDecoder()
            guard var status = try? decoder.decode(SessionStatus.self, from: request.body) else { return .badRequest }
            status.updatedAt = Date()
            guard let data = try? JSONEncoder().encode(status) else { return .badRequest }
            do {
                try data.write(to: sessionDir.appendingPathComponent("status.json"), options: .atomic)
                return .ok
            } catch { return Response(status: 500, body: Data("{\"error\":\"write failed\"}".utf8)) }
        case (_, "replies"):
            guard request.method == "POST" else { return .methodNotAllowed }
            do {
                let replies = sessionDir.appendingPathComponent("replies.json")
                var existing = Data()
                if fileManager.fileExists(atPath: replies.path) { existing = try Data(contentsOf: replies) }
                var newline = request.body
                if !existing.isEmpty && existing.last != UInt8(ascii: "\n") { existing.append(0x0A) }
                existing.append(newline)
                if newline.last != UInt8(ascii: "\n") { existing.append(0x0A) }
                try existing.write(to: replies, options: .atomic)
                return .ok
            } catch { return Response(status: 500, body: Data("{\"error\":\"write failed\"}".utf8)) }
        default:
            return .notFound
        }
    }

    private static func fileResponse(at url: URL, contentType: String = "application/octet-stream") -> Response {
        guard let data = try? Data(contentsOf: url) else { return .notFound }
        return Response(status: 200, contentType: contentType, body: data)
    }
}
