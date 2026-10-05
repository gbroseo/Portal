import Foundation
import Network

/// 长连接 + 反向连接。
///
/// 每台电脑都会主动连上它能连到的其他电脑，并保持这条连接（link）。长连接有三个用处：
/// 1. 剪贴板内容直接从长连接发过去，不用每次新建连接（高延迟网络下快很多，复制后几乎马上到）
/// 2. 判断对方在不在线，不用反复 ping
/// 3. 反向连接：如果 B 连不上 A，但 A 连得上 B，B 要发文件时通过 A→B 的长连接请 A 反过来连 B 一次。
///    所以两台电脑里只要有一台能连上另一台，双向就都能用。
final class Links {
    static let shared = Links()
    weak var server: Server?
    /// 有电脑连上或断开时（主线程）
    var onChange: (() -> Void)?

    private struct Link {
        var conn: NWConnection
        var name: String
        var version: String?
        var lastSeen: Date
    }

    private let lock = NSLock()
    private var incoming: [String: Link] = [:]     // 对方连过来的长连接：对方 IP → 连接
    private var outgoing: [String: Link] = [:]     // 我连过去的长连接：地址 → 连接
    private var dialing: Set<String> = []
    private var pending: [String: (NWConnection?) -> Void] = [:]
    private var timer: DispatchSourceTimer?

    private init() {
        let t = DispatchSource.makeTimerSource(queue: netQueue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in self?.keepalive() }
        t.resume()
        timer = t
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return f()
    }

    var incomingIPs: [String] { locked { Array(incoming.keys) } }
    var outgoingAddresses: [String] { locked { Array(outgoing.keys) } }
    func hasIncoming(_ ip: String) -> Bool { locked { incoming[ip] != nil } }

    /// 和这台电脑之间有没有活着的长连接（任一方向），有的话返回对方名字和版本
    func linked(_ address: String) -> (name: String, version: String?)? {
        let host = hostOf(address)
        return locked {
            if let l = outgoing[address] ?? outgoing.first(where: { hostOf($0.key) == host })?.value { return (l.name, l.version) }
            if let l = incoming[host] { return (l.name, l.version) }
            return nil
        }
    }

    /// 通过长连接发一帧（剪贴板等小数据）。没有长连接时返回 false
    func send(to address: String, _ data: Data) async -> Bool {
        let host = hostOf(address)
        let conn = locked { (outgoing[address] ?? outgoing.first(where: { hostOf($0.key) == host })?.value ?? incoming[host])?.conn }
        guard let conn else { return false }
        do { try await conn.sendAsync(data, timeout: 30); return true } catch { return false }
    }

    // MARK: 对方连进来的长连接

    func registerIncoming(_ ip: String, _ conn: NWConnection, name: String, version: String?) {
        let old = locked { () -> NWConnection? in
            let o = incoming[ip]?.conn
            incoming[ip] = Link(conn: conn, name: name, version: version, lastSeen: Date())
            return o
        }
        if let old, old !== conn { old.cancel() }
        log("\(name)（\(ip)）连上了本机")
        notify()
        Task.detached {
            await self.readLoop(conn, peerIP: ip, address: nil)
            let removed = self.locked { () -> Bool in
                guard self.incoming[ip]?.conn === conn else { return false }
                self.incoming[ip] = nil
                return true
            }
            conn.cancel()
            if removed { log("\(name) 的长连接断开"); self.notify() }
        }
    }

    /// 长连接上的消息：心跳、回拨请求、剪贴板内容
    private func readLoop(_ conn: NWConnection, peerIP: String, address: String?) async {
        while true {
            guard let h = try? await conn.readFrame(Header.self, timeout: 60) else { return }
            locked {
                if let address { outgoing[address]?.lastSeen = Date() } else { incoming[peerIP]?.lastSeen = Date() }
            }
            switch h.kind {
            case "callback":
                if let id = h.id, let address { Task.detached { await self.answerCallback(address, id: id) } }
            case "clip":
                var items: [(Rep, Data)] = []
                for r in h.reps ?? [] {
                    guard r.size >= 0, r.size < 512 << 20, (0..<10_000).contains(r.item),
                          let d = try? await conn.readExactly(r.size) else { return }
                    items.append((r, d))
                }
                await server?.deliverClip(items, from: h.from)
            default:
                break   // keepalive
            }
        }
    }

