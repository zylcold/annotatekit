import AnnotateCore
import Foundation
import Testing

struct SessionHTTPTests {
    @Test func routesHealthAndRejectsTraversal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ak-http-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(SessionHTTP.respond(to: .init(method: "GET", path: "/health"), storeDirectory: dir).status == 200)
        #expect(SessionHTTP.respond(to: .init(method: "GET", path: "/sessions/../../etc/passwd/files/x"), storeDirectory: dir).status == 400)
        #expect(SessionHTTP.respond(to: .init(method: "POST", path: "/health"), storeDirectory: dir).status == 405)
    }

    @Test func listsAndServeBundle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ak-http-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = AnnotationSession(
            id: SessionWriter.makeSessionID(date: Date(), suffix: "test"),
            createdAt: Date(),
            app: AppInfo(),
            device: DeviceInfo(model: "iPhone", systemName: "iOS", systemVersion: "26.0", isSimulator: false,
                               screen: AnnotationSize(width: 393, height: 852), scale: 3, colorScheme: "dark",
                               contentSize: "L", orientation: "portrait"),
            screens: [],
            annotations: []
        )
        let bundle = SessionBundle(session: session, images: ["crops/1.png": Data([1, 2, 3])])
        let written = try SessionWriter.write(bundle, prompt: "# hello", to: dir)
        let id = written.lastPathComponent

        let list = SessionHTTP.respond(to: .init(method: "GET", path: "/sessions"), storeDirectory: dir)
        #expect(String(data: list.body, encoding: .utf8)?.contains(id) == true)

        let prompt = SessionHTTP.respond(to: .init(method: "GET", path: "/sessions/\(id)/prompt"), storeDirectory: dir)
        #expect(String(data: prompt.body, encoding: .utf8) == "# hello")

        let crop = SessionHTTP.respond(to: .init(method: "GET", path: "/sessions/\(id)/files/crops/1.png"), storeDirectory: dir)
        #expect(crop.body == Data([1, 2, 3]))
    }
}
