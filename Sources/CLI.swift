import AppKit

/// 命令行：portal send <文件…> / portal text <文字> / portal peers / portal key
enum CLI {
    static let usage = """
    传送门命令行
      portal send <文件或文件夹…> [--to 电脑名]   发送到其他电脑（放进对方「下载/传送门」，并放进对方剪贴板）
      portal text <文字> [--to 电脑名]            把文字放进对方剪贴板
      portal peers                                列出能连上的电脑
      portal key [新配对码]                        查看 / 设置本机配对码
      portal diag                                 诊断信息
      portal remote <地址> diag|clip              查看另一台的诊断 / 剪贴板（测试用）
      （send / text 可加 --host IP 直接指定对方地址）
    """

    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    static func run(_ args: [String]) async -> Int32 {
        var rest = Array(args.dropFirst())
        var filter: String?
        if let i = rest.firstIndex(of: "--to"), i + 1 < rest.count {
            filter = rest[i + 1].lowercased()
            rest.removeSubrange(i...i + 1)
        }
        var host: String?
        if let i = rest.firstIndex(of: "--host"), i + 1 < rest.count {
            host = rest[i + 1]
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
                case .wrongKey: s = "对方版本太旧，请更新"
                case .offline: s = "未运行传送门"
                }
                print("\(p.display)\t\(p.address)\t\(s)\tv\(p.version ?? "?")")
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
            let candidates = host != nil ? [await Peers.ping(host!, label: host!)] : await Peers.scan()
            let targets = candidates.filter { p in
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

        case "diag":
            print(await Diag.text())
            return 0

        case "remote":
            // portal remote <地址> diag | clip | copy <文字> | copyimage | copyfile <MB>
            guard rest.count >= 2 else { err("用法：portal remote <地址> diag|clip|copy 文字|copyimage|copyfile MB"); return 1 }
            let cfg = Store.shared.config
            var h = Header(key: cfg.key, from: computerName, kind: "diag")
            switch rest[1] {
            case "diag": break
            case "clip": h.kind = "clipinfo"
            case "copy": h.kind = "simulate"; h.mode = "text"; h.text = rest.dropFirst(2).joined(separator: " ")
            case "copyimage": h.kind = "simulate"; h.mode = "image"; h.text = rest.dropFirst(2).joined(separator: " ")
            case "copyfile": h.kind = "simulate"; h.mode = "file"; h.size = Int64(rest.count > 2 ? rest[2] : "1") ?? 1
            default: err("未知操作 \(rest[1])"); return 1
            }
            do {
                let conn = try await Sender.connect(rest[0])
                defer { conn.cancel() }
                try await conn.writeFrame(h)
                let r = try await conn.readFrame(Reply.self)
                print("[\(r.name ?? "?") v\(r.version ?? "?")] ok=\(r.ok) \(r.error ?? "")")
                if let info = r.info { print(info) }
                return r.ok ? 0 : 1
            } catch {
                err("\(error.localizedDescription)")
                return 1
            }

        default:
            print(usage)
            return 0
        }
    }
}
