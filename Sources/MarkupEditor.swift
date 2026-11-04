import AppKit
import Combine
import CoreImage
import SwiftUI

/// One mark on a screenshot. Points and sizes are in the image's pixels, with the origin at the
/// bottom left, so the marks keep their place however big the window is.
struct Markup {
    enum Tool: String, CaseIterable, Identifiable {
        case arrow, rectangle, ellipse, line, pen, highlighter, text, number, pixelate
        var id: String { rawValue }

        var title: String {
            switch self {
            case .arrow: return "Arrow"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .line: return "Line"
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .text: return "Text"
            case .number: return "Counter"
            case .pixelate: return "Pixelate"
            }
        }

        var systemImage: String {
            switch self {
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .line: return "line.diagonal"
            case .pen: return "scribble"
            case .highlighter: return "highlighter"
            case .text: return "textformat"
            case .number: return "1.circle"
            case .pixelate: return "checkerboard.rectangle"
            }
        }
    }

    enum Shape {
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case line(CGPoint, CGPoint)
        case pen([CGPoint])
        case highlighter([CGPoint])
        /// The text's bottom left corner.
        case text(String, CGPoint)
        case number(Int, CGPoint)
        case pixelate(CGRect)
    }

    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// In screen points; multiplied by the image's pixels per point.
        var lineWidth: CGFloat { [3, 5, 9][index] }
        var fontSize: CGFloat { [16, 24, 36][index] }
        var numberDiameter: CGFloat { [24, 32, 44][index] }
        private var index: Int { Self.allCases.firstIndex(of: self)! }
    }

    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]

    var shape: Shape
    var color: NSColor
    var size: Size

    func draw(in context: CGContext, unit: CGFloat, pixelated: CGImage?, imageSize: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(size.lineWidth * unit)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch shape {
        case .arrow(let from, let to):
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return }
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = min(size.lineWidth * unit * 4, length * 0.6)
            let base = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
            context.move(to: from)
            context.addLine(to: base)
            context.strokePath()
            let spread = CGFloat.pi / 7
            context.move(to: to)
            context.addLine(to: CGPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head))
            context.addLine(to: CGPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head))
            context.closePath()
            context.fillPath()
        case .rectangle(let rect):
            context.stroke(rect)
        case .ellipse(let rect):
            context.strokeEllipse(in: rect)
        case .line(let from, let to):
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        case .pen(let points):
            stroke(points, in: context)
        case .highlighter(let points):
            context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(size.lineWidth * unit * 4)
            context.setLineCap(.square)
            context.setBlendMode(.multiply)
            stroke(points, in: context)
        case .text(let string, let origin):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: string, attributes: Self.textAttributes(color: color, fontSize: size.fontSize * unit))
                .draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
        case .number(let number, let center):
            let diameter = size.numberDiameter * unit
            context.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: diameter * 0.55, weight: .bold),
                .foregroundColor: color == .white || color == .systemYellow ? NSColor.black : NSColor.white,
            ])
            let labelSize = label.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        case .pixelate(let rect):
            guard let pixelated else { return }
            context.clip(to: rect)
            context.interpolationQuality = .none
            context.draw(pixelated, in: CGRect(origin: .zero, size: imageSize))
        }
    }

    private func stroke(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        if points.count == 1 { context.addLine(to: first) }
        points.dropFirst().forEach { context.addLine(to: $0) }
        context.strokePath()
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(color == .black ? 0 : 0.45)
        shadow.shadowBlurRadius = fontSize / 8
        return [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color, .shadow: shadow]
    }
}

/// The screenshot being marked up, its marks, and undo.
@MainActor
final class MarkupDocument: ObservableObject {
    let image: CGImage
    /// The whole image pixelated, shown through the pixelate marks.
    let pixelated: CGImage?
    /// The image's pixels per screen point, so marks look the same size as on the screen.
    let unit: CGFloat
    /// Where the marked-up image is saved: over the capture itself, or as a new file in the
    /// captures folder for an image opened from elsewhere.
    let saveURL: URL

