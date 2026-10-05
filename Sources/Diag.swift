import Foundation

enum Diag {
    static func text() async -> String {
        let cfg = Store.shared.config
        var lines: [String] = []
        lines.append("电脑：\(computerName)  系统：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("传送门：\(appVersion)  端口：\(cfg.port)  本机 Tailscale 地址：\(myTailnetIP() ?? "无")")
        lines.append("Tailscale 命令行：\(Peers.tailscaleCLI ?? "未找到")")
        let ts = Peers.tailscalePeers()
        lines.append("Tailscale 同账号在线设备：\(ts.map { "\($0.label) \($0.address)" })")
        if let e = Peers.lastError { lines.append("Tailscale 错误：\(e)") }
        lines.append("记住的电脑：\(cfg.learned)  手动地址：\(cfg.peers)")
        lines.append("长连接 连进来：\(Links.shared.incomingIPs)  连出去：\(Links.shared.outgoingAddresses)")
        lines.append("自动同步剪贴板：\(cfg.autoSync)")
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Portal.log")
        if let log = try? String(contentsOf: logURL, encoding: .utf8) {
            lines.append("--- 最近日志 ---")
            lines.append(contentsOf: log.split(separator: "\n").suffix(25).map(String.init))
        }
        return lines.joined(separator: "\n")
    }
}
