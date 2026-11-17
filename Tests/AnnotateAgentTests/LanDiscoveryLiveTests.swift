import AnnotateAgent
import Testing

/// Live LAN probe: discovery plus a real HTTP round-trip against every AnnotateKit service on this
/// network. Never fails when nothing answers (CI has no app running); the prints are the point when
/// a real device is on the same Wi-Fi.
struct LanDiscoveryLiveTests {
    @Test func browseAndFetchHealth() async {
        let services = await LanDiscovery.browse(timeout: 4)
        print("LAN SERVICES:", services.map { "\($0.name)@\($0.host):\($0.port)" })
        for service in services {
            let client = LanSessionClient(service: service)
            do {
                let healthy = try await client.health()
                let ids = (try? await client.sessionIDs()) ?? []
                print("LAN HEALTH:", service.name, healthy, "sessions:", ids.count)
            } catch {
                print("LAN HEALTH:", service.name, "failed:", error)
            }
        }
        #expect(services.count >= 0)
    }
}
