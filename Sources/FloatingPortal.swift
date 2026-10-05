import AppKit

/// 屏幕边上的悬浮小球：把文件拖上来就发送，点一下弹出菜单，按住可以拖到别的位置。
/// 菜单栏图标多了会被系统藏起来，UU 远程全屏时也看不到菜单栏，所以用它当主要入口。
final class FloatingPortal: NSView {
    var onDrop: (([URL]) -> Void)?
    var menuProvider: (() -> NSMenu)?
    private let panel: NSPanel
    private var dragTarget = false
    private var mouseDownAt: NSPoint?
    private var moved = false
    var connected = false { didSet { needsDisplay = true } }
    var progressText: String? { didSet { needsDisplay = true } }

    static let size: CGFloat = 52

    init() {
        let s = FloatingPortal.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(frame: NSRect(x: 0, y: 0, width: s, height: s))
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = self
        registerForDraggedTypes([.fileURL])
        toolTip = "传送门：把文件拖到这里发送到另一台电脑；点一下打开菜单"

        let saved = UserDefaults.standard.string(forKey: "floatOrigin").map(NSPointFromString)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var origin = saved ?? NSPoint(x: screen.visibleFrame.maxX - s - 8, y: screen.visibleFrame.minY + 140)
        if !NSScreen.screens.contains(where: { $0.frame.contains(origin) }) {
            origin = NSPoint(x: screen.visibleFrame.maxX - s - 8, y: screen.visibleFrame.minY + 140)
        }
        panel.setFrameOrigin(origin)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        let circle = NSBezierPath(ovalIn: r)
        let alpha: CGFloat = dragTarget ? 1 : 0.88
        let c1 = connected ? NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.98, alpha: alpha) : NSColor(white: 0.55, alpha: alpha)
        let c2 = connected ? NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.70, alpha: alpha) : NSColor(white: 0.70, alpha: alpha)
        NSGradient(starting: c1, ending: c2)!.draw(in: circle, angle: 45)
        if dragTarget {
            NSColor.white.setStroke()
            circle.lineWidth = 3
            circle.stroke()
        }

        if let text = progressText {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white]
            let sz = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
            return
        }
        let symbol = dragTarget ? "arrow.down.circle" : "arrow.left.arrow.right"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .semibold)) {
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: bounds.midX - img.size.width / 2, y: bounds.midY - img.size.height / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    // MARK: 点击 / 拖动小球

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = NSEvent.mouseLocation
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let now = NSEvent.mouseLocation
        if !moved, hypot(now.x - start.x, now.y - start.y) < 3 { return }
        moved = true
        var origin = panel.frame.origin
        origin.x += now.x - start.x
        origin.y += now.y - start.y
        panel.setFrameOrigin(origin)
        mouseDownAt = now
    }

    override func mouseUp(with event: NSEvent) {
        if moved {
            UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "floatOrigin")
        } else if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        }
        mouseDownAt = nil
    }

    // MARK: 拖文件进来

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) else { return [] }
        dragTarget = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragTarget = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragTarget = false
        needsDisplay = true
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
