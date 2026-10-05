import Foundation
import Network

// 传输协议：一条 TCP 连接只做一件事。
//   请求：[4 字节长度 + JSON Header] 后面紧跟 payload（剪贴板数据或文件内容，按 Header 里的大小依次排列）
//   回复：[4 字节长度 + JSON Reply]

enum PortalError: LocalizedError {
    case closed, timeout, badFrame, remote(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "连接断开"
        case .timeout: return "连接超时"
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
}

struct Header: Codable {
    var v = 1
    var key: String
    var from: String
    var kind: String          // ping | clip | files
    var mode: String?         // clip（复制同步）| drop（主动发送）
    var reps: [Rep]?
    var files: [FileEntry]?
}

struct Reply: Codable {
    var ok: Bool
    var error: String?
    var name: String?
}

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

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    func receiveAsync(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else { c.resume(throwing: PortalError.closed) }
            }
        }
    }

    func readExactly(_ n: Int) async throws -> Data {
        var buf = Data()
        while buf.count < n {
            buf.append(try await receiveAsync(max: n - buf.count))
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

    func readFrame<T: Decodable>(_ type: T.Type) async throws -> T {
        let b = [UInt8](try await readExactly(4))
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n > 0, n < 64 << 20 else { throw PortalError.badFrame }
        return try JSONDecoder().decode(T.self, from: try await readExactly(n))
    }
}
