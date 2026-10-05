import Foundation
import Network

/// 长连接 + 反向连接。
///
/// 每台电脑都会主动连上它能连到的其他电脑，并保持这条连接（link）。
/// 如果 B 连不上 A（防火墙、系统网络权限等），但 A 连得上 B，那么 A→B 的这条长连接就是 B 的「回拨通道」：
/// B 要发东西给 A 时，通过它请 A 反过来连 B 一次（reverse），然后 B 在这条新连接上照常发送。
/// 所以两台电脑里只要有一台能连上另一台，双向就都能用。
final class Links {
    static let shared = Links()
    weak var server: Server?
    /// 有新电脑连进来或断开时（主线程）
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var incoming: [String: NWConnection] = [:]     // 对方连过来的长连接：对方 IP → 连接
    private var outgoing: [String: NWConnection] = [:]     // 我连过去的长连接：地址 → 连接
    private var dialing: Set<String> = []
    private var lastSeen: [String: Date] = [:]
    private var pending: [String: (NWConnection?) -> Void] = [:]

    private init() {
        let timer = DispatchSource.makeTimerSource(queue: netQueue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.keepalive() }
        timer.resume()
        keepaliveTimer = timer
    }
    private var keepaliveTimer: DispatchSourceTimer?

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return f()
    }

    var incomingIPs: [String] { locked { Array(incoming.keys) } }
    var outgoingAddresses: [String] { locked { Array(outgoing.keys) } }
    func hasIncoming(_ ip: String) -> Bool { locked { incoming[ip] != nil } }

    // MARK: 对方连进来的长连接

    func registerIncoming(_ ip: String, _ conn: NWConnection) {
        let old = locked { () -> NWConnection? in
            let o = incoming[ip]
            incoming[ip] = conn
            return o
        }
        if let old, old !== conn { old.cancel() }
        log("\(ip) 连上了本机（长连接）")
        notify()
        // 对方之后不会再发数据，读到断开就清理
        Task.detached {
            while true {
                do { _ = try await conn.receiveAsync(max: 4096) } catch { break }
            }
            let removed = self.locked { () -> Bool in
                guard self.incoming[ip] === conn else { return false }
                self.incoming[ip] = nil
                return true
            }
            conn.cancel()
            if removed { log("\(ip) 的长连接断开"); self.notify() }
        }
    }

    private func keepalive() {
        let conns = locked { Array(incoming.values) }
        let frame = Header(key: "", from: computerName, kind: "keepalive")
        for c in conns { Task.detached { try? await c.writeFrame(frame) } }
        // 我连出去的长连接：70 秒没收到心跳就认为断了，下次刷新会重连
        let stale = locked { outgoing.filter { Date().timeIntervalSince(lastSeen[$0.key] ?? .distantPast) > 70 }.map(\.value) }
        stale.forEach { $0.cancel() }
    }

    /// 请对方（通过它连过来的长连接）反向连我一次，返回这条新连接。
    func requestCallback(_ ip: String, timeout: TimeInterval = 8) async throws -> NWConnection {
        guard let link = locked({ incoming[ip] }) else { throw PortalError.remote("连不上对方") }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<NWConnection, Error>) in
            locked {
                pending[id] = { conn in
                    if let conn { c.resume(returning: conn) } else { c.resume(throwing: PortalError.timeout) }
                }
            }
            Task.detached {
                do { try await link.writeFrame(Header(key: "", from: computerName, kind: "callback", id: id)) }
                catch { _ = self.fulfil(id, nil) }
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
            let c = try await NWConnection.open(address, defaultPort: cfg.port, timeout: 5)
            conn = c
            try await c.writeFrame(Header(key: cfg.key, from: computerName, kind: "link"))
            let r = try await c.readFrame(Reply.self)
            guard r.ok else { throw PortalError.remote(r.error ?? "对方拒绝") }
            locked {
                dialing.remove(address)
                outgoing[address] = c
                lastSeen[address] = Date()
            }
            log("已和 \(r.name ?? address) 建立长连接")
            while true {
                let h = try await c.readFrame(Header.self)
                locked { lastSeen[address] = Date() }
                if h.kind == "callback", let id = h.id {
                    Task.detached { await self.answerCallback(address, id: id) }
                }
            }
        } catch {}
        let had = locked { () -> Bool in
            dialing.remove(address)
            let had = outgoing[address] != nil && outgoing[address] === conn
            if had { outgoing[address] = nil }
            return had
        }
        conn?.cancel()
        if had { log("和 \(address) 的长连接断开") }
    }

    /// 对方请求回拨：连过去，告诉它编号，然后像接收端一样处理它发来的请求
    private func answerCallback(_ address: String, id: String) async {
        let cfg = Store.shared.config
        do {
            let c = try await NWConnection.open(address, defaultPort: cfg.port, timeout: 5)
            try await c.writeFrame(Header(key: cfg.key, from: computerName, kind: "reverse", id: id))
            if let server { await server.handle(c, ip: hostOf(address)) }
            c.cancel()
        } catch {
            log("回拨 \(address) 失败：\(error.localizedDescription)")
        }
    }

    private func notify() {
        DispatchQueue.main.async { self.onChange?() }
    }
}
