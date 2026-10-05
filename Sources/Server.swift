import Foundation
import Network

/// 传输进度（接收或发送）
struct TransferStatus {
    var receiving: Bool
    var name: String
    var done: Int64
    var total: Int64
}

/// 接收端：监听端口，接收剪贴板内容和文件。
final class Server {
    var listener: NWListener?
    /// 收到东西后在主线程回调
    var onClip: (([(Rep, Data)], String) -> Void)?
    var onFiles: (([URL], String, String) -> Void)?   // urls, from, mode
    var onProgress: ((TransferStatus?) -> Void)?

    /// 正在接收的分段传输
    private final class Incoming {
        let staging: URL
        let name: String
        let total: Int64
        var done: Int64 = 0
        var remaining: Int64          // 还没收到的分段字节数
        var lastProgress = Date()
        var waiter: CheckedContinuation<Void, Error>?
        init(staging: URL, name: String, total: Int64, remaining: Int64) {
            self.staging = staging; self.name = name; self.total = total; self.remaining = remaining
        }
    }
    private let lock = NSLock()
    private var transfers: [String: Incoming] = [:]
    private var lastReport = Date.distantPast

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
                let keep = await self?.handle(conn, ip: ip) ?? false
                if !keep { conn.cancel() }
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

    /// Tailscale 地址连进来的一律信任（只有同一账号的设备能连到这些地址）；局域网地址才需要配对码。
    private func authorized(_ h: Header, ip: String) -> Bool {
        isTailnet(ip) || isLoopback(ip) || Config.normalize(h.key) == Config.normalize(Store.shared.config.key)
    }

    private func ok(_ info: String? = nil) -> Reply {
        Reply(ok: true, name: computerName, version: appVersion, known: Peers.knownAddresses(), info: info)
    }

    func deliverClip(_ items: [(Rep, Data)], from: String) async {
        log("收到 \(from) 的剪贴板（\(items.count) 项，\(items.reduce(0) { $0 + $1.1.count }) 字节）")
        await MainActor.run { onClip?(items, from) }
    }

    /// 处理一条连接上的请求。返回 true 表示这条连接要保留（长连接 / 反向连接）。
    @discardableResult
    func handle(_ conn: NWConnection, ip: String) async -> Bool {
        do {
            let h = try await conn.readFrame(Header.self)
            guard authorized(h, ip: ip) else {
                log("配对码不一致，拒绝 \(h.from) (\(ip))")
                try await conn.writeFrame(Reply(ok: false, error: "配对码不一致", name: computerName, version: appVersion))
                return false
            }
            if !isLoopback(ip) { Peers.learn(ip) }
            let testable = isTailnet(ip) || isLoopback(ip)
            switch h.kind {
            case "ping":
                try await conn.writeFrame(ok())
            case "link":
                try await conn.writeFrame(ok())
                Links.shared.registerIncoming(ip, conn, name: h.from, version: h.ver)
                return true
            case "reverse":
                if let id = h.id, Links.shared.fulfil(id, conn) { return true }
            case "diag" where testable:
                try await conn.writeFrame(ok(await Diag.text()))
            case "clipinfo" where testable:
                let info = await MainActor.run { Clipboard.info() }
                try await conn.writeFrame(ok(info))
            case "simulate" where testable:
                // 远程测试：在本机模拟一次「复制」，看能不能自动同步出去
                let info = try await MainActor.run { try Clipboard.simulateCopy(h.mode ?? "text", text: h.text, size: h.size ?? 1) }
                try await conn.writeFrame(ok(info))
            case "clip":
                var items: [(Rep, Data)] = []
                for r in h.reps ?? [] {
                    guard r.size >= 0, r.size < 512 << 20, (0..<10_000).contains(r.item) else { throw PortalError.badFrame }
                    items.append((r, try await conn.readExactly(r.size)))
                }
                await deliverClip(items, from: h.from)
                try await conn.writeFrame(ok())
            case "files":
                let urls = try await receiveFiles(h, conn)
                log("收到 \(h.from) 的 \(urls.count) 个项目：\(urls.map(\.lastPathComponent))")
                await MainActor.run { onFiles?(urls, h.from, h.mode ?? "drop") }
                try await conn.writeFrame(ok())
            case "part":
                // 一条并行连接上会依次发来多个分段
                var cur = h
                while true {
                    try await receivePart(cur, conn)
                    try await conn.writeFrame(Reply(ok: true))
                    guard let next = try? await conn.readFrame(Header.self, timeout: 120), next.kind == "part" else { break }
                    cur = next
                }
            default:
                try await conn.writeFrame(Reply(ok: false, error: "不支持的请求 \(h.kind)", name: computerName))
            }
        } catch {
            log("处理连接出错：\(error.localizedDescription)")
        }
        return false
    }

