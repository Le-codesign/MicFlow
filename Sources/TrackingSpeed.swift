import AppKit
import IOKit.hid

/// Tracking speed through `HIDMouseAcceleration`, the value System Settings › Mouse › Tracking
/// speed writes (its slider stops at 3, "Fast"). This one starts at Fast and continues on macOS's
/// own curve, so the cursor moves the same native way, just quicker.
///
/// It's set system-wide, the way System Settings does it: the Magic Mouse ignores the per-mouse
/// value. Mice that do keep their own value (USB mice) get it too. macOS may put its own value
/// back (after login, or when System Settings changes it), so it's checked and re-applied.
final class TrackingSpeedController {
    enum State: Equatable {
        case off, noMouse, running
    }

    /// macOS's "Fast", the top of its own slider.
    static let macOSFast = 3.0
    static let maximum = 9.0

    var speed = macOSFast { didSet { apply() } }
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var appliedServices: [UInt64] = []

    /// What System Settings › Mouse › Tracking speed is set to.
    static var systemSpeed: Double {
        UserDefaults(suiteName: ".GlobalPreferences")?.object(forKey: "com.apple.mouse.scaling") as? Double ?? 0.6875
    }

    func start() {
        guard timer == nil else { return }
        // Re-apply when the set of mice changes or macOS has put its own system-wide value back.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let systemValue = (IOHIDEventSystemClientCopyProperty(self.client, Self.key) as? NSNumber)?.intValue
            guard self.registryIDs(self.mice()) != self.appliedServices || systemValue != Self.fixed(self.speed) else { return }
            self.apply()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.apply() }
        apply()
    }

    /// Puts every mouse back to the System Settings tracking speed.
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        set(Self.systemSpeed, on: mice())
        appliedServices = []
        setState(.off)
    }

    private func apply() {
        guard timer != nil else { return }
        let services = mice()
        appliedServices = registryIDs(services)
        set(speed, on: services)
        setState(services.isEmpty ? .noMouse : .running)
    }

    private static let key = "HIDMouseAcceleration" as CFString

    private static func fixed(_ speed: Double) -> Int { Int(speed * 65536) }

    private func set(_ speed: Double, on services: [IOHIDServiceClient]) {
        let value = NSNumber(value: Self.fixed(speed))
        IOHIDEventSystemClientSetProperty(client, Self.key, value)
        for service in services {
            IOHIDServiceClientSetProperty(service, Self.key, value)
        }
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    private func mice() -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []).filter {
            IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
        }
    }

    private func registryIDs(_ services: [IOHIDServiceClient]) -> [UInt64] {
        services.compactMap { (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value }
    }
}
