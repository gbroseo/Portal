import Foundation
import Network

/// 接收端：监听端口，接收剪贴板内容和文件。
final class Server {
    var listener: NWListener?
    /// 收到东西后在主线程回调：文字说明 + 内容
    var onClip: (([(Rep, Data)], String) -> Void)?
    var onFiles: (([URL], String, String) -> Void)?   // urls, from, mode
    var onProgress: ((Double?) -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            guard let ip = Server.remoteIP(conn.endpoint), Server.isPrivate(ip) else {
                log("拒绝外部连接 \(conn.endpoint)")
                conn.cancel()
                return
            }
            conn.start(queue: netQueue)
            Task {
                await self?.handle(conn, ip: ip)
                conn.cancel()
            }
        }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state { log("监听失败：\(e)") }
            if case .ready = state { log("开始监听端口 \(port)") }
        }
        l.start(queue: netQueue)
        listener = l
    }

    static func remoteIP(_ ep: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = ep else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a):
            if let v4 = a.asIPv4 { return "\(v4)" }
            return "\(a)".components(separatedBy: "%").first
        default: return nil
        }
    }

    /// 只接受回环、局域网、Tailscale（100.64.0.0/10、fd7a:115c:a1e0::/48）地址。
    static func isPrivate(_ ip: String) -> Bool {
        if ip.contains(":") {
            let l = ip.lowercased()
            return l == "::1" || l.hasPrefix("fe80") || l.hasPrefix("fd7a:115c:a1e0")
        }
        let o = ip.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 127 || o[0] == 10 || (o[0] == 100 && (64...127).contains(o[1]))
            || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
            || (o[0] == 169 && o[1] == 254)
    }

    private func authorized(_ h: Header, ip: String) -> Bool {
        if Config.normalize(h.key) == Config.normalize(Store.shared.config.key) { return true }
        if Peers.isTrusted(ip) { return true }
        // 新设备刚加入 Tailscale 时信任列表可能还没刷新，再查一次
        _ = Peers.tailscalePeers()
        return Peers.isTrusted(ip)
    }

    private func handle(_ conn: NWConnection, ip: String) async {
        do {
            let h = try await conn.readFrame(Header.self)
            guard authorized(h, ip: ip) else {
                log("配对码不一致，拒绝 \(h.from) (\(ip))")
                try await conn.writeFrame(Reply(ok: false, error: "配对码不一致", name: computerName))
                return
            }
            Peers.learn(ip)
            switch h.kind {
            case "ping":
                try await conn.writeFrame(Reply(ok: true, name: computerName))
            case "clip":
                var items: [(Rep, Data)] = []
                for r in h.reps ?? [] {
                    guard r.size >= 0, r.size < 512 << 20, (0..<10_000).contains(r.item) else { throw PortalError.badFrame }
                    items.append((r, try await conn.readExactly(r.size)))
                }
                log("收到 \(h.from) 的剪贴板（\(items.count) 项，\(items.reduce(0) { $0 + $1.1.count }) 字节）")
                let received = items
                await MainActor.run { onClip?(received, h.from) }
                try await conn.writeFrame(Reply(ok: true, name: computerName))
            case "files":
                let urls = try await receiveFiles(h.files ?? [], conn)
                log("收到 \(h.from) 的 \(urls.count) 个项目：\(urls.map(\.lastPathComponent))")
                await MainActor.run { onFiles?(urls, h.from, h.mode ?? "drop") }
                try await conn.writeFrame(Reply(ok: true, name: computerName))
            default:
                try await conn.writeFrame(Reply(ok: false, error: "不支持的请求 \(h.kind)", name: computerName))
            }
        } catch {
            log("处理连接出错：\(error.localizedDescription)")
            await MainActor.run { onProgress?(nil) }
        }
    }

    private func receiveFiles(_ files: [FileEntry], _ conn: NWConnection) async throws -> [URL] {
        let fm = FileManager.default
        let dest = Store.shared.config.recvURL
        let staging = dest.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let total = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        var done: Int64 = 0
        var lastReport = Date.distantPast
        var tops: [String] = []

        for f in files {
            let parts = f.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty, !f.path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), f.size >= 0 else {
                throw PortalError.badFrame
            }
            if !tops.contains(parts[0]) { tops.append(parts[0]) }
            let url = staging.appendingPathComponent(parts.joined(separator: "/"))
            if f.dir {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
            let fh = try FileHandle(forWritingTo: url)
            var remaining = f.size
            while remaining > 0 {
                let chunk = try await conn.receiveAsync(max: Int(min(remaining, Int64(chunkSize))))
                fh.write(chunk)
                remaining -= Int64(chunk.count)
                done += Int64(chunk.count)
                if total > 8 << 20, Date().timeIntervalSince(lastReport) > 0.3 {
                    lastReport = Date()
                    let frac = Double(done) / Double(total)
                    await MainActor.run { onProgress?(frac) }
                }
            }
            fh.closeFile()
        }
        await MainActor.run { onProgress?(nil) }

        var result: [URL] = []
        for t in tops {
            let target = Server.unique(dest.appendingPathComponent(t))
            try fm.moveItem(at: staging.appendingPathComponent(t), to: target)
            result.append(target)
        }
        return result
    }

    /// 重名时改成「名字 2.扩展名」
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