    private func keepalive() {
        guard let frame = try? NWConnection.frameData(Header(key: "", from: computerName, kind: "keepalive")) else { return }
        let all = locked { Array(incoming.values) + Array(outgoing.values) }
        for l in all {
            if Date().timeIntervalSince(l.lastSeen) > 50 { l.conn.cancel(); continue }   // 对方没心跳了
            Task.detached { try? await l.conn.sendAsync(frame, timeout: 30) }
        }
    }

    // MARK: 反向连接

    /// 请对方（通过它连过来的长连接）反向连我一次，返回这条新连接。
    func requestCallback(_ ip: String, timeout: TimeInterval = 20) async throws -> NWConnection {
        guard let link = locked({ incoming[ip]?.conn }) else { throw PortalError.remote("连不上对方") }
        let id = UUID().uuidString
        let frame = try NWConnection.frameData(Header(key: "", from: computerName, kind: "callback", id: id))
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<NWConnection, Error>) in
            locked {
                pending[id] = { conn in
                    if let conn { c.resume(returning: conn) } else { c.resume(throwing: PortalError.timeout) }
                }
            }
            Task.detached {
                do { try await link.sendAsync(frame, timeout: 15) } catch { _ = self.fulfil(id, nil) }
            }
            netQueue.asyncAfter(deadline: .now() + timeout) { _ = self.fulfil(id, nil) }
        }
    }

    /// 对方按回拨请求连过来了；返回 false 表示请求已超时
    func fulfil(_ id: String, _ conn: NWConnection?) -> Bool {
        guard let f = locked({ pending.removeValue(forKey: id) }) else { return false }
        f(conn)
        return true
    }

    private func answerCallback(_ address: String, id: String) async {
        let cfg = Store.shared.config
        do {
            let c = try await NWConnection.open(address, defaultPort: cfg.port, timeout: 15)
            try await c.writeFrame(Header(key: cfg.key, from: computerName, kind: "reverse", id: id))
            if let server { await server.handle(c, ip: hostOf(address)) }
            c.cancel()
        } catch {
            log("回拨 \(address) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: 我连出去的长连接

    /// 对还没有长连接的地址发起连接（失败就算了，下次刷新再试）
    func maintain(_ addresses: [String]) {
        for address in addresses {
            let start = locked { () -> Bool in
                guard outgoing[address] == nil, !dialing.contains(address) else { return false }
                dialing.insert(address)
                return true
            }
            if start { Task.detached { await self.runLink(address) } }
        }
    }

    private func runLink(_ address: String) async {
        let cfg = Store.shared.config
        var conn: NWConnection?
        do {
            let c = try await NWConnection.open(address, defaultPort: cfg.port, timeout: 15)
            conn = c
            try await c.writeFrame(Header(key: cfg.key, from: computerName, kind: "link", ver: appVersion))
            let r = try await c.readFrame(Reply.self, timeout: 20)
            guard r.ok else { throw PortalError.remote(r.error ?? "对方拒绝") }
            locked {
                dialing.remove(address)
                outgoing[address] = Link(conn: c, name: r.name ?? address, version: r.version, lastSeen: Date())
            }
            log("已和 \(r.name ?? address) 建立长连接")
            notify()
            await readLoop(c, peerIP: hostOf(address), address: address)
        } catch {}
        let had = locked { () -> Bool in
            dialing.remove(address)
            let had = conn != nil && outgoing[address]?.conn === conn
            if had { outgoing[address] = nil }
            return had
        }
        conn?.cancel()
        if had { log("和 \(address) 的长连接断开"); notify() }
    }

    private func notify() {
        DispatchQueue.main.async { self.onChange?() }
    }
}
