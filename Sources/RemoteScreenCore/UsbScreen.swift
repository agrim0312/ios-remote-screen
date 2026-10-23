import AVFoundation
import CoreDeviceInput
import CoreImage
import CoreMediaIO
import Foundation

/// Streams a USB-connected iPhone's screen through the public CoreMediaIO screen-capture device, the
/// same path QuickTime uses, and drives it through CoreDevice HID input (`CoreDeviceInput`). Video needs
/// Camera permission on the Mac; input needs Developer Mode on the phone. No Apple Account or app.
///
/// Context from REA: the CoreDevice display service (`dtremotedisplayd`) also streams the screen, but
/// `avconferenced` rejects stream setup from non-Apple clients (`vcMediaStreamSetSessionConfig failed
/// auth`), so this public capture path is the supported video source.
public final class UsbScreenBackend: NSObject, RelayBackend, AVCaptureVideoDataOutputSampleBufferDelegate {
    public struct Options {
        /// Matches a capture device's unique ID or name (case-insensitive substring); nil takes the first.
        public var device: String?
        public var fps: Int = 30
        public var jpegQuality: Double = 0.6
        /// Downscale wider frames to this many pixels; 0 keeps the native size.
        public var maxWidth: Int = 0
        /// usb: CoreMediaIO capture (needs Camera permission). screenshot: Apple's `devicectl` screenshots
        /// (about 1 fps, needs no Mac permission, works from SSH sessions). auto: usb when Camera access is
        /// authorized, otherwise screenshot.
        public var video: String = "auto"
        /// UDID for `devicectl` screenshots.
        public var udid: String?
        /// Screenshot mode: which display to show ("auto" = the active one; foldables have two).
        public var display: String = "auto"
        public init() {}
    }

    let options: Options
    let log: (String) -> Void
    private let queue = DispatchQueue(label: "ios-remote-screen.usb")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var deviceName: String?
    private var _latest: RelayFrame?
    private var lastEncode = Date.distantPast
    private var frameHandler: ((RelayFrame) -> Void)?
    private var timer: DispatchSourceTimer?
    private var lastWait: String?
    private var lastFrameAt = Date()
    let input: CoreDeviceInput?
    private var scrollAccumulator: (x: Double, y: Double, dx: Double, dy: Double)?
    private var scrollFlush: DispatchWorkItem?

    public init(options: Options, input: CoreDeviceInput?, log: @escaping (String) -> Void) {
        self.options = options
        self.input = input
        self.log = log
    }

    public var latestFrame: RelayFrame? { lock.withLock { _latest } }
    public var inputAvailable: Bool { input?.isReady ?? false }

    public var status: [String: Any] {
        lock.withLock {
            [
                "source": "usb",
                "capturing": (session?.isRunning ?? false) || screenshotting,
                "video": screenshotting ? "screenshot" : "usb",
                "device": deviceName as Any? ?? NSNull(),
                "cameraAuthorization": Self.authorizationName(AVCaptureDevice.authorizationStatus(for: .video)),
                "coreDevice": input?.deviceID.uuidString as Any? ?? NSNull(),
                "displayMode": requestedDisplay ?? options.display,
                "shownDisplay": shownDisplay?.uniqueID as Any? ?? NSNull(),
                "displays": knownDisplays.map {
                    ["id": $0.id, "uniqueID": $0.uniqueID, "active": $0.active, "primary": $0.primary, "rotation": $0.rotation] as [String: Any]
                },
            ]
        }
    }