    // MARK: 接收文件

    private func receiveFiles(_ h: Header, _ conn: NWConnection) async throws -> [URL] {
        let files = h.files ?? []
        let fm = FileManager.default
        let dest = Store.shared.config.recvURL
        let staging = dest.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 第一遍：检查路径、建目录、给分段传输的大文件预留空间
        var tops: [String] = []
        var splitBytes: Int64 = 0
        for f in files {
            let url = try Server.safeURL(staging, f.path)
            let top = String(f.path.split(separator: "/")[0])
            if !tops.contains(top) { tops.append(top) }
            if f.dir {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else if f.split == true {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
                let fh = try FileHandle(forWritingTo: url)
                fh.truncateFile(atOffset: UInt64(f.size))
                fh.closeFile()
                splitBytes += f.size
            }
        }
        let total = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        let name = tops.count == 1 ? tops[0] : "\(tops.count) 个项目"
        let tid = h.tid ?? UUID().uuidString
        let t = Incoming(staging: staging, name: name, total: total, remaining: splitBytes)
        lock.lock(); transfers[tid] = t; lock.unlock()
        defer {
            lock.lock(); transfers[tid] = nil; lock.unlock()
            report(nil)
        }

        // 第二遍：小文件内容直接跟在这条连接后面
        for f in files where !f.dir && f.split != true {
            let url = try Server.safeURL(staging, f.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
            let fh = try FileHandle(forWritingTo: url)
            defer { fh.closeFile() }
            var remaining = f.size
            while remaining > 0 {
                let chunk = try await conn.receiveAsync(max: Int(min(remaining, Int64(chunkSize))))
                fh.write(chunk)
                remaining -= Int64(chunk.count)
                progress(t, Int64(chunk.count))
            }
        }

        // 等并行分段全部到齐（90 秒没有任何进展就放弃）
        if splitBytes > 0 {
            log("\(name)：大文件分段并行接收（\(formatBytes(splitBytes))）")
            let watchdog = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self else { return }
                    self.lock.lock()
                    let stalled = Date().timeIntervalSince(t.lastProgress) > 90
                    let w = stalled ? t.waiter : nil
                    if stalled { t.waiter = nil }
                    self.lock.unlock()
                    if let w { w.resume(throwing: PortalError.stalled); return }
                }
            }
            defer { watchdog.cancel() }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if t.remaining <= 0 { lock.unlock(); c.resume() } else { t.waiter = c; lock.unlock() }
            }
        }

        var result: [URL] = []
        for top in tops {
            let target = Server.unique(dest.appendingPathComponent(top))
            try fm.moveItem(at: staging.appendingPathComponent(top), to: target)
            result.append(target)
        }
        return result
    }

    private func receivePart(_ h: Header, _ conn: NWConnection) async throws {
        // 分段可能比主连接的文件清单先到，稍等一下
        var found: Incoming?
        for _ in 0..<100 {
            lock.lock(); found = h.tid.flatMap { transfers[$0] }; lock.unlock()
            if found != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let t = found, let path = h.text, let offset = h.offset, let size = h.size, offset >= 0, size >= 0 else {
            throw PortalError.badFrame
        }
        let url = try Server.safeURL(t.staging, path)
        let fh = try FileHandle(forWritingTo: url)
        defer { fh.closeFile() }
        fh.seek(toFileOffset: UInt64(offset))
        var remaining = size
        while remaining > 0 {
            let chunk = try await conn.receiveAsync(max: Int(min(remaining, Int64(chunkSize))))
            fh.write(chunk)
            remaining -= Int64(chunk.count)
            progress(t, Int64(chunk.count))
        }
        lock.lock()
        t.remaining -= size
        let w = t.remaining <= 0 ? t.waiter : nil
        if w != nil { t.waiter = nil }
        lock.unlock()
        w?.resume()
    }

    private func progress(_ t: Incoming, _ n: Int64) {
        lock.lock()
        t.done += n
        t.lastProgress = Date()
        let due = t.total > 4 << 20 && Date().timeIntervalSince(lastReport) > 0.25
        if due { lastReport = Date() }
        let status = TransferStatus(receiving: true, name: t.name, done: t.done, total: t.total)
        lock.unlock()
        if due { report(status) }
    }

    private func report(_ s: TransferStatus?) {
        DispatchQueue.main.async { self.onProgress?(s) }
    }

    /// 对方给的相对路径必须留在目标文件夹里
    static func safeURL(_ base: URL, _ path: String) throws -> URL {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else {
            throw PortalError.badFrame
        }
        return base.appendingPathComponent(parts.joined(separator: "/"))
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
