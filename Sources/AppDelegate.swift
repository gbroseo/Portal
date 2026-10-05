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
            self.remember(Clipboard.signature(reps))
            Clipboard.apply(reps)
            self.markClipboardSeen()
            HUD.show("📋 已收到 \(from) 的\(Clipboard.describe(reps))，可直接粘贴", level: .clip)
        }
        server.onFiles = { urls, from, mode in
            self.remember(Clipboard.signature(urls))
            Clipboard.applyFiles(urls)
            self.markClipboardSeen()
            let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个文件"
            HUD.show("📥 收到 \(from) 的 \(what)\n已放进「下载/传送门」，⌘V 可粘贴到任意文件夹", seconds: 4,
                     level: mode == "drop" ? .file : .clip)
            if mode == "drop" { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        server.onProgress = { st in self.showProgress(st, receiving: true) }
        Links.shared.server = server
        Links.shared.onChange = { self.refresh() }
        do { try server.start(port: Store.shared.config.port) } catch {
            HUD.show("⚠️ 传送门启动失败：\(error.localizedDescription)", seconds: 6, level: .error)
        }

        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in self.checkClipboard() }
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
                // 对每台能连上的电脑保持一条长连接，对方连不过来时靠它反向连接
                Links.shared.maintain(found.filter { $0.state == .online }.map(\.address))
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

    /// 最近收到 / 发出的内容特征。UU 远程等软件也会同步剪贴板，会把刚收到的内容再写一遍，
    /// 靠这个识别出来，避免又发回去（来回弹）。
    private var recent: [(sig: String, at: Date)] = []

    private func remember(_ sig: String?) {
        guard let sig else { return }
        recent.removeAll { Date().timeIntervalSince($0.at) > 60 }
        recent.append((sig, Date()))
    }

    private func isEcho(_ sig: String?) -> Bool {
        guard let sig else { return false }
        return recent.contains { $0.sig == sig && Date().timeIntervalSince($0.at) < 60 }
    }

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
            let sig = Clipboard.signature(reps)
            guard !isEcho(sig) else { return }
            remember(sig)
            let targets = online
            Task.detached {
                for p in targets {
                    do { _ = try await Sender.sendClip(reps, to: p.address) }
                    catch { log("同步剪贴板到 \(p.display) 失败：\(error.localizedDescription)") }
                }
            }
        case .files(let urls):
            let sig = Clipboard.signature(urls)
            guard !isEcho(sig) else { return }
            remember(sig)
            let limit = Int64(Store.shared.config.maxAutoFileMB) << 20
            let targets = online
            Task.detached {
                let size = Sender.totalSize(urls)
                if size > limit {
                    await MainActor.run {
                        HUD.show("文件较大（\(formatBytes(size))），没有自动同步\n把它拖到传送门小球上就能发送", seconds: 4, level: .file)
                    }
                    return
                }
                await self.send(urls, to: targets, mode: "clip")
            }
        }
    }

    private func markClipboardSeen() {
        lastChange = NSPasteboard.general.changeCount
        seenChange = lastChange
    }

    // MARK: - 发送文件

    func send(_ urls: [URL], to targets: [Peer], mode: String) async {
        let size = Sender.totalSize(urls)
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) 个项目"
        let total = max(size * Int64(targets.count), 1)
        let counter = Counter()
        let throttle = Throttle(0.25)
        await MainActor.run { transfers += 1 }
        var ok: [String] = []
        var failed: [String] = []
        for p in targets {
            do {
                let peerName = try await Sender.sendFiles(urls, to: p.address, mode: mode, peerVersion: p.version) { n in
                    let sent = counter.add(n)
                    if size > 4 << 20, throttle.due() {
                        let st = TransferStatus(receiving: false, name: name, done: sent, total: total)
                        DispatchQueue.main.async { self.showProgress(st, receiving: false) }
                    }
                }
                ok.append(peerName)
            } catch {
                log("发送到 \(p.display) 失败：\(error.localizedDescription)")
                failed.append("\(p.display)（\(error.localizedDescription)）")
            }
        }
        let ok2 = ok, failed2 = failed
        await MainActor.run {
            transfers -= 1
            if transfers == 0 { showProgress(nil, receiving: false) }
            if !failed2.isEmpty {
                HUD.show("⚠️ 发送失败：\(failed2.joined(separator: "、"))", seconds: 5, level: .error)
            } else {
                HUD.show("✅ \(name)（\(formatBytes(size))）已发送到 \(ok2.joined(separator: "、"))",
                         level: mode == "drop" || size > 4 << 20 ? .file : .clip)
            }
        }
    }

    private func sendInteractive(_ urls: [URL]) {
        let go = {
            let targets = self.online
            guard !targets.isEmpty else {
                HUD.show("没有找到在线的电脑\n请确认另一台电脑开着传送门和 Tailscale", seconds: 4, level: .error)
                return
            }
            Task.detached { await self.send(urls, to: targets, mode: "drop") }
        }
        if online.isEmpty { refresh(then: go) } else { go() }
    }

    // MARK: - 进度显示

    /// 每个方向一个：速度用滑动平均，算剩余时间
    private struct Tracker {
        var status: TransferStatus
        var sampleBytes: Int64
        var sampleTime: Date
        var lastChange: Date
        var speed: Double = 0
    }
    private var trackers: [Bool: Tracker] = [:]
    private var progressTimer: Timer?

    private func showProgress(_ s: TransferStatus?, receiving: Bool) {
        guard let s else {
            trackers[receiving] = nil
            renderProgress()
            return
        }
        let now = Date()
        if var t = trackers[receiving], t.status.name == s.name {
            if s.done != t.status.done { t.lastChange = now }
            let dt = now.timeIntervalSince(t.sampleTime)
            if dt >= 1 {
                let inst = Double(s.done - t.sampleBytes) / dt
                t.speed = t.speed == 0 ? inst : t.speed * 0.6 + inst * 0.4
                t.sampleBytes = s.done
                t.sampleTime = now
            }
            t.status = s
            trackers[receiving] = t
        } else {
            trackers[receiving] = Tracker(status: s, sampleBytes: s.done, sampleTime: now, lastChange: now)
        }
        renderProgress()
        // 网络卡住时进度不会再更新，定时刷新一下好显示「等待网络」
        if progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.renderProgress() }
        }
    }

    private func progressLine(_ t: Tracker, receiving: Bool) -> String {
        let s = t.status
        let pct = Int(Double(s.done) / Double(max(s.total, 1)) * 100)
        let verb = receiving ? "正在接收" : "正在发送"
        if Date().timeIntervalSince(t.lastChange) > 5 {
            return "\(receiving ? "↓" : "↑") \(verb) \(s.name)  \(pct)% · 网络较慢，等待中…"
        }
        var line = "\(receiving ? "↓" : "↑") \(verb) \(s.name)  \(pct)%"
        if t.speed > 0 {
            line += " · \(formatBytes(Int64(t.speed)))/s"
            let left = Double(s.total - s.done) / t.speed
            line += " · 剩余约 " + (left < 60 ? "\(max(1, Int(left))) 秒" : "\(Int(left / 60) + 1) 分钟")
        }
        return line
    }

    private func renderProgress() {
        guard let (dir, t) = trackers.first(where: { $0.key }) ?? trackers.first else {
            statusItem.button?.title = ""
            float.progressText = nil
            float.toolTip = FloatingPortal.defaultTip
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }
        let pct = Int(Double(t.status.done) / Double(max(t.status.total, 1)) * 100)
        let short = "\(dir ? "↓" : "↑")\(pct)%"
        statusItem.button?.title = " " + short
        float.progressText = short
        float.toolTip = progressLine(t, receiving: dir)
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
        for (dir, t) in trackers.sorted(by: { $0.key && !$1.key }) {
            menu.addItem(disabled(progressLine(t, receiving: dir)))
        }
        menu.addItem(.separator())

        // 只显示有名字的离线设备（Tailscale 列表里的），记住的旧地址离线时不显示
        let shown = peers.filter { $0.state != .offline || $0.label != $0.address }
        if shown.isEmpty {
            menu.addItem(disabled(myTailnetIP() == nil ? "Tailscale 未连接，请打开 Tailscale 并登录" : "正在寻找其他电脑…"))
            menu.addItem(disabled("（另一台也要打开传送门和 Tailscale，用同一个账号）"))
        }
        for p in shown {
            switch p.state {
            case .online: menu.addItem(disabled("🟢 \(p.display)  已连接"))
            case .wrongKey: menu.addItem(disabled("🟠 \(p.display)  传送门版本太旧，请在那台更新"))
            case .offline: menu.addItem(disabled("⚪️ \(p.label)  未打开传送门"))
            }
        }
        menu.addItem(item("刷新", #selector(refreshClicked)))
        menu.addItem(.separator())

        let sync = item("自动同步剪贴板（文字 / 图片 / 文件）", #selector(toggleSync))
        sync.state = cfg.autoSync ? .on : .off
        menu.addItem(sync)
        menu.addItem(item("发送文件…", #selector(pickFiles)))
        menu.addItem(item("打开接收文件夹", #selector(openInbox)))
        let notifyMenu = NSMenu()
        for (key, title) in [("all", "全部提示（包括剪贴板同步）"), ("files", "只提示文件传输和错误"), ("off", "全部关闭")] {
            let m = item(title, #selector(setNotify(_:)))
            m.representedObject = key
            m.state = cfg.notify == key ? .on : .off
            notifyMenu.addItem(m)
        }
        let notifyItem = NSMenuItem(title: "提示消息", action: nil, keyEquivalent: "")
        notifyItem.submenu = notifyMenu
        menu.addItem(notifyItem)
        let ball = item("显示悬浮小球（拖文件到小球上发送）", #selector(toggleFloat))
        ball.state = UserDefaults.standard.bool(forKey: "hideFloat") ? .off : .on
        menu.addItem(ball)
        menu.addItem(.separator())

        // 同一 Tailscale 账号的电脑自动连接；配对码只在不用 Tailscale、走局域网时才需要
        let advanced = NSMenu()
        advanced.addItem(item("复制本机配对码：\(cfg.key)", #selector(copyKey)))
        advanced.addItem(item("输入另一台的配对码…", #selector(enterKey)))
        advanced.addItem(item("手动添加电脑地址…", #selector(addPeer)))
        advanced.addItem(.separator())
        advanced.addItem(disabled("版本 \(appVersion)"))
        let adv = NSMenuItem(title: "高级（局域网配对，一般用不到）", action: nil, keyEquivalent: "")
        adv.submenu = advanced
        menu.addItem(adv)
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

    @objc private func setNotify(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Store.shared.update { $0.notify = key }
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
    /// clip：剪贴板同步（默认不提示）；file：文件传输；error：出错；always：用户自己点的操作
    enum Level { case clip, file, error, always }

    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, seconds: Double = 2.5, level: Level = .always) {
        switch (Store.shared.config.notify, level) {
        case (_, .always), ("all", _): break
        case ("files", .file), ("files", .error): break
        default: return
        }
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
