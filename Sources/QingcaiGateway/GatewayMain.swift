import Foundation
import QingcaiGatewayKit

struct Startup: Decodable { let token: String; let port: UInt16; let databasePath: String; let mode: String }

@main struct GatewayMain {
    static func main() async {
        // Configuration is received through a private stdin pipe, never argv or logs.
        guard let line = readLine(), line.utf8.count <= 8192, let data = line.data(using: .utf8), let config = try? JSONDecoder().decode(Startup.self, from: data),
              config.databasePath.hasPrefix("/"), ["sandbox", "live"].contains(config.mode) else { fputs("QINGCAI_GATEWAY_INVALID_STARTUP\n", stderr); exit(1) }
        do {
            let provider: any GatewayProvider = config.mode == "sandbox" ? SandboxProvider() : UnconfiguredLiveProvider()
            let gateway = try FinanceGateway(database: URL(fileURLWithPath: config.databasePath), provider: provider)
            let server = try GatewayHTTPServer(gateway: gateway, token: config.token)
            let port = try await server.start(port: config.port)
            print("QINGCAI_GATEWAY_READY \(port)"); fflush(stdout)
            // If the desktop process exits/crashes, its pipe closes and the helper exits.
            DispatchQueue.global().async { while readLine() != nil {} ; exit(0) }
            while !Task.isCancelled {
                do { try await gateway.tick() } catch { fputs("QINGCAI_GATEWAY_WORKER_PERSISTENCE_ERROR\n", stderr) }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            server.stop()
        } catch { fputs("QINGCAI_GATEWAY_START_FAILED\n", stderr); exit(1) }
    }
}
