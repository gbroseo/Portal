import Foundation
import Network

// 传输协议：一条 TCP 连接只做一件事。
//   请求：[4 字节长度 + JSON Header] 后面紧跟 payload（剪贴板数据或文件内容，按 Header 里的大小依次排列）
//   回复：[4 字节长度 + JSON Reply]

enum PortalError: LocalizedError {
    case closed, timeout, stalled, badFrame, remote(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "连接断开"
        case .timeout: return "连接超时"
        case .stalled: return "网络卡住了（2 分钟没有进展）"
        case .badFrame: return "数据格式不对"
        case .remote(let m): return m
        }
    }
}

struct Rep: Codable {
    var item: Int
    var type: String
    var size: Int
}

struct FileEntry: Codable {
    var path: String      // 相对路径，用 / 分隔，第一段是顶层文件/文件夹名
    var size: Int64
    var dir: Bool
    var split: Bool?      // 大文件：内容不跟在这条连接后面，而是分段从多条并行连接发送
}

struct Header: Codable {
    var v = 1
    var key: String
    var from: String
    var kind: String          // ping | clip | files | link | callback | reverse | keepalive | diag | clipinfo | simulate
    var mode: String?         // clip（复制同步）| drop（主动发送）；simulate 时为 text / image / file
    var reps: [Rep]?
    var files: [FileEntry]?
    var id: String?           // 反向连接的编号
    var text: String?
    var size: Int64?
    var ver: String?          // 发送方的传送门版本
    var tid: String?          // 文件传输编号（并行分段用）
    var offset: Int64?        // 分段在文件里的位置
}

struct Reply: Codable {
    var ok: Bool
    var error: String?
    var name: String?
    var version: String?
    var known: [String]?      // 对方知道的其他电脑（Tailscale 地址），互相分享
    var info: String?
}

/// 测试开关：模拟「这台电脑连不出去」
let testNoDial = ProcessInfo.processInfo.environment["PORTAL_TEST_NODIAL"] != nil

let netQueue = DispatchQueue(label: "portal.net")
let chunkSize = 4 << 20

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        f()
    }
}

extension NWConnection {
    static func open(_ address: String, defaultPort: UInt16, timeout: TimeInterval = 5) async throws -> NWConnection {
        if testNoDial { throw PortalError.remote("测试：禁止主动连接") }
        var host = address
        var port = defaultPort
        if address.filter({ $0 == ":" }).count == 1, let i = address.lastIndex(of: ":"),
           let p = UInt16(address[address.index(after: i)...]) {
            host = String(address[..<i])
            port = p
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { c.resume() }
                case .failed(let e), .waiting(let e): once.run { conn.cancel(); c.resume(throwing: e) }
                case .cancelled: once.run { c.resume(throwing: PortalError.closed) }
                default: break
                }
            }
            conn.start(queue: netQueue)
            netQueue.asyncAfter(deadline: .now() + timeout) {
                once.run { conn.cancel(); c.resume(throwing: PortalError.timeout) }
            }
        }
        return conn
    }

    /// 发送；超过 timeout 秒对方一直不收（网络卡死），断开连接并报错
    func sendAsync(_ data: Data, timeout: TimeInterval = 60) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            send(content: data, completion: .contentProcessed { e in
                once.run { if let e { c.resume(throwing: e) } else { c.resume() } }
            })
            netQueue.asyncAfter(deadline: .now() + timeout) {
                once.run { self.cancel(); c.resume(throwing: PortalError.stalled) }
            }
        }
    }

    /// 接收；timeout 秒内一个字节都没收到就断开（nil = 不限时）
    func receiveAsync(max: Int, timeout: TimeInterval? = 120) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            let once = Once()
            receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                once.run {
                    if let error { c.resume(throwing: error) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else { c.resume(throwing: PortalError.closed) }
                }
            }
            if let timeout {
                netQueue.asyncAfter(deadline: .now() + timeout) {
                    once.run { self.cancel(); c.resume(throwing: PortalError.stalled) }
                }
            }
        }
    }

    func readExactly(_ n: Int, timeout: TimeInterval? = 60) async throws -> Data {
        var buf = Data()
        while buf.count < n {
            buf.append(try await receiveAsync(max: n - buf.count, timeout: timeout))
        }
        return buf
    }

    func writeFrame<T: Encodable>(_ value: T) async throws {
        let body = try JSONEncoder().encode(value)
        let n = UInt32(body.count)
        var out = Data([UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        out.append(body)
        try await sendAsync(out)
    }

    func readFrame<T: Decodable>(_ type: T.Type, timeout: TimeInterval? = 60) async throws -> T {
        let b = [UInt8](try await readExactly(4, timeout: timeout))
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n > 0, n < 64 << 20 else { throw PortalError.badFrame }
        return try JSONDecoder().decode(T.self, from: try await readExactly(n))
    }

    /// 一帧 + 数据拼成一次发送：长连接上多个任务同时写也不会交错
    static func frameData<T: Encodable>(_ value: T, payload: [Data] = []) throws -> Data {
        let body = try JSONEncoder().encode(value)
        let n = UInt32(body.count)
        var out = Data([UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        out.append(body)
        payload.forEach { out.append($0) }
        return out
    }
}
