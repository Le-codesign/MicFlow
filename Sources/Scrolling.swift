import AppKit
import ApplicationServices

extension CGEvent {
    /// Multiplies a scroll event's distance on both axes, in every unit apps may read.
    ///
    /// Writing the line delta makes macOS recompute the fixed and pixel deltas from it, in steps of
    /// whole lines. So smooth (continuous) scrolls keep their line delta as it is, or tiny moves at
    /// the end of a swipe would turn into line-sized jumps; wheel scrolls set it first and then
    /// overwrite the finer values.
    func scaleScrollDeltas(by factor: Double) {
        let continuous = getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let axes: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventDeltaAxis1),
            (.scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventDeltaAxis2),
        ]
        for (fixed, point, line) in axes {
            let scaledFixed = getDoubleValueField(fixed) * factor
            let scaledPoint = Int64((Double(getIntegerValueField(point)) * factor).rounded())
            if !continuous {
                setIntegerValueField(line, value: Int64((Double(getIntegerValueField(line)) * factor).rounded()))
            }
            setDoubleValueField(fixed, value: scaledFixed)
            setIntegerValueField(point, value: scaledPoint)
        }
    }
}

/// Scroll distance and smooth scrolling, in every app.
/// - Distance multiplies how far each swipe scrolls.
/// - Smooth scrolling holds back each vertical scroll and replays its distance as a stream of small
///   scroll events, 120 times a second, each covering a share of what's left, so the page eases
///   into place instead of jumping. Sideways scrolls (and so swiping between pages) aren't smoothed.
/// Scrolls with a modifier key held are left alone.
final class ScrollController {
    enum State: Equatable {
        case off, needsAccessibility, running
    }

    /// Multiplier on scroll distance, 1 = macOS normal.
    var distance: Double = 1
    var smoothEnabled = false { didSet { if !smoothEnabled { stopTicker() } } }
    /// 0 = light smoothing, 1 = very smooth (slow, floaty easing).
    var smoothness: Double = 0.5
    /// Checked for every scroll; true leaves it alone (used while Figma Zoom turns swipes into zoom).
    var shouldSkip: () -> Bool = { false }
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    /// Tags the events we post so our own tap lets them through.
    private static let marker: Int64 = 0x4D42_5343
    private static let tickRate = 120.0

    private lazy var tap = EventTap(types: [.scrollWheel]) { [unowned self] _, event in
        self.handle(event)
    }
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pending = CGVector.zero
    private var carry = CGVector.zero
    private var ticker: Timer?
    private var permissionTimer: Timer?

    func start() {
        guard permissionTimer == nil else { return }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        // Re-checks until Accessibility permission is granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        tap.remove()
        stopTicker()
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

    /// Returns false to drop the original event once its distance is queued for smoothing.
    private func handle(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return true }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard event.flags.intersection(modifiers).isEmpty, !shouldSkip() else { return true }
        let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        guard smoothEnabled, abs(dy) >= abs(dx), dy != 0 else {
            if distance != 1 { event.scaleScrollDeltas(by: distance) }
            return true
        }
        pending.dy += dy * distance
        pending.dx += dx * distance
        startTicker()
        return false
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let ticker = Timer(timeInterval: 1 / Self.tickRate, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        pending = .zero
        carry = .zero
    }

    private func tick() {
        // Share of the remaining distance covered each tick: half at "light", 8% at "very smooth".
        let share = 0.5 - 0.42 * min(max(smoothness, 0), 1)
        var step = CGVector(dx: pending.dx * share, dy: pending.dy * share)
        if abs(pending.dx) < 1 { step.dx = pending.dx }
        if abs(pending.dy) < 1 { step.dy = pending.dy }
        pending.dx -= step.dx
        pending.dy -= step.dy

        // Scroll events carry whole pixels; keep the fractions for the next tick.
        carry.dx += step.dx
        carry.dy += step.dy
        let pixels = (x: Int32(carry.dx.rounded(.towardZero)), y: Int32(carry.dy.rounded(.towardZero)))
        carry.dx -= Double(pixels.x)
        carry.dy -= Double(pixels.y)

        if pixels.x != 0 || pixels.y != 0,
           let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: pixels.y, wheel2: pixels.x, wheel3: 0) {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cgSessionEventTap)
        }
        if pending.dx == 0, pending.dy == 0, abs(carry.dx) < 1, abs(carry.dy) < 1 {
            stopTicker()
        }
    }
}
