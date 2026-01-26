import Foundation
import Observation

struct Server: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var privateKeyId: String?

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String, privateKeyId: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyId = privateKeyId
    }
}

@Observable
class ServerStore {
    var servers: [Server] = []
    private let key = "vilya.servers"

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Server].self, from: data) {
            servers = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ server: Server) { servers.append(server); save() }
    func delete(_ server: Server) { servers.removeAll { $0.id == server.id }; save() }
}