    static func authorizationName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    public func start(onFrame: @escaping (RelayFrame) -> Void) {
        frameHandler = onFrame
        input?.connect()
        Self.allowScreenCaptureDevices()
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.log("Camera access \(granted ? "granted" : "denied")")
            }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let d = note.object as? AVCaptureDevice else { return }
            self.queue.async {
                if d.localizedName == self.lock.withLock({ self.deviceName }) {
                    self.log("Capture device \(d.localizedName) disconnected")
                    self.stopSession()
                }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// iOS screens only appear as capture devices after this system property is set.
    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private func waiting(_ message: String) {
        guard message != lastWait else { return }
        lastWait = message
        log(message)
    }

    private var screenshotting = false
    // Mid-session display switching (foldables): what the viewer asked for, what is shown, and the list.
    private var requestedDisplay: String?
    private var displayDirty = false
    private var knownDisplays: [CoreDeviceLookup.Display] = []
    private var shownDisplay: CoreDeviceLookup.Display?

    private var useScreenshots: Bool {
        options.video == "screenshot" || (options.video == "auto" && AVCaptureDevice.authorizationStatus(for: .video) != .authorized)
    }

    private func tick() {
        if let input, !input.isReady { input.connect() }
        if useScreenshots {
            if !screenshotting { startScreenshots() }
            return
        }
        if lock.withLock({ session?.isRunning ?? false }) {
            // A phone restart leaves the capture session "running" without frames; start over.
            if Date().timeIntervalSince(lastFrameAt) > 20 {
                log("No USB frames for 20s; restarting capture")
                stopSession()
            }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return waiting("Waiting for Camera permission (System Settings > Privacy & Security > Camera)")
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
        let match = devices.first { d in
            guard let q = options.device?.lowercased(), !q.isEmpty else { return true }
            return d.uniqueID.lowercased().contains(q) || d.localizedName.lowercased().contains(q)
        }
        guard let device = match else {
            return waiting("Waiting for a USB iPhone screen device (\(devices.count) present; plug in and trust this Mac)")
        }
        lastWait = nil
        do {
            let session = AVCaptureSession()
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw RelayError("cannot add capture input") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw RelayError("cannot add video output") }
            session.addOutput(output)
            session.commitConfiguration()
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.log("USB capture runtime error: \(error?.localizedDescription ?? "unknown")")
                self?.queue.async { self?.stopSession() }
            }
            session.startRunning()
            log("Format: \(device.activeFormat.formatDescription.dimensions.width)x\(device.activeFormat.formatDescription.dimensions.height), running: \(session.isRunning)")
            lock.withLock {
                self.session = session
                self.deviceName = device.localizedName
            }
            lastFrameAt = Date()
            log("Capturing \(device.localizedName) (\(device.uniqueID)) over USB")
        } catch {
            waiting("Failed to start USB capture for \(device.localizedName): \(error.localizedDescription)")
        }
    }