    @Published var tool = Markup.Tool.arrow
    @Published var color = Markup.colors[0]
    @Published var size = Markup.Size.medium
    @Published private(set) var marks: [Markup] = []
    @Published private(set) var redoable: [Markup] = []
    private(set) var isDirty = false

    var size2D: CGSize { CGSize(width: image.width, height: image.height) }
    var nextNumber: Int {
        marks.filter { if case .number = $0.shape { return true } else { return false } }.count + 1
    }

    init(image: CGImage, unit: CGFloat, saveURL: URL) {
        self.image = image
        self.unit = unit
        self.saveURL = saveURL
        // Blurred first so each block is the average of its pixels: the pixelate filter alone takes
        // the color at the block's center, which can be a solid letter.
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 6 * unit])
        let filter = CIFilter(name: "CIPixellate", parameters: [kCIInputImageKey: blurred, kCIInputScaleKey: 12 * unit])
        pixelated = filter?.outputImage.flatMap { CIContext().createCGImage($0, from: input.extent) }
    }

    func add(_ mark: Markup) {
        marks.append(mark)
        redoable = []
        isDirty = true
    }

    func undo() {
        guard let mark = marks.popLast() else { return }
        redoable.append(mark)
        isDirty = true
    }

    func redo() {
        guard let mark = redoable.popLast() else { return }
        marks.append(mark)
        isDirty = true
    }

    /// The image with every mark drawn on it, at full resolution.
    func render() -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size2D))
        marks.forEach { $0.draw(in: context, unit: unit, pixelated: pixelated, imageSize: size2D) }
        return context.makeImage()
    }

    /// Saves the marks into the file, if there are changes; returns the file.
    @discardableResult
    func save() -> URL? {
        guard isDirty || !FileManager.default.fileExists(atPath: saveURL.path) else { return saveURL }
        guard let rendered = render(),
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]),
              (try? png.write(to: saveURL)) != nil else { return nil }
        isDirty = false
        return saveURL
    }
}

/// A window to draw arrows, boxes, text and so on onto a screenshot.
@MainActor
enum MarkupEditor {
    struct Actions {
        var copyText: (CGImage) -> Void
        var upload: (URL) -> Void
        var copied: () -> Void
    }

    private static var windows: [NSWindow] = []

    static func open(_ url: URL, capturesFolder: URL, actions: Actions) {
        guard let nsImage = NSImage(contentsOf: url),
              let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let isCapture = url.deletingLastPathComponent().standardizedFileURL == capturesFolder.standardizedFileURL
        let saveURL = isCapture ? url : capturesFolder
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (marked up)").appendingPathExtension("png")
        try? FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        // Screenshots carry their pixels per point; other images are treated as Retina when big.
        let pointWidth = nsImage.size.width > 0 ? nsImage.size.width : CGFloat(image.width)
        let unit = max(1, (CGFloat(image.width) / pointWidth).rounded())
        let document = MarkupDocument(image: image, unit: unit, saveURL: saveURL)

        let window = MarkupWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.document = document
        let canvas = MarkupCanvas(document: document)
        window.canvas = canvas
        window.contentView = NSHostingView(rootView: MarkupEditorView(document: document, canvas: canvas, actions: actions) {
            window.performClose(nil)
        })

        // As big as the screenshot at 100%, if the screen has room.
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let natural = CGSize(width: CGFloat(image.width) / unit, height: CGFloat(image.height) / unit + 56)
        let fit = min(1, visible.width * 0.9 / natural.width, visible.height * 0.9 / natural.height)
        window.setContentSize(CGSize(width: max(natural.width * fit, 760), height: max(natural.height * fit, 420)))
        window.contentMinSize = CGSize(width: 760, height: 360)
        window.center()
        windows.append(window)
        window.onClose = { windows.removeAll { $0 === window } }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }
}

