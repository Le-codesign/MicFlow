import CoreGraphics
import Foundation

/// A session-wide event tap on the main run loop whose handler can change events in place, or
/// return false to drop them. A listen-only tap just watches: events never wait for the handler
/// (so typing can't lag), and what it returns is ignored. Creating one needs Accessibility permission.
final class EventTap {
    private let types: [CGEventType]
    private let listenOnly: Bool
    private let handler: (CGEventType, CGEvent) -> Bool
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isInstalled: Bool { port != nil }

    init(types: [CGEventType], listenOnly: Bool = false, handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.types = types
        self.listenOnly = listenOnly
        self.handler = handler
    }

    deinit { remove() }

    /// Returns false when macOS refuses the tap, usually because Accessibility isn't granted.
    @discardableResult
    func install() -> Bool {
        guard port == nil else { return true }
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        (self.port, self.source) = (port, source)
        return true
    }

    func remove() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            // Otherwise the disabled tap lingers until the process exits.
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        (port, source) = (nil, nil)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a slow tap off; switch it straight back on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        default:
            if !handler(type, event) { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
}
