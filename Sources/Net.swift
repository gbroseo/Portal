import Foundation

let appVersion: String = {
    if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
    // 通过 ~/.local/bin/portal 软链接运行时，Bundle.main 找不到 app，顺着链接找回去
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}()

/// Tailscale 地址（100.64.0.0/10、fd7a:115c:a1e0::/48）。只有登录同一账号的设备才能从这些地址连进来。
func isTailnet(_ ip: String) -> Bool {
    if ip.contains(":") { return ip.lowercased().hasPrefix("fd7a:115c:a1e0") }
    let o = ip.split(separator: ".").compactMap { Int($0) }
    return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])
}

func isLoopback(_ ip: String) -> Bool { ip.hasPrefix("127.") || ip == "::1" }

/// "100.1.2.3:47321" → "100.1.2.3"
func hostOf(_ address: String) -> String {
    if address.filter({ $0 == ":" }).count == 1, let i = address.lastIndex(of: ":") { return String(address[..<i]) }
    return address
}

/// 本机所有网卡上的 IP
func localIPs() -> Set<String> {
    var result: Set<String> = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return result }
    defer { freeifaddrs(head) }
    var p = head
    while let ifa = p {
        if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            if getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(cString: buf).components(separatedBy: "%")[0])
            }
        }
        p = ifa.pointee.ifa_next
    }
    return result
}

/// 本机的 Tailscale 地址（没装或没连上时为 nil）
func myTailnetIP() -> String? {
    localIPs().filter { isTailnet($0) && $0.contains(".") }.sorted().first
}
