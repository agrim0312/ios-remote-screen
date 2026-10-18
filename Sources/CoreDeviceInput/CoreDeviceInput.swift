@_implementationOnly import CoreDevice
import CoreGraphics
import Foundation

/// Touch, button and keyboard input for a USB/CoreDevice-connected iPhone, with no app on the phone.
///
/// REA findings this relies on:
/// - The iOS Developer Disk Image (Xcode 27) ships `dtuhidd`, which serves
///   `com.apple.coredevice.hid.indigo` (digitizer, button, scroll) and `.universalhid` (keyboard).
/// - Xcode's CoreDevice.framework exposes them as the `HIDDigitizer` / `HIDButton` capabilities
///   (`CapabilityStaticMember.hid.digitizer` / `.hid.button`), reached via
///   `RemoteDevice.getImplementation(for:)`. Points are normalized 0...1 in portrait orientation.
/// - Capabilities are only offered while the CoreDevice tunnel is up, so a usage assertion requiring
///   Developer Disk Image services is held for the life of the session.
///
/// The phone must have Developer Mode on. Unlike the CoreDevice video stream (which `avconferenced`
/// refuses for non-Apple clients), these input capabilities accept calls from this process.
public final class CoreDeviceInput {
    public enum Phase { case start, move, end }
    /// Screen edge a gesture starts from (system gestures such as the app switcher need it).
    public enum Edge { case none, bottom, top, left, right }

    static func digitizerEdge(_ e: Edge) -> DigitizerEdge {
        switch e {
        case .none: return .none
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .left
        case .right: return .right
        }
    }

    public let deviceID: UUID
    let log: (String) -> Void
    private let queue = DispatchQueue(label: "ios-remote-screen.coredevice-input")
    // Stored as Any so no CoreDevice type appears in this module's interface.
    private var digitizerBox: Any?
    private var buttonBox: Any?
    private var assertion: AnyObject?
    private var digitizer: (any HIDDigitizer)? {
        get { digitizerBox as? any HIDDigitizer }
        set { digitizerBox = newValue }
    }
    private var button: (any HIDButton)? {
        get { buttonBox as? any HIDButton }
        set { buttonBox = newValue }
    }
    private var connecting = false
    private var lastPoint = CGPoint(x: 0.5, y: 0.5)

    public init(deviceID: UUID, log: @escaping (String) -> Void) {
        self.deviceID = deviceID
        self.log = log
    }

    public var isReady: Bool { queue.sync { digitizer != nil && button != nil } }

    /// Connects in the background; safe to call repeatedly (e.g. after a disconnect).
    public func connect() {
        let shouldStart = queue.sync { () -> Bool in
            if connecting || digitizer != nil { return false }
            connecting = true
            return true
        }
        guard shouldStart else { return }
        Task {
            defer { queue.sync { connecting = false } }
            do {
                let manager = DeviceManager.shared
                await manager.awaitFullInitialization()
                guard let device = manager.devices[deviceID] else {
                    log("CoreDevice: device \(deviceID) not found (is it paired with this Mac?)")
                    return
                }
                let assertion = try await device.acquireDeviceUsageAssertion(
                    withReason: "ios-remote-screen remote input",
                    options: UsageAssertionOptions(requiredPreparedness: .developerDiskImageServicesEnabled))
                let digitizer = try await Self.implementation(manager, deviceID, fallback: device, .hid.digitizer)
                let button = try await Self.implementation(manager, deviceID, fallback: device, .hid.button)
                queue.sync {
                    self.assertion = assertion
                    self.digitizer = digitizer
                    self.button = button
                }
                log("CoreDevice input ready (touch, buttons, keyboard)")
            } catch {
                log("CoreDevice input unavailable: \(error) (Developer Mode on, phone unlocked?)")
            }
        }
    }

    static func implementation<A: DeviceCapability>(_ manager: DeviceManager, _ id: UUID, fallback: RemoteDevice,
                                                    _ member: CapabilityStaticMember<A>) async throws -> A.ProtocolType {
        var lastError: Error?
        for _ in 0..<20 {
            do { return try await (manager.devices[id] ?? fallback).getImplementation(for: member) } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError!
    }

    private func failed(_ error: Error) {
        log("CoreDevice input error: \(error); reconnecting")
        digitizer = nil
        button = nil
        assertion = nil
        DispatchQueue.global().async { self.connect() }
    }

    /// One finger. Each start must be followed by an end.
    public func touch(_ phase: Phase, x: Double, y: Double, edge: Edge = .none) {
        queue.async {
            guard let digitizer = self.digitizer else { return }
            let p = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            self.lastPoint = p
            let type: DigitizerEventType = phase == .start ? .start : phase == .move ? .position : .end
            do {
                try digitizer.send(pointOne: p, pointTwo: nil, eventType: type, edge: Self.digitizerEdge(edge), target: .mainScreen)
                if phase == .end { digitizer.sendBarrier() }
            } catch { self.failed(error) }
        }
    }

    /// A straight drag sampled at about 60 Hz, then a hold before lifting.
    public func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval, hold: TimeInterval = 0, edge: Edge = .none) {
        let steps = max(2, Int(duration * 60))
        touch(.start, x: from.x, y: from.y, edge: edge)
        queue.async {
            for i in 1...steps {
                Thread.sleep(forTimeInterval: duration / Double(steps))
                let t = Double(i) / Double(steps)
                guard let d = self.digitizer else { return }
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                try? d.send(pointOne: p, pointTwo: nil, eventType: .position, edge: Self.digitizerEdge(edge), target: .mainScreen)
            }
            if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        }
        touch(.end, x: to.x, y: to.y, edge: edge)
    }

