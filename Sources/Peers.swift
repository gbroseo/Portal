import Foundation
import Network

struct Peer {
    enum State { case online, wrongKey, offline }
    var address: String
    var label: String      // Tailscale 里的名字，或手动地址
    var name: String?      // 对方回报的电脑名
    var state: State

    var display: String { name ?? label }
}

/// 找到其他电脑：Tailscale 里同一账号下的在线设备 + 手动添加的地址。
enum Peers {
    private static let lock = NSLock()
    private static var trusted: Set<String> = []     // 同一 Tailscale 账号的设备 IP，免配对码

    static func isTrusted(_ ip: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return trusted.contains(ip)
    }

    static var tailscaleCLI: String? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 读取 tailscale status，返回同账号的在线设备，并刷新信任列表。
    static func tailscalePeers() -> [(address: String, label: String)] {
        guard let cli = tailscaleCLI else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["Self"] as? [String: Any] else { return [] }
        let myUser = me["UserID"] as? Int
        var found: [(String, String)] = []
        var ips: Set<String> = []
        for case let peer as [String: Any] in (root["Peer"] as? [String: Any] ?? [:]).values {
            guard peer["UserID"] as? Int == myUser else { continue }
            let addrs = peer["TailscaleIPs"] as? [String] ?? []
            ips.formUnion(addrs)
            if peer["Online"] as? Bool == true, let v4 = addrs.first(where: { $0.contains(".") }) {
                found.append((v4, peer["HostName"] as? String ?? v4))
            }
        }
        lock.lock(); trusted = ips; lock.unlock()
        return found
    }

    static func ping(_ address: String, label: String) async -> Peer {
        let cfg = Store.shared.config
        var peer = Peer(address: address, label: label, name: nil, state: .offline)
        do {
            let conn = try await NWConnection.open(address, defaultPort: cfg.port, timeout: 3)
            defer { conn.cancel() }
            try await conn.writeFrame(Header(key: cfg.key, from: computerName, kind: "ping"))
            let r = try await conn.readFrame(Reply.self)
            peer.name = r.name
            peer.state = r.ok ? .online : .wrongKey
        } catch {}
        return peer
    }

    static func scan() async -> [Peer] {
        let manual = Store.shared.config.peers.map { (address: $0, label: $0) }
        let all = tailscalePeers() + manual
        return await withTaskGroup(of: Peer.self) { group in
            for c in all { group.addTask { await ping(c.address, label: c.label) } }
            var result: [Peer] = []
            for await p in group { result.append(p) }
            return result.sorted { $0.display < $1.display }
        }
    }
}
