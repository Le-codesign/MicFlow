import AppKit

/// Lets the user pick part of the screen: the screens dim, the user drags a rectangle, and the
/// result comes back in global Cocoa coordinates (origin at the bottom left of the main screen).
/// A click without dragging picks the whole screen under the pointer. Esc cancels.
@MainActor
final class AreaSelector {
    private static var current: AreaSelector?

    private var windows: [NSWindow] = []
    private let completion: (CGRect?) -> Void

    /// `hint` is shown at the top of each screen until the user starts dragging.
    static func select(hint: String, completion: @escaping (CGRect?) -> Void) {
        current?.finish(nil)
        let selector = AreaSelector(completion: completion)
        current = selector
        selector.show(hint: hint)
    }

    private init(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
    }

    private func show(hint: String) {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), hint: hint)
            view.onFinish = { [weak self] rect in
                self?.finish(rect.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) })
            }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            if screen.frame.contains(mouse) { window.makeKey() }
            windows.append(window)
        }
        NSCursor.crosshair.push()
    }

    private func finish(_ rect: CGRect?) {
        guard Self.current === self else { return }
        Self.current = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion(rect)
    }
}

/// Borderless windows can't take key presses unless they say so; this one needs Esc.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: (CGRect?) -> Void = { _ in }

    private let hint: String
    private var start: CGPoint?
    private var selection: CGRect?

    init(frame: CGRect, hint: String) {
        self.hint = hint
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        // A click, or a drag too small to mean anything: the whole screen.
        if let selection, selection.width >= 4, selection.height >= 4 {
            onFinish(selection.integral)
        } else {
            onFinish(bounds)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim everything but the selection.
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.append(NSBezierPath(rect: selection)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        guard let selection else {
            drawLabel(hint, centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 80), fontSize: 15)
            return
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        // The size in pixels, as it will be saved.
        let scale = window?.backingScaleFactor ?? 2
        let size = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        let below = selection.minY - 22
        drawLabel(size, centeredAt: CGPoint(x: selection.midX, y: below > 10 ? below : selection.minY + 22), fontSize: 12)
    }

    private func drawLabel(_ text: String, centeredAt center: CGPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: center.x - size.width / 2 - 8, y: center.y - size.height / 2 - 4,
                         width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4))
    }
}
