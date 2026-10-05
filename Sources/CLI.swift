import AppKit

/// 命令行：portal send <文件…> / portal text <文字> / portal peers / portal key
enum CLI {
    static let usage = """
    传送门命令行
      portal send <文件或文件夹…> [--to 电脑名]   发送到其他电脑（放进对方「下载/传送门」，并放进对方剪贴板）
      portal text <文字> [--to 电脑名]            把文字放进对方剪贴板
      portal peers                                列出能连上的电脑
      portal key [新配对码]                        查看 / 设置本机配对码
    """

    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    static func run(_ args: [String]) async -> Int32 {
        var rest = Array(args.dropFirst())
        var filter: String?
        if let i = rest.firstIndex(of: "--to"), i + 1 < rest.count {
            filter = rest[i + 1].lowercased()
            rest.removeSubrange(i...i + 1)
        }

        switch args[0] {
        case "peers":
            let peers = await Peers.scan()
            if peers.isEmpty { print(Peers.tailscaleCLI == nil ? "未检测到 Tailscale" : "没有发现其他电脑") }
            for p in peers {
                let s: String
                switch p.state {
                case .online: s = "已连接"
                case .wrongKey: s = "配对码不一致"
                case .offline: s = "未运行传送门"
                }
                print("\(p.display)\t\(p.address)\t\(s)")
            }
            return 0

        case "key":
            if let k = rest.first {
                guard Config.normalize(k).count == 12 else { err("配对码应为 12 位"); return 1 }
                Store.shared.update { $0.key = k.uppercased() }
            }
            print(Store.shared.config.key)
            return 0

        case "send", "text":
            guard !rest.isEmpty else { err(usage); return 1 }
            let targets = await Peers.scan().filter { p in
                p.state == .online && (filter == nil || [p.display, p.label, p.address].contains { $0.lowercased().contains(filter!) })
            }
            guard !targets.isEmpty else { err("没有找到在线的电脑（portal peers 查看）"); return 1 }

            if args[0] == "text" {
                let data = rest.joined(separator: " ").data(using: .utf8)!
                let reps = [(Rep(item: 0, type: NSPasteboard.PasteboardType.string.rawValue, size: data.count), data)]
                var code: Int32 = 0
                for p in targets {
                    do { print("已发送到 \(try await Sender.sendClip(reps, to: p.address))") }
                    catch { err("\(p.display)：\(error.localizedDescription)"); code = 1 }
                }
                return code
            }

            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let urls = rest.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
            let size = Sender.totalSize(urls)
            var code: Int32 = 0
            for p in targets {
                let start = Date()
                var sent: Int64 = 0
                var last = Date.distantPast
                do {
                    let name = try await Sender.sendFiles(urls, to: p.address, mode: "drop") { n in
                        sent += n
                        if Date().timeIntervalSince(last) > 0.5 {
                            last = Date()
                            err(String(format: "\r→ %@  %3.0f%%  %@/s", p.display, Double(sent) / Double(max(size, 1)) * 100,
                                       formatBytes(Int64(Double(sent) / max(Date().timeIntervalSince(start), 0.001)))))
                        }
                    }
                    let secs = Date().timeIntervalSince(start)
                    print("已发送到 \(name)：\(formatBytes(size))，用时 \(String(format: "%.1f", secs)) 秒")
                } catch {
                    err("\n\(p.display)：\(error.localizedDescription)")
                    code = 1
                }
            }
            return code

        default:
            print(usage)
            return 0
        }
    }
}
