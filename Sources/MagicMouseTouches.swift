import AppKit
import os

/// MultitouchSupport's per-finger record is 96 bytes; we read the touch state and the
/// normalized position (0...1, left to right / bottom to top).
private let fingerStride = 96
private let fingerStateOffset = 20
private let fingerXOffset = 32
private let fingerYOffset = 36
/// States 3...5 are "making contact", "touching" and "breaking contact".
private let touchingStates: ClosedRange<Int32> = 3...5
/// MultitouchSupport family IDs for the Magic Mouse.
private let magicMouseFamilies: Set<Int32> = [112, 113]

enum SwipeDirection: String {
    case left, right
}

extension Notification.Name {
    /// Posted on the main queue with the `SwipeDirection` as the object.
    static let magicMouseSwipe = Notification.Name("magicMouseSwipe")
}

/// Recognizes a one-finger sideways swipe: the finger lands, moves at least a quarter of the
/// mouse's width, mostly sideways, within 0.6 seconds, and lifts. A second finger at any point
/// cancels it, so two-finger moves never count.
private struct SwipeTracker {
    private var start: (x: Float, y: Float, time: Double)?
    private var last: (x: Float, y: Float) = (0, 0)
    private var moreThanOneFinger = false

    mutating func update(_ touches: [(x: Float, y: Float)], time: Double) -> SwipeDirection? {
        guard let first = touches.first else {
            defer { (start, moreThanOneFinger) = (nil, false) }
            guard let start, !moreThanOneFinger else { return nil }
            let dx = last.x - start.x, dy = last.y - start.y
            guard time - start.time < 0.6, abs(dx) > 0.25, abs(dy) < abs(dx) * 0.6 else { return nil }
            return dx < 0 ? .left : .right
        }
        if touches.count > 1 { moreThanOneFinger = true }
        if start == nil { start = (first.x, first.y, time) }
        last = first
        return nil
    }
}

/// X positions of the fingers currently on a Magic Mouse, written by the multitouch thread.
private let touchPositions = OSAllocatedUnfairLock<[Float]>(initialState: [])
private let swipeTracker = OSAllocatedUnfairLock(initialState: SwipeTracker())

private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private let contactCallback: ContactCallback = { _, data, count, timestamp, _ in
    var touches: [(x: Float, y: Float)] = []
    if let data {
        for i in 0..<Int(count) {
            let finger = data.advanced(by: i * fingerStride)
            if touchingStates.contains(finger.load(fromByteOffset: fingerStateOffset, as: Int32.self)) {
                touches.append((finger.load(fromByteOffset: fingerXOffset, as: Float.self),
                                finger.load(fromByteOffset: fingerYOffset, as: Float.self)))
            }
        }
    }
    let xs = touches.map(\.x)
    touchPositions.withLock { $0 = xs }
    let current = touches
    if let swipe = swipeTracker.withLock({ $0.update(current, time: timestamp) }) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .magicMouseSwipe, object: swipe) }
    }
    return 0
}

/// Finger positions on the Magic Mouse's touch surface, from Apple's private MultitouchSupport
/// framework (the same one tools like BetterTouchTool use). It's loaded at runtime, so if a future
/// macOS changes it the app reports "no Magic Mouse found" instead of crashing.
///
/// Shared by every feature that reads touches; it listens while at least one of them is using it.
final class MagicMouseTouchMonitor {
    static let shared = MagicMouseTouchMonitor()

    private struct API {
        let createList: @convention(c) () -> Unmanaged<CFArray>
        let familyID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
        let deviceID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
        let register: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
        let unregister: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
        let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
        let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32

        init?() {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
            func load<T>(_ name: String) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
            guard let createList: @convention(c) () -> Unmanaged<CFArray> = load("MTDeviceCreateList"),
                  let familyID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32 = load("MTDeviceGetFamilyID"),
                  let deviceID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32 = load("MTDeviceGetDeviceID"),
                  let register: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void = load("MTRegisterContactFrameCallback"),
                  let unregister: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void = load("MTUnregisterContactFrameCallback"),
                  let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32 = load("MTDeviceStart"),
                  let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32 = load("MTDeviceStop") else { return nil }
            (self.createList, self.familyID, self.deviceID) = (createList, familyID, deviceID)
            (self.register, self.unregister, self.start, self.stop) = (register, unregister, start, stop)
        }
    }

    private let api = API()
    /// Keeps the device objects alive while we're registered with them.
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var deviceIDs: [UInt64] = []
    private var users = 0

    private init() {}

    var isTracking: Bool { !devices.isEmpty }
    var touches: [Float] { touchPositions.withLock { $0 } }

    func addUser() {
        users += 1
        refresh()
    }

    func removeUser() {
        users = max(users - 1, 0)
        if users == 0 { stop() }
    }

    /// Starts listening to every connected Magic Mouse. Cheap when nothing changed; `force`
    /// re-registers anyway, which is needed after the Mac wakes from sleep.
    func refresh(force: Bool = false) {
        guard let api, users > 0 else { return }
        let list = api.createList().takeRetainedValue()
        let mice = (list as [AnyObject]).map { Unmanaged.passUnretained($0).toOpaque() }.filter { device in
            var family: Int32 = 0
            _ = api.familyID(device, &family)
            return magicMouseFamilies.contains(family)
        }
        let ids = mice.map { device -> UInt64 in
            var id: UInt64 = 0
            _ = api.deviceID(device, &id)
            return id
        }
        guard force || ids != deviceIDs else { return }
        stop()
        for device in mice {
            api.register(device, contactCallback)
            _ = api.start(device, 0)
        }
        (deviceList, devices, deviceIDs) = (list, mice, ids)
    }

    private func stop() {
        if let api {
            for device in devices {
                api.unregister(device, contactCallback)
                _ = api.stop(device)
            }
        }
        (deviceList, devices, deviceIDs) = (nil, [], [])
        touchPositions.withLock { $0 = [] }
    }
}
