import AppKit
import CoreGraphics
import Darwin

enum SelectionMode: String {
    case area, window
}

struct WindowTarget {
    let id: CGWindowID
    let frame: NSRect
}

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
    weak var controller: SelectionController?
    private var cursorTracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking {
            removeTrackingArea(cursorTracking)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved,
                      .activeInActiveApp, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        cursorTracking = tracking
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.pointerMoved()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.pointerMoved()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
        controller?.pointerDown()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.pointerMoved()
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.pointerUp()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.finish(reason: "cancelled")
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 ||
            (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q") {
            controller?.finish(reason: "cancelled")
        }
        // Consume other keys while the selection overlay owns keyboard focus.
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let window else { return }

        // Keep the clear selection mouse-sensitive instead of creating a click-through hole.
        NSColor.black.withAlphaComponent(0.002).setFill()
        bounds.fill()

        let shade = NSBezierPath(rect: bounds)
        var localSelection: NSRect?
        if let selection = controller.selection {
            let local = selection.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            let intersection = local.intersection(bounds)
            if !intersection.isNull && !intersection.isEmpty {
                shade.appendRect(intersection)
                localSelection = local
            }
        }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        shade.fill()

        if let localSelection {
            let border = NSBezierPath(rect: localSelection)
            border.lineWidth = 2
            NSColor(calibratedRed: 0.2, green: 0.6, blue: 1, alpha: 1).setStroke()
            border.stroke()
        }
    }
}

final class SelectionController: NSObject, NSApplicationDelegate {
    let mode: SelectionMode
    private let previousApp = NSWorkspace.shared.frontmostApplication
    private var windows: [SelectionWindow] = []
    private var targets: [WindowTarget] = []
    private var anchor: NSPoint?
    private var areaScreen: NSScreen?
    private var pressedWindow: CGWindowID?
    private var hoveredWindow: WindowTarget?
    private var signals: [DispatchSourceSignal] = []
    private var parentMonitor: DispatchSourceProcess?
    private var started = false
    private var finished = false
    private var primaryTop: CGFloat = 0
    var selection: NSRect?

    init(mode: SelectionMode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let primary = NSScreen.screens.first else {
            finish(reason: "no-display")
            return
        }
        primaryTop = primary.frame.maxY
        // Capture the window order before our own overlays appear.
        if mode == .window {
            targets = visibleWindows()
            if targets.isEmpty {
                finish(reason: "no-windows")
                return
            }
        }

        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                         backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
            window.orderFrontRegardless()
        }

        let pointer = NSEvent.mouseLocation
        let initial = windows.first(where: { $0.frame.contains(pointer) }) ?? windows[0]
        NSApp.activate(ignoringOtherApps: true)
        initial.makeKeyAndOrderFront(nil)
        started = true
        pointerMoved()
        NSCursor.crosshair.set()

        for code in [SIGTERM, SIGINT, SIGHUP] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(reason: "terminated") }
            source.resume()
            signals.append(source)
        }
        // Also remove the overlays if the Hammerspoon process exits unexpectedly.
        let monitor = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
        monitor.setEventHandler { [weak self] in self?.finish(reason: "parent-exited") }
        monitor.resume()
        parentMonitor = monitor
    }

    private func visibleWindows() -> [WindowTarget] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { item in
            guard let number = item[kCGWindowNumber as String] as? NSNumber,
                  let layer = item[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let owner = item[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value != getpid(),
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds),
                  quartz.width > 1, quartz.height > 1 else { return nil }
            if let alpha = item[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 {
                return nil
            }
            return WindowTarget(id: number.uint32Value,
                                frame: NSRect(x: quartz.minX, y: primaryTop - quartz.maxY,
                                              width: quartz.width, height: quartz.height))
        }
    }

    func pointerDown() {
        pointerMoved()
        if mode == .area {
            anchor = NSEvent.mouseLocation
            areaScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            selection = nil
        } else {
            pressedWindow = hoveredWindow?.id
        }
        redraw()
    }

    func pointerMoved() {
        let point = NSEvent.mouseLocation
        if mode == .window {
            hoveredWindow = targets.first(where: { $0.frame.contains(point) })
            selection = hoveredWindow?.frame
        } else if let anchor, let areaScreen {
            // Match the existing area capture: stay on the display where dragging began.
            let frame = areaScreen.frame
            let end = NSPoint(x: min(max(point.x, frame.minX), frame.maxX),
                              y: min(max(point.y, frame.minY), frame.maxY))
            selection = NSRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                               width: abs(end.x - anchor.x), height: abs(end.y - anchor.y))
        }
        redraw()
    }

    func pointerUp() {
        pointerMoved()
        if mode == .area {
            guard let selection, selection.width >= 2, selection.height >= 2 else {
                anchor = nil
                areaScreen = nil
                selection = nil
                redraw()
                return
            }
            finish(reason: "selected", rect: selection)
        } else if let target = hoveredWindow, target.id == pressedWindow {
            finish(reason: "selected", rect: target.frame, windowID: target.id)
        } else {
            pressedWindow = nil
        }
    }

    private func redraw() {
        for window in windows { window.contentView?.needsDisplay = true }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if started { finish(reason: "deactivated", restoreFocus: false) }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if started { finish(reason: "displays-changed") }
    }

    func finish(reason: String, rect: NSRect? = nil, windowID: CGWindowID? = nil,
                restoreFocus: Bool = true) {
        guard !finished else { return }
        finished = true
        parentMonitor?.cancel()
        for source in signals { source.cancel() }
        for window in windows { window.orderOut(nil) }
        // Remove our cursor ownership; the revealed application chooses its own cursor.
        if restoreFocus, NSApp.isActive {
            previousApp?.activate(options: [])
        }

        var result: [String: Any] = ["status": rect == nil ? "cancelled" : "selected",
                                     "reason": reason, "mode": mode.rawValue]
        if let rect {
            result["coordinateSystem"] = "macOS-top-left-points"
            result["rect"] = ["x": rect.minX, "y": primaryTop - rect.maxY,
                              "w": rect.width, "h": rect.height]
        }
        if let windowID { result["windowID"] = windowID }
        if mode == .area, rect != nil, let areaScreen,
           let number = areaScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            result["screenID"] = number.uint32Value
        }
        if var data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
        NSApp.terminate(nil)
    }
}

let argument = CommandLine.arguments.dropFirst().first ?? "area"
guard let mode = SelectionMode(rawValue: argument) else {
    FileHandle.standardError.write(Data("Usage: ScreenshotPicker [area|window]\n".utf8))
    exit(2)
}
let app = NSApplication.shared
let controller = SelectionController(mode: mode)
app.setActivationPolicy(.accessory)
app.delegate = controller
app.run()
