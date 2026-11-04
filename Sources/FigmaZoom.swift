import AppKit
import ApplicationServices

/// Makes swiping up and down on the mouse zoom the Figma canvas, by adding Control to vertical
/// scrolls while Figma is the frontmost app. Figma's own "Use scroll wheel zoom" only applies to
/// notched scroll wheels; the Magic Mouse scrolls smoothly like a trackpad, which Figma pans with.
/// Sideways swipes are left alone, so they still move the canvas left and right. `zoomAmount`
/// scales each zoom swipe.
final class FigmaZoomController {
    enum State: Equatable {
        case off, needsAccessibility, running
    }

    static let figmaBundleIDs: Set<String> = ["com.figma.Desktop"]

    /// Multiplier on how far each swipe zooms, 1 = Figma's normal.
    var zoomAmount: Double = 1
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    private lazy var tap = EventTap(types: [.scrollWheel]) { [unowned self] _, event in
        self.handle(event)
        return true
    }
    private var figmaIsFrontmost = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        updateFrontmostApp(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.updateFrontmostApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        // Re-checks until Accessibility permission is granted.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        tap.remove()
        setState(.off)
    }

    private func update() {
        guard AXIsProcessTrusted(), tap.install() else {
            tap.remove()
            setState(.needsAccessibility)
            return
        }
        setState(.running)
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    /// True while swipes are being turned into zoom, so other scroll features can stay out of the way.
    var isZoomingFrontmostApp: Bool { state == .running && figmaIsFrontmost }

    private func updateFrontmostApp(_ app: NSRunningApplication?) {
        figmaIsFrontmost = app?.bundleIdentifier.map(Self.figmaBundleIDs.contains) ?? false
    }

    private func handle(_ event: CGEvent) {
        guard figmaIsFrontmost else { return }
        let vertical = abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let horizontal = abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        guard vertical >= horizontal else { return }
        event.flags.insert(.maskControl)
        if zoomAmount != 1 { event.scaleScrollDeltas(by: zoomAmount) }
    }
}
