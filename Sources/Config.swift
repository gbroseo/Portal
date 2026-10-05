import Foundation

/// 本机设置，存放在 ~/Library/Application Support/Portal/config.json（测试时可用 PORTAL_HOME 覆盖）。
struct Config: Codable {
    var key: String
    var port: UInt16 = 47321
    var autoSync = true
    var peers: [String] = []          // 手动添加的地址：host 或 host:port
    var learned: [String] = []        // 连接过并验证通过的电脑，自动记住
    var maxAutoFileMB = 200           // 复制文件时，超过这个大小就不自动同步
    var recvDir: String?

    init(key: String) { self.key = key }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? Config.newKey()
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 47321
        autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? true
        peers = try c.decodeIfPresent([String].self, forKey: .peers) ?? []
        learned = try c.decodeIfPresent([String].self, forKey: .learned) ?? []
        maxAutoFileMB = try c.decodeIfPresent(Int.self, forKey: .maxAutoFileMB) ?? 200
        recvDir = try c.decodeIfPresent(String.self, forKey: .recvDir)
    }

    var recvURL: URL {
        if let p = recvDir { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").appendingPathComponent("传送门")
    }

    static let home: URL = {
        if let p = ProcessInfo.processInfo.environment["PORTAL_HOME"] { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Portal")
    }()

    static var file: URL { home.appendingPathComponent("config.json") }

    static func load() -> Config {
        if let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Config.self, from: d) {
            return c
        }
        let c = Config(key: newKey())
        c.save()
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.home, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Config.file, options: .atomic) }
    }

    static func newKey() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let chars = (0..<12).map { _ in alphabet.randomElement()! }
        return stride(from: 0, to: 12, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    static func normalize(_ key: String) -> String {
        key.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// 线程安全的设置存取（网络线程和主线程都会读）。
final class Store {
    static let shared = Store()
    private let lock = NSLock()
    private var current = Config.load()
    private var loadedAt = Store.modified()

    private static func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Config.file.path))?[.modificationDate] as? Date
    }

    /// 配置文件被命令行（portal key 等）改过时自动重新读取
    var config: Config {
        lock.lock(); defer { lock.unlock() }
        let m = Store.modified()
        if m != loadedAt { current = Config.load(); loadedAt = m }
        return current
    }

    func update(_ change: (inout Config) -> Void) {
        lock.lock()
        if Store.modified() != loadedAt { current = Config.load() }
        change(&current)
        current.save()
        loadedAt = Store.modified()
        lock.unlock()
    }
}

let computerName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

private let logURL: URL = {
    if let p = ProcessInfo.processInfo.environment["PORTAL_LOG"] { return URL(fileURLWithPath: p) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Portal.log")
}()

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)   // 系统用的是佛历，强制公历
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

private let logQueue = DispatchQueue(label: "portal.log")

func log(_ message: String) {
    let line = "\(logFormatter.string(from: Date())) \(message)\n"
    logQueue.async {
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.data(using: .utf8)!.write(to: logURL)
        }
    }
}
