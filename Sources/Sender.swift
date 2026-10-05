import Foundation
import Network

/// 发送端：把剪贴板内容或文件推给一台电脑。
enum Sender {
    /// 大于这个大小的文件分段、多条连接并行发送（高延迟或丢包的网络上快很多）
    static let splitThreshold: Int64 = 16 << 20
    static let segmentSize: Int64 = 8 << 20

    /// 先直接连；连不上但对方正连着本机时，请它反向连过来
    static func connect(_ address: String, timeout: TimeInterval = 15) async throws -> NWConnection {
        do {
            return try await NWConnection.open(address, defaultPort: Store.shared.config.port, timeout: timeout)
        } catch {
            let ip = hostOf(address)
            guard Links.shared.hasIncoming(ip) else { throw error }
            return try await Links.shared.requestCallback(ip)
        }
    }

    static func sendClip(_ reps: [(Rep, Data)], to address: String) async throws -> String {
        let cfg = Store.shared.config
        let header = Header(key: cfg.key, from: computerName, kind: "clip", mode: "clip", reps: reps.map(\.0))
        // 有长连接就直接从长连接发，省掉建立连接的往返，复制后几乎马上到
        if let l = Links.shared.linked(address), versionAtLeast(l.version, "1.2.0"),
           await Links.shared.send(to: address, try NWConnection.frameData(header, payload: reps.map(\.1))) {
            return l.name
        }
        let conn = try await connect(address)
        defer { conn.cancel() }
        try await conn.sendAsync(try NWConnection.frameData(header, payload: reps.map(\.1)))
        let r = try await conn.readFrame(Reply.self)
        guard r.ok else { throw PortalError.remote(r.error ?? "对方拒绝") }
        return r.name ?? address
    }

    /// 展开文件夹，得到要发送的条目（相对路径）和本地源文件。
    static func plan(_ urls: [URL]) throws -> [(FileEntry, URL?)] {
        let fm = FileManager.default
        var out: [(FileEntry, URL?)] = []
        for url in urls {
            let top = url.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw PortalError.remote("找不到文件 \(top)") }
            if !isDir.boolValue {
                let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                out.append((FileEntry(path: top, size: size, dir: false), url))
                continue
            }
            out.append((FileEntry(path: top, size: 0, dir: true), nil))
            for sub in try fm.subpathsOfDirectory(atPath: url.path).sorted() {
                let src = url.appendingPathComponent(sub)
                let attrs = try fm.attributesOfItem(atPath: src.path)   // 不跟随符号链接
                let type = attrs[.type] as? FileAttributeType
                if type == .typeDirectory {
                    out.append((FileEntry(path: "\(top)/\(sub)", size: 0, dir: true), nil))
                } else if type == .typeRegular {
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    out.append((FileEntry(path: "\(top)/\(sub)", size: size, dir: false), src))
                }
            }
        }
        return out
    }

    static func totalSize(_ urls: [URL]) -> Int64 {
        ((try? plan(urls)) ?? []).reduce(0) { $0 + $1.0.size }
    }

    private struct Segment {
        var path: String
        var src: URL
        var offset: Int64
        var length: Int64
    }

    private actor SegmentQueue {
        var items: [Segment]
        init(_ items: [Segment]) { self.items = items }
        func next() -> Segment? { items.isEmpty ? nil : items.removeFirst() }
    }

    /// progress 会从多个并行连接同时调用，调用方要自己保证线程安全
    static func sendFiles(_ urls: [URL], to address: String, mode: String, peerVersion knownVersion: String? = nil,
                          progress: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        let cfg = Store.shared.config
        var items = try plan(urls)
        // 对方是 1.2.0 以上才支持分段并行
        let peerVersion = knownVersion ?? Links.shared.linked(address)?.version
        let streams = versionAtLeast(peerVersion, "1.2.0") ? max(1, cfg.streams) : 1
        if streams > 1 {
            for i in items.indices where !items[i].0.dir && items[i].0.size >= splitThreshold { items[i].0.split = true }
        }
        var segments: [Segment] = []
        for (e, src) in items where e.split == true {
            guard let src else { continue }
            var off: Int64 = 0
            while off < e.size {
                segments.append(Segment(path: e.path, src: src, offset: off, length: min(segmentSize, e.size - off)))
                off += segmentSize
            }
        }

        let tid = UUID().uuidString
        let conn = try await connect(address)
        defer { conn.cancel() }
        try await conn.writeFrame(Header(key: cfg.key, from: computerName, kind: "files", mode: mode,
                                         files: items.map(\.0), tid: tid))

        // 大文件分段，同时用多条连接发；小文件跟在主连接后面
        async let parts: Void = sendSegments(segments, to: address, tid: tid, streams: streams, progress: progress)
        for (entry, src) in items where !entry.dir && entry.split != true {
            guard let src else { continue }
            try await stream(src, offset: 0, length: entry.size, over: conn, name: entry.path, progress: progress)
        }
        try await parts
        let r = try await conn.readFrame(Reply.self, timeout: 120)
        guard r.ok else { throw PortalError.remote(r.error ?? "对方拒绝") }
        return r.name ?? address
    }

    private static func sendSegments(_ segments: [Segment], to address: String, tid: String, streams: Int,
                                     progress: (@Sendable (Int64) -> Void)?) async throws {
        guard !segments.isEmpty else { return }
        let cfg = Store.shared.config
        let queue = SegmentQueue(segments)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(streams, segments.count) {
                group.addTask {
                    let c = try await connect(address)
                    defer { c.cancel() }
                    while let s = await queue.next() {
                        try await c.writeFrame(Header(key: cfg.key, from: computerName, kind: "part", text: s.path,
                                                      size: s.length, tid: tid, offset: s.offset))
                        try await stream(s.src, offset: s.offset, length: s.length, over: c, name: s.path, progress: progress)
                        let r = try await c.readFrame(Reply.self, timeout: 120)
                        guard r.ok else { throw PortalError.remote(r.error ?? "对方拒绝") }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private static func stream(_ src: URL, offset: Int64, length: Int64, over conn: NWConnection, name: String,
                               progress: (@Sendable (Int64) -> Void)?) async throws {
        let fh = try FileHandle(forReadingFrom: src)
        defer { fh.closeFile() }
        fh.seek(toFileOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            let chunk = fh.readData(ofLength: Int(min(remaining, 256 << 10)))   // 小块发：慢网络下每块也能很快确认
            guard !chunk.isEmpty else { throw PortalError.remote("\(name) 在发送过程中被改动了") }
            try await conn.sendAsync(chunk, timeout: 120)
            remaining -= Int64(chunk.count)
            progress?(Int64(chunk.count))
        }
    }
}

/// "1.2.0" >= "1.1.9"
func versionAtLeast(_ v: String?, _ min: String) -> Bool {
    guard let v else { return false }
    let a = v.split(separator: ".").map { Int($0) ?? 0 }, b = min.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return true
}

/// 多线程累加计数
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ n: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; value += n; return value }
}

/// 限制刷新频率（多线程安全）
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    let interval: TimeInterval
    init(_ interval: TimeInterval) { self.interval = interval }
    func due() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(last) >= interval else { return false }
        last = Date()
        return true
    }
}