    /// Presses and releases one HID usage, e.g. (0x0C, 0x40) for Home or (0x07, 0x04) for "a".
    public func press(page: Int, usage: Int, modifiers: [Int] = []) {
        queue.async {
            guard let button = self.button else { return }
            do {
                for m in modifiers { try button.sendCustomButton(usagePage: 0x07, usageCode: m, state: .down) }
                try button.sendCustomButton(usagePage: page, usageCode: usage, state: .down)
                Thread.sleep(forTimeInterval: 0.02)
                try button.sendCustomButton(usagePage: page, usageCode: usage, state: .up)
                for m in modifiers.reversed() { try button.sendCustomButton(usagePage: 0x07, usageCode: m, state: .up) }
                button.sendBarrier()
            } catch { self.failed(error) }
        }
    }

    public func pressHome() { press(page: 0x0C, usage: 0x40) }

    /// Types ASCII text as HID keyboard key presses; other characters are skipped and reported.
    public func type(_ text: String) {
        var skipped = 0
        for ch in text {
            guard let (usage, shift) = HIDKeyboard.usage(for: ch) else { skipped += 1; continue }
            press(page: 0x07, usage: usage, modifiers: shift ? [HIDKeyboard.leftShift] : [])
        }
        if skipped > 0 { log("Skipped \(skipped) character(s) that have no US keyboard key") }
    }
}

/// US-layout HID keyboard usages (usage page 0x07).
public enum HIDKeyboard {
    public static let leftControl = 0xE0, leftShift = 0xE1, leftOption = 0xE2, leftCommand = 0xE3

    static let unshifted: [Character: Int] = {
        var m: [Character: Int] = [
            "\n": 0x28, "\r": 0x28, "\t": 0x2B, " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30,
            "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38, "0": 0x27,
        ]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[c] = 0x04 + i }
        for (i, c) in "123456789".enumerated() { m[c] = 0x1E + i }
        return m
    }()

    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/",
    ]

    public static func usage(for ch: Character) -> (Int, Bool)? {
        if let u = unshifted[ch] { return (u, false) }
        if ch.isUppercase, let u = unshifted[Character(ch.lowercased())] { return (u, true) }
        if let base = shifted[ch], let u = unshifted[base] { return (u, true) }
        return nil
    }

    /// DOM `KeyboardEvent.code` values for non-text keys.
    public static let codes: [String: Int] = [
        "Enter": 0x28, "NumpadEnter": 0x58, "Escape": 0x29, "Backspace": 0x2A, "Tab": 0x2B, "Space": 0x2C,
        "Delete": 0x4C, "ArrowRight": 0x4F, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52,
        "Home": 0x4A, "End": 0x4D, "PageUp": 0x4B, "PageDown": 0x4E,
    ]

    /// Usage for a DOM code such as "KeyA", "Digit1" or "Enter".
    public static func usage(forCode code: String) -> Int? {
        if let u = codes[code] { return u }
        if code.hasPrefix("Key"), code.count == 4, let c = code.last?.lowercased().first { return unshifted[c] }
        if code.hasPrefix("Digit"), code.count == 6, let c = code.last { return unshifted[c] }
        return nil
    }
}

/// Finds the CoreDevice identifier for a device by name, UDID or identifier, using `devicectl`.
public enum CoreDeviceLookup {
    public struct Device { public var identifier: UUID; public var name: String; public var udid: String }

    public static func physicalDevices() -> [Device] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ios-remote-screen-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["devicectl", "list", "devices", "--quiet", "--json-output", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        guard let data = try? Data(contentsOf: out),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (obj["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { d in
            guard let id = (d["identifier"] as? String).flatMap(UUID.init(uuidString:)),
                  let hw = d["hardwareProperties"] as? [String: Any], (hw["reality"] as? String) == "physical" else { return nil }
            let name = (d["deviceProperties"] as? [String: Any])?["name"] as? String ?? ""
            return Device(identifier: id, name: name, udid: hw["udid"] as? String ?? "")
        }
    }

    /// Matches `query` against identifier, UDID or name (case-insensitive substring); nil picks the only device.
    public static func find(_ query: String?) -> Device? {
        let all = physicalDevices()
        guard let q = query?.lowercased(), !q.isEmpty else { return all.count == 1 ? all[0] : nil }
        return all.first { $0.identifier.uuidString.lowercased() == q || $0.udid.lowercased() == q || $0.name.lowercased().contains(q) }
    }
}
