import Foundation
import Network

struct Peer {
    enum State { case online, wrongKey, offline }
    var address: String
    var label: String      // Tailscale 里的名字，或手动地址
    var name: String?      // 对方回报的电脑名
    var state: State
    var version: String?

    var display: String { name ?? label }
}

/// 找到其他电脑，来源有四个（任何一个能用就行）：
/// Tailscale 设备列表、以前连过的电脑、正连着本机的电脑、其他电脑分享过来的地址。
enum Peers {
    private static let lock = NSLock()
    private static var found: [(address: String, label: String)] = []
    static var lastError: String?

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
        let errPipe = Pipe()
        p.standardOutput = out
        p.standardError = errPipe
        do { try p.run() } catch { lastError = "无法运行 \(cli)：\(error.localizedDescription)"; return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["Self"] as? [String: Any] else {
            let head = String(data: data.prefix(300), encoding: .utf8) ?? ""
            lastError = "tailscale status 失败（退出码 \(p.terminationStatus)）：\(errText.prefix(300)) \(head)"
            return []
        }
        lastError = nil
        let myUser = me["UserID"] as? Int
        var result: [(String, String)] = []
        for case let peer as [String: Any] in (root["Peer"] as? [String: Any] ?? [:]).values {
            guard peer["UserID"] as? Int == myUser else { continue }
            let addrs = peer["TailscaleIPs"] as? [String] ?? []
            if peer["Online"] as? Bool == true, let v4 = addrs.first(where: { $0.contains(".") }) {
                result.append((v4, peer["HostName"] as? String ?? v4))
            }
        }
        lock.lock(); found = result; lock.unlock()
        return result
    }

    /// 分享给其他电脑的地址列表（只含 Tailscale 地址）
    static func knownAddresses() -> [String] {
        lock.lock(); let ts = found.map(\.address); lock.unlock()
        let all = ts + Store.shared.config.learned + Links.shared.incomingIPs
        return Array(Set(all.filter { isTailnet($0) }))
    }

    /// 记住连过的电脑：下次即使 Tailscale 列表读不到也能找到它
    static func learn(_ ip: String) {
        let ip = hostOf(ip)
        guard !isLoopback(ip), !localIPs().contains(ip), !Store.shared.config.learned.contains(ip) else { return }
        Store.shared.update { if !$0.learned.contains(ip) { $0.learned.append(ip) } }
        log("记住新电脑 \(ip)")
    }

    static func ping(_ address: String, label: String) async -> Peer {
        let cfg = Store.shared.config
        var peer = Peer(address: address, label: label, name: nil, state: .offline)
        do {
            let conn = try await Sender.connect(address, timeout: 3)
            defer { conn.cancel() }
            try await conn.writeFrame(Header(key: cfg.key, from: computerName, kind: "ping"))
            let r = try await conn.readFrame(Reply.self)
            peer.name = r.name
            peer.version = r.version
            peer.state = r.ok ? .online : .wrongKey
            for k in r.known ?? [] where isTailnet(k) { learn(k) }
        } catch {}
        return peer
    }

    static func scan() async -> [Peer] {
        let cfg = Store.shared.config
        let mine = testNoDial ? [] : localIPs()
        var all: [(address: String, label: String)] = []
        let candidates = tailscalePeers()
            + (cfg.peers + cfg.learned + Links.shared.incomingIPs).map { (address: $0, label: $0) }
        for c in candidates where !(hostOf(c.address) == c.address && mine.contains(c.address)) && !all.contains(where: { $0.address == c.address }) {
            all.append(c)
        }
        return await withTaskGroup(of: Peer.self) { group in
            for c in all { group.addTask { await ping(c.address, label: c.label) } }
            var result: [Peer] = []
            for await p in group { result.append(p) }
            return result.sorted { $0.display < $1.display }
        }
    }
}
