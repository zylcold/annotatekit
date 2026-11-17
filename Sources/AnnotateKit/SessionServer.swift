// The in-app half of the LAN delivery mode: an HTTP server on the device/Simulator that serves the
// annotation store and advertises itself over Bonjour as `_annotatekit._tcp`, so an agent on the
// same network can discover it without any file sharing. Compiled only into DEBUG builds; the
// local-file and developer-connection paths stay as they are.
// ponytail: single-client HTTP/1.1, no TLS — LAN debug traffic only; upgrade to a framed protocol
// if this ever leaves DEBUG.
// Compiled in every configuration because Swift packages are often built without -DDEBUG (Xcode
// doesn't pass the app's DEBUG define down to package targets); only `OverlayInstaller`'s DEBUG-only
// install path ever starts it, so Release builds ship the code but never open a socket.

#if canImport(Network)
import AnnotateCore
import Foundation
import Network

public final class SessionServer: @unchecked Sendable {
    public static let shared = SessionServer()

    private let queue = DispatchQueue(label: "annotatekit.session-server")
    private var listener: NWListener?
    private var storeDirectory: URL?

    private init() {}

    /// Starts (or restarts) the server on an ephemeral port and advertises it via Bonjour.
    /// `appName` becomes the service name so several apps on one network stay tellable apart.
    @MainActor
    public func start(storeDirectory: URL, appName: String = "AnnotateKit") {
        stop()
        var record = NWTXTRecord()
        record["app"] = appName
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.service = NWListener.Service(name: appName, type: SessionHTTP.bonjourType, txtRecord: record)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? DispatchQueue(label: "annotatekit.session-server.conn"))
            SessionServer.receive(on: connection, store: self?.storeDirectory)
        }
        self.storeDirectory = storeDirectory
        self.listener = listener
        listener.start(queue: queue)
    }

    @MainActor
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func receive(on connection: NWConnection, store: URL?) {
        receiveHeader(on: connection, accumulated: Data(), store: store)
    }

    private static func receiveHeader(on connection: NWConnection, accumulated: Data, store: URL?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard error == nil else { connection.cancel(); return }
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { receiveHeader(on: connection, accumulated: buffer, store: store) }
                return
            }
            let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { connection.cancel(); return }
            let contentLength = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            receiveBody(on: connection, method: String(parts[0]), path: String(parts[1]),
                        expected: contentLength, body: Data(buffer[range.upperBound...]), store: store)
        }
    }

    private static func receiveBody(on connection: NWConnection, method: String, path: String, expected: Int, body: Data, store: URL?) {
        if body.count < expected {
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(expected - body.count, 1)) { data, _, isComplete, error in
                guard error == nil else { connection.cancel(); return }
                var grown = body
                if let data { grown.append(data) }
                if isComplete && grown.count < expected { connection.cancel(); return }
                receiveBody(on: connection, method: method, path: path, expected: expected, body: grown, store: store)
            }
            return
        }
        let directory = store ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let request = SessionHTTP.Request(method: method, path: path, body: body)
        let response = SessionHTTP.respond(to: request, storeDirectory: directory)
        var head = "HTTP/1.1 \(response.status) OK\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