/// Keeps marks when the window closes, and handles ⌘Z, ⌘C, ⌘S and ⌘W for the editor itself, since
/// MicFlow's menus don't have commands for marks.
private final class MarkupWindow: NSWindow, NSWindowDelegate {
    var document: MarkupDocument?
    weak var canvas: MarkupCanvas?
    var onClose: () -> Void = {}

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        canvas?.commitText()
        MainActor.assumeIsolated { _ = document?.save() }
        onClose()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        // While typing a text mark, the usual text editing shortcuts.
        if firstResponder is NSTextView {
            let selectors: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)),
                                                 "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
                                                 "z": shift ? Selector(("redo:")) : Selector(("undo:"))]
            if let selector = selectors[key] { return NSApp.sendAction(selector, to: nil, from: self) }
        }
        switch key {
        case "z":
            MainActor.assumeIsolated { shift ? document?.redo() : document?.undo() }
        case "w":
            performClose(nil)
        case "c", "s":
            NotificationCenter.default.post(name: key == "c" ? .markupCopy : .markupSave, object: self)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

private extension Notification.Name {
    static let markupCopy = Notification.Name("local.micboost.markup.copy")
    static let markupSave = Notification.Name("local.micboost.markup.save")
}

private struct MarkupEditorView: View {
    @ObservedObject var document: MarkupDocument
    let canvas: MarkupCanvas
    let actions: MarkupEditor.Actions
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(Markup.Tool.allCases) { tool in
                        Button { document.tool = tool } label: {
                            Image(systemName: tool.systemImage).frame(width: 26, height: 24)
                                .background(document.tool == tool ? Color.accentColor.opacity(0.25) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(tool.title)
                    }
                }
                Divider().frame(height: 20)
                HStack(spacing: 4) {
                    ForEach(Markup.colors, id: \.self) { color in
                        Button { document.color = color } label: {
                            Circle().fill(Color(nsColor: color)).frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color.primary.opacity(document.color == color ? 0.9 : 0.2),
                                                         lineWidth: document.color == color ? 2 : 1).padding(-2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Picker("Size", selection: $document.size) {
                    ForEach(Markup.Size.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                Divider().frame(height: 20)
                Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(document.marks.isEmpty).help("Undo (⌘Z)")
                Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(document.redoable.isEmpty).help("Redo (⇧⌘Z)")
                Spacer()
                Button { if let image = document.render() { actions.copyText(image) } } label: {
                    Image(systemName: "text.viewfinder")
                }
                .help("Copy the text in the image (OCR)")
                Button("Copy", action: copy).help("Copy the image (⌘C)")
                Button("Upload") {
                    canvas.commitText()
                    if let url = document.save() { actions.upload(url) }
                }
                .help("Upload to GitHub and copy the link")
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .help("Save and close (⌘W)")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            Divider()
            CanvasHost(canvas: canvas)
        }
        .onReceive(NotificationCenter.default.publisher(for: .markupCopy)) { _ in copy() }
        .onReceive(NotificationCenter.default.publisher(for: .markupSave)) { _ in
            canvas.commitText()
            document.save()
        }
    }

    private func copy() {
        canvas.commitText()
        guard let image = document.render() else { return }
        document.save()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / document.unit,
                                                                             height: CGFloat(image.height) / document.unit))])
        actions.copied()
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: MarkupCanvas
    func makeNSView(context: Context) -> MarkupCanvas { canvas }
    func updateNSView(_ view: MarkupCanvas, context: Context) {}
}

/// Shows the screenshot with its marks, scaled to fit, and turns drags into marks.
final class MarkupCanvas: NSView, NSTextFieldDelegate {
    private let document: MarkupDocument
    private var draft: Markup?
    private var start: CGPoint?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private var observer: AnyCancellable?

    init(document: MarkupDocument) {
        self.document = document
        super.init(frame: .zero)
        observer = document.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the image sits in the view, and how many view points one image pixel takes.
    private var layout: (rect: CGRect, scale: CGFloat) {
        let size = MainActor.assumeIsolated { document.size2D }
        let area = bounds.insetBy(dx: 16, dy: 16)
        let scale = min(area.width / size.width, area.height / size.height, 1 / MainActor.assumeIsolated { document.unit })
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return (CGRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2, width: drawn.width, height: drawn.height), scale)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let (rect, scale) = layout
        let point = convert(event.locationInWindow, from: nil)
        let size = MainActor.assumeIsolated { document.size2D }
        return CGPoint(x: min(max((point.x - rect.minX) / scale, 0), size.width),
                       y: min(max((point.y - rect.minY) / scale, 0), size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black)?.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let (rect, scale) = layout
        MainActor.assumeIsolated {
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: scale, y: scale)
            context.interpolationQuality = .high
            context.draw(document.image, in: CGRect(origin: .zero, size: document.size2D))
            for mark in document.marks + (draft.map { [$0] } ?? []) {
                mark.draw(in: context, unit: document.unit, pixelated: document.pixelated, imageSize: document.size2D)
            }
            context.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let hadText = textField != nil
        commitText()
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        MainActor.assumeIsolated {
            switch document.tool {
            case .text:
                // A click while typing only finishes that text.
                if !hadText { beginText(at: point) }
            case .number:
                document.add(Markup(shape: .number(document.nextNumber, point), color: document.color, size: document.size))
            default:
                start = point
                draft = mark(from: point, to: point)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = imagePoint(event)
        MainActor.assumeIsolated {
            if case .pen(let points) = draft?.shape {
                draft?.shape = .pen(points + [point])
            } else if case .highlighter(let points) = draft?.shape {
                draft?.shape = .highlighter(points + [point])
            } else {
                draft = mark(from: start, to: constrained(point, from: start, shift: event.modifierFlags.contains(.shift)))
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            draft = nil
            needsDisplay = true
        }
        guard let draft, let start else { return }
        let end = imagePoint(event)
        // Ignore a plain click, except with the pen, where it's a dot.
        let moved = hypot(end.x - start.x, end.y - start.y) > 3
        MainActor.assumeIsolated {
            switch draft.shape {
            case .pen, .highlighter: document.add(draft)
            default: if moved { document.add(draft) }
            }
        }
    }

    /// With Shift: lines and arrows at 45° steps, squares and circles.
    private func constrained(_ point: CGPoint, from start: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return point }
        let dx = point.x - start.x, dy = point.y - start.y
        switch MainActor.assumeIsolated({ document.tool }) {
        case .arrow, .line:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .rectangle, .ellipse, .pixelate:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            return point
        }
    }

    @MainActor
    private func mark(from start: CGPoint, to end: CGPoint) -> Markup {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        let shape: Markup.Shape
        switch document.tool {
        case .arrow: shape = .arrow(start, end)
        case .rectangle: shape = .rectangle(rect)
        case .ellipse: shape = .ellipse(rect)
        case .line: shape = .line(start, end)
        case .pen: shape = .pen([start])
        case .highlighter: shape = .highlighter([start])
        case .pixelate: shape = .pixelate(rect)
        case .text, .number: shape = .line(start, end)
        }
        return Markup(shape: shape, color: document.color, size: document.size)
    }

    // MARK: Text

    @MainActor
    private func beginText(at point: CGPoint) {
        let (rect, scale) = layout
        let fontSize = document.size.fontSize * document.unit * scale
        let field = NSTextField(string: "")
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        field.textColor = document.color
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.15)
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Type"
        field.sizeToFit()
        let height = field.frame.height
        field.frame = CGRect(x: rect.minX + point.x * scale - 2, y: rect.minY + point.y * scale - height / 2,
                             width: max(field.frame.width, 60), height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = point
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField else { return }
        let width = field.frame.width
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width + 8, 60, width)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            textField?.stringValue = ""
            commitText()
            return true
        }
        return false
    }

    /// Turns the text being typed into a mark.
    func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        textField = nil
        textOrigin = nil
        let string = field.stringValue
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !string.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        MainActor.assumeIsolated {
            // The field is centered on the click; the mark is drawn from its bottom left corner.
            let fontSize = document.size.fontSize * document.unit
            let height = NSAttributedString(string: string, attributes: Markup.textAttributes(color: document.color, fontSize: fontSize)).size().height
            document.add(Markup(shape: .text(string, CGPoint(x: origin.x, y: origin.y - height / 2)),
                                color: field.textColor ?? document.color, size: document.size))
        }
    }
}
