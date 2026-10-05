import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let server = Server()
    private let float = FloatingPortal()
    private var peers: [Peer] = []
    private var scanning = false
    private var lastChange = NSPasteboard.general.changeCount
    private var seenChange = NSPasteboard.general.changeCount
    private var transfers = 0

    private var online: [Peer] { peers.filter { $0.state == .online } }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "arrow.left.arrow.right.circle", accessibilityDescription: "传送门")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        // 文件拖到菜单栏图标上 = 发送给另一台电脑
        statusItem.button?.window?.registerForDraggedTypes([.fileURL])
        statusItem.button?.window?.delegate = self

        float.onDrop = { urls in self.sendInteractive(urls) }
        float.menuProvider = {
            let m = NSMenu()
            self.menuNeedsUpdate(m)
            return m
        }
        float.setVisible(!UserDefaults.standard.bool(forKey: "hideFloat"))

        server.onClip = { reps, from in
            Clipboard.apply(reps)
            self.markClipboardSeen()
            HUD.show("📋 已收到 \(from) 的\(Clipboard.describe(reps))，可直接粘贴")
        }
        server.onFiles = { urls, from, mode in
            Clipboard.applyFiles(urls)
            self.markClipboardSeen()
            let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件"
            HUD.show("📥 收到 \(from) 的 \(what)\n已放进「下载/传送门」，⌘V 可粘贴到任意文件夹", seconds: 4)
            if mode == "drop" { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        server.onProgress = { frac in self.showProgress(frac, receiving: true) }
        do { try server.start(port: Store.shared.config.port) } catch {
            HUD.show("⚠️ 传送门启动失败：\(error.localizedDescription)", seconds: 6)
        }

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in self.checkClipboard() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in self.refresh() }
        refresh()
        setupLoginItemOnce()
        log("传送门已启动（\(computerName)）")
    }

    // MARK: - 发现电脑

    private func refresh(then: (() -> Void)? = nil) {
        guard !scanning else { then?(); return }
        scanning = true
        Task.detached {
            let found = await Peers.scan()
            await MainActor.run {
                let before = self.online.map(\.address)
                self.peers = found
                self.scanning = false
                let after = self.online.map(\.address)
                if before != after { log("在线电脑：\(self.online.map(\.display))") }
                self.updateButton()
                then?()
            }
        }
    }

    private func updateButton() {
        statusItem.button?.appearsDisabled = online.isEmpty
        float.connected = !online.isEmpty
    }

    // MARK: - 剪贴板同步

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChange else { return }
        // 别的程序是先清空再写入的，刚变化时可能还没写完，等下一轮内容稳定了再读
        if count != seenChange { seenChange = count; return }
        lastChange = count
        guard Store.shared.config.autoSync, !online.isEmpty else { return }

        switch Clipboard.snapshot() {
        case .none:
            break
        case .reps(let reps):
            let targets = online
            Task.detached {
                for p in targets {
                    do { _ = try await Sender.sendClip(reps, to: p.address) }
                    catch { log("同步剪贴板到 \(p.display) 失败：\(error.localizedDescription)") }
                }
            }
        case .files(let urls):
            let limit = Int64(Store.shared.config.maxAutoFileMB) << 20
            let targets = online
            Task.detached {
                let size = Sender.totalSize(urls)
                if size > limit {
                    await MainActor.run {
                        HUD.show("文件较大（\(formatBytes(size))），没有自动同步\n把它拖到屏幕边上的传送门小球上就能发送", seconds: 4)
                    }
                    return
                }
                await self.send(urls, to: targets, mode: "clip", quiet: size < 8 << 20)
            }
        }
    }

    private func markClipboardSeen() {
        lastChange = NSPasteboard.general.changeCount
        seenChange = lastChange
    }

    // MARK: - 发送文件

    func send(_ urls: [URL], to targets: [Peer], mode: String, quiet: Bool = false) async {
        let size = Sender.totalSize(urls)
        let total = max(size * Int64(targets.count), 1)
        var sent: Int64 = 0
        var lastUI = Date.distantPast
        await MainActor.run { transfers += 1; if !quiet { showProgress(0, receiving: false) } }
        var ok: [String] = []
        var failed: [String] = []
        for p in targets {
            do {
                let name = try await Sender.sendFiles(urls, to: p.address, mode: mode) { n in
                    sent += n
                    if !quiet, Date().timeIntervalSince(lastUI) > 0.3 {
                        lastUI = Date()
                        let frac = Double(sent) / Double(total)
                        DispatchQueue.main.async { self.showProgress(frac, receiving: false) }
                    }
                }
                ok.append(name)
            } catch {
                log("发送到 \(p.display) 失败：\(error.localizedDescription)")
                failed.append("\(p.display)（\(error.localizedDescription)）")
            }
        }
        let ok2 = ok, failed2 = failed
        await MainActor.run {
            transfers -= 1
            showProgress(nil, receiving: false)
            if !failed2.isEmpty {
                HUD.show("⚠️ 发送失败：\(failed2.joined(separator: "、"))", seconds: 5)
            } else if !quiet || mode == "drop" {
                let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个项目"
                HUD.show("✅ \(what)（\(formatBytes(size))）已发送到 \(ok2.joined(separator: "、"))")
            }
        }
    }

    private func sendInteractive(_ urls: [URL]) {
        let go = {
            let targets = self.online
            guard !targets.isEmpty else {
                HUD.show("没有找到在线的电脑\n请确认另一台电脑开着传送门和 Tailscale", seconds: 4)
                return
            }
            Task.detached { await self.send(urls, to: targets, mode: "drop") }
        }
        if online.isEmpty { refresh(then: go) } else { go() }
    }

    private func showProgress(_ frac: Double?, receiving: Bool) {
        if let frac {
            statusItem.button?.title = " \(receiving ? "↓" : "↑")\(Int(frac * 100))%"
            float.progressText = "\(receiving ? "↓" : "↑")\(Int(frac * 100))%"
        } else if transfers == 0 {
            statusItem.button?.title = ""
            float.progressText = nil
        }
    }

    // MARK: - 拖放到菜单栏图标

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func draggingExited(_ sender: NSDraggingInfo?) { statusItem.button?.highlight(false) }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        sendInteractive(urls)
        return true
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = Store.shared.config
        menu.addItem(disabled("传送门 · 本机：\(computerName)"))
        menu.addItem(.separator())

        if peers.isEmpty {
            menu.addItem(disabled(Peers.tailscaleCLI == nil ? "未检测到 Tailscale，请先安装并登录" : "还没发现其他电脑"))
        }
        for p in peers {
            switch p.state {
            case .online: menu.addItem(disabled("🟢 \(p.display)  已连接"))
            case .wrongKey: menu.addItem(disabled("🟠 \(p.display)  配对码不一致"))
            case .offline: menu.addItem(disabled("⚪️ \(p.label)  未运行传送门"))
            }
        }
        menu.addItem(item("刷新", #selector(refreshClicked)))
        menu.addItem(.separator())

        let sync = item("自动同步剪贴板（文字 / 图片 / 文件）", #selector(toggleSync))
        sync.state = cfg.autoSync ? .on : .off
        menu.addItem(sync)
        menu.addItem(item("发送文件…", #selector(pickFiles)))
        menu.addItem(item("打开接收文件夹", #selector(openInbox)))
        let ball = item("显示悬浮小球（拖文件到小球上发送）", #selector(toggleFloat))
        ball.state = UserDefaults.standard.bool(forKey: "hideFloat") ? .off : .on
        menu.addItem(ball)
        menu.addItem(.separator())

        menu.addItem(item("复制本机配对码：\(cfg.key)", #selector(copyKey)))
        menu.addItem(item("输入另一台的配对码…", #selector(enterKey)))
        menu.addItem(item("手动添加电脑地址…", #selector(addPeer)))
        if #available(macOS 13.0, *) {
            let login = item("开机自动启动", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(item("退出传送门", #selector(quit)))
        refresh()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        m.isEnabled = false
        return m
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = self
        return m
    }

    @objc private func refreshClicked() { refresh() }

    @objc private func toggleSync() { Store.shared.update { $0.autoSync.toggle() } }

    @objc private func pickFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "发送"
        guard panel.runModal() == .OK else { return }
        sendInteractive(panel.urls)
    }

    @objc private func toggleFloat() {
        let hide = !UserDefaults.standard.bool(forKey: "hideFloat")
        UserDefaults.standard.set(hide, forKey: "hideFloat")
        float.setVisible(!hide)
    }

    @objc private func openInbox() {
        let dir = Store.shared.config.recvURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func copyKey() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Store.shared.config.key, forType: .string)
        HUD.show("配对码已复制")
    }

    @objc private func enterKey() {
        guard let key = ask("输入另一台电脑的配对码", info: "两台电脑用同一个 Tailscale 账号时不需要配对码。\n只有手动添加的电脑才需要两边一致。",
                            placeholder: "XXXX-XXXX-XXXX"), Config.normalize(key).count == 12 else { return }
        let n = Config.normalize(key)
        let formatted = stride(from: 0, to: 12, by: 4).map { i -> String in
            let s = n.index(n.startIndex, offsetBy: i)
            return String(n[s..<n.index(s, offsetBy: 4)])
        }.joined(separator: "-")
        Store.shared.update { $0.key = formatted }
        refresh()
    }

    @objc private func addPeer() {
        guard let addr = ask("手动添加电脑地址", info: "填另一台电脑的 IP（例如 100.101.102.103），一般不需要：同一 Tailscale 账号的电脑会自动出现。",
                             placeholder: "100.x.x.x"), !addr.isEmpty else { return }
        Store.shared.update { if !$0.peers.contains(addr) { $0.peers.append(addr) } }
        refresh()
    }

    @available(macOS 13.0, *)
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { HUD.show("设置开机启动失败：\(error.localizedDescription)") }
    }

    private func setupLoginItemOnce() {
        guard #available(macOS 13.0, *), !UserDefaults.standard.bool(forKey: "loginItemConfigured"),
              Bundle.main.bundlePath.hasPrefix("/Applications") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        try? SMAppService.mainApp.register()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func ask(_ title: String, info: String, placeholder: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 屏幕顶部的浮动提示，全屏（比如 UU 远程全屏）时也能看到。
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, seconds: Double = 2.5) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 420
        let size = label.fittingSize
        let w = size.width + 40, h = size.height + 24

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        label.frame = NSRect(x: 20, y: 12, width: size.width, height: size.height)
        fx.addSubview(label)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.visibleFrame.maxY - h - 12, width: w, height: h)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = fx
        p.orderFrontRegardless()
        panel = p

        let work = DispatchWorkItem { p.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