    private func stopSession() {
        let s = lock.withLock { () -> AVCaptureSession? in
            let s = session
            session = nil
            deviceName = nil
            return s
        }
        s?.stopRunning()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastEncode) >= 1.0 / Double(max(1, options.fps)),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastEncode = now
        lastFrameAt = now
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if options.maxWidth > 0, image.extent.width > CGFloat(options.maxWidth) {
            let s = CGFloat(options.maxWidth) / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                  of: image, colorSpace: colorSpace,
                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): options.jpegQuality]
              ) else { return }
        let frame = RelayFrame(jpeg: jpeg, pixelSize: image.extent.size)
        lock.withLock { _latest = frame }
        frameHandler?(frame)
    }

    /// Polls Apple's `devicectl device capture screenshot`; slow, but needs no Mac privacy permission.
    private func startScreenshots() {
        guard let udid = options.udid else {
            return waiting("Screenshot video needs the device UDID (--device)")
        }
        screenshotting = true
        log("Using devicectl screenshots for video (Camera access not authorized for USB capture)")
        lock.withLock { deviceName = udid }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ios-remote-screen-shot-\(getpid()).png").path
        Thread.detachNewThread { [weak self] in
            var display: CoreDeviceLookup.Display?
            var lastDisplayCheck = Date.distantPast
            while let self {
                // Re-check displays every 10 s (folding switches the active one in auto mode), or right
                // away when a viewer picks a different display.
                let (dirty, requested) = self.lock.withLock { () -> (Bool, String) in
                    let d = self.displayDirty
                    self.displayDirty = false
                    return (d, self.requestedDisplay ?? self.options.display)
                }
                if dirty || Date().timeIntervalSince(lastDisplayCheck) > 10 {
                    lastDisplayCheck = Date()
                    let all = CoreDeviceLookup.displays(udid: udid)
                    let picked = CoreDeviceLookup.pick(from: all, requested: requested)
                    if let picked, picked.uniqueID != display?.uniqueID || picked.rotation != display?.rotation {
                        self.log("Showing display \(picked.id) (\(picked.uniqueID), rotation \(picked.rotation))")
                        self.input?.setDisplay(id: picked.primary ? 0 : picked.id, rotation: picked.rotation)
                    }
                    display = picked ?? display
                    self.lock.withLock {
                        if !all.isEmpty { self.knownDisplays = all }
                        self.shownDisplay = display
                    }
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                var args = ["devicectl", "device", "capture", "screenshot", "--device", udid, "--destination", path, "--quiet"]
                if let display { args += ["--display-unique-id", display.uniqueID] }
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { self.log("devicectl failed: \(error)"); Thread.sleep(forTimeInterval: 2); continue }
                p.waitUntilExit()
                guard p.terminationStatus == 0, var image = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                if self.options.maxWidth > 0, image.extent.width > CGFloat(self.options.maxWidth) {
                    let s = CGFloat(self.options.maxWidth) / image.extent.width
                    image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
                }
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let jpeg = self.ciContext.jpegRepresentation(
                          of: image, colorSpace: colorSpace,
                          options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): self.options.jpegQuality]
                      ) else { continue }
                let frame = RelayFrame(jpeg: jpeg, pixelSize: image.extent.size)
                self.lock.withLock { self._latest = frame }
                self.frameHandler?(frame)
            }
        }
    }

    public func handle(_ message: ControlMessage) {
        guard let input else { return }
        switch message {
        case let .pointer(phase, x, y):
            input.touch(phase == .down ? .start : phase == .move ? .move : .end, x: x, y: y)
        case let .scroll(x, y, dx, dy):
            // Wheel/trackpad deltas become one finger swipe per burst of scroll events.
            queue.async {
                var acc = self.scrollAccumulator ?? (x, y, 0, 0)
                acc.dx += dx
                acc.dy += dy
                self.scrollAccumulator = acc
                self.scrollFlush?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.flushScroll() }
                self.scrollFlush = work
                self.queue.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        case let .text(s):
            input.type(s)
        case let .key(code, modifiers):
            guard let usage = HIDKeyboard.usage(forCode: code) else { return log("No HID usage for key \(code)") }
            var mods: [Int] = []
            if modifiers.contains(.command) { mods.append(HIDKeyboard.leftCommand) }
            if modifiers.contains(.shift) { mods.append(HIDKeyboard.leftShift) }
            if modifiers.contains(.option) { mods.append(HIDKeyboard.leftOption) }
            if modifiers.contains(.control) { mods.append(HIDKeyboard.leftControl) }
            input.press(page: 0x07, usage: usage, modifiers: mods)
        case let .display(d):
            lock.withLock {
                requestedDisplay = d
                displayDirty = true
            }
            log("Viewer selected display \(d)")
        case let .action(action):
            switch action {
            case .home: input.pressHome()
            case .appSwitcher:
                input.swipe(from: CGPoint(x: 0.5, y: 0.995), to: CGPoint(x: 0.5, y: 0.6), duration: 0.35, hold: 0.45, edge: .bottom)
            case .spotlight:
                input.swipe(from: CGPoint(x: 0.5, y: 0.3), to: CGPoint(x: 0.5, y: 0.6), duration: 0.2)
            }
        }
    }

    private func flushScroll() {
        guard let acc = scrollAccumulator, let input else { return }
        scrollAccumulator = nil
        // Content follows the finger, so the finger moves opposite to the wheel delta.
        let scale = 1.0 / 900
        let to = CGPoint(x: acc.x - acc.dx * scale, y: acc.y - acc.dy * scale)
        input.swipe(from: CGPoint(x: acc.x, y: acc.y), to: to, duration: 0.12)
    }

    public func releaseAll() {}
}

struct RelayError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
