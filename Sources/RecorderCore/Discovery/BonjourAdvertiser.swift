import Foundation
import Logging
import LumeRecorderKit
import ServiceLifecycle

/// TXT record contents shared by the macOS advertiser and the Docker avahi file.
public enum BonjourTXT {
    public static func record(serverID: UUID) -> [String: String] {
        ["id": serverID.uuidString.lowercased(), "version": RecorderVersion.current, "api": String(LumeRecorderAPI.version)]
    }
}

#if canImport(Darwin)
    /// Advertises `_lume-recorder._tcp` via `NetService` on a dedicated run-loop
    /// thread (an async `main` never spins `RunLoop.main`). Used for macOS dev
    /// runs; Linux/Docker advertises through avahi from the entrypoint script.
    public final class BonjourAdvertiser: NSObject, NetServiceDelegate, @unchecked Sendable {
        private let name: String
        private let port: Int32
        private let txt: [String: String]
        private let logger: Logger
        private var service: NetService?
        private var thread: Thread?

        public init(name: String, port: Int, serverID: UUID, logger: Logger) {
            self.name = name
            self.port = Int32(port)
            txt = BonjourTXT.record(serverID: serverID)
            self.logger = logger
        }

        public func start() {
            let thread = Thread { [self] in
                let service = NetService(domain: "local.", type: LumeRecorderClient.bonjourServiceType + ".", name: name, port: port)
                service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
                service.delegate = self
                service.schedule(in: .current, forMode: .default)
                service.publish()
                self.service = service
                while !Thread.current.isCancelled {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                }
                service.stop()
                service.remove(from: .current, forMode: .default)
            }
            thread.name = "bonjour"
            self.thread = thread
            thread.start()
        }

        public func stop() {
            thread?.cancel()
        }

        public func netServiceDidPublish(_ sender: NetService) {
            logger.info("Bonjour: advertising \"\(sender.name)\" as \(LumeRecorderClient.bonjourServiceType) on port \(sender.port)")
        }

        public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
            logger.warning("Bonjour: couldn't advertise (\(errorDict))")
        }
    }
#endif

/// Runs the advertiser for the lifetime of the service group (no-op on Linux).
struct BonjourService: Service {
    let name: String
    let port: Int
    let serverID: UUID
    let logger: Logger

    func run() async throws {
        #if canImport(Darwin)
            let advertiser = BonjourAdvertiser(name: name, port: port, serverID: serverID, logger: logger)
            advertiser.start()
            try? await gracefulShutdown()
            advertiser.stop()
        #else
            try? await gracefulShutdown()
        #endif
    }
}
