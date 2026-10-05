import Foundation
import Network

/// 发送端：把剪贴板内容或文件推给一台电脑。
enum Sender {
    /// 先直接连；连不上但对方正连着本机时，请它反向连过来
    static func connect(_ address: String, timeout: TimeInterval = 5) async throws -> NWConnection {
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
        let conn = try await connect(address)
        defer { conn.cancel() }
        try await conn.writeFrame(Header(key: cfg.key, from: computerName, kind: "clip", mode: "clip",
                                         reps: reps.map(\.0)))
        for (_, data) in reps where !data.isEmpty { try await conn.sendAsync(data) }
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

    static func sendFiles(_ urls: [URL], to address: String, mode: String,
                          progress: ((Int64) -> Void)? = nil) async throws -> String {
        let cfg = Store.shared.config
        let items = try plan(urls)
        let conn = try await connect(address)
        defer { conn.cancel() }
        try await conn.writeFrame(Header(key: cfg.key, from: computerName, kind: "files", mode: mode,
                                         files: items.map(\.0)))
        for (entry, src) in items {
            guard let src, !entry.dir else { continue }
            let fh = try FileHandle(forReadingFrom: src)
            defer { fh.closeFile() }
            var remaining = entry.size
            while remaining > 0 {
                let chunk = fh.readData(ofLength: Int(min(remaining, Int64(chunkSize))))
                guard !chunk.isEmpty else { throw PortalError.remote("\(entry.path) 在发送过程中被改动了") }
                try await conn.sendAsync(chunk)
                remaining -= Int64(chunk.count)
                progress?(Int64(chunk.count))
            }
        }
        let r = try await conn.readFrame(Reply.self)
        guard r.ok else { throw PortalError.remote(r.error ?? "对方拒绝") }
        return r.name ?? address
    }
}
