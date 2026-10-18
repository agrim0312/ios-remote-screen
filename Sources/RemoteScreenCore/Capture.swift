import CoreImage
import Foundation
import ScreenCaptureKit

/// Locates and captures the iPhone Mirroring device window with ScreenCaptureKit.
///
/// REA finding (ScreenContinuityUI `sub_8e110`): the app watches
/// its own device-screen window and calls `ScreenSharingSession.sendWindowRecordingEvent`
/// when the window is captured, so the iPhone is told that its mirror is being recorded.
/// The session is not torn down locally.
public final class MirrorCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public static let bundleIdentifier = "com.apple.ScreenContinuity"

    public struct Options {
        public var fps: Int = 30
        public var jpegQuality: Double = 0.6
        /// Output pixels per window point. 0 means the display's backing scale.
        public var scale: Double = 0
        public init() {}
    }

    public struct Frame {
        public var jpeg: Data
        public var pixelSize: CGSize
        public var windowFrame: CGRect
    }

    let options: Options
    let onFrame: (Frame) -> Void
    let onLog: (String) -> Void

    private let queue = DispatchQueue(label: "ios-remote-screen.capture")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var stream: SCStream?
    private var windowID: CGWindowID?
    private var _windowFrame: CGRect?
    private var _latest: Frame?
    private var configuredSize: CGSize = .zero
    private var watchdog: DispatchSourceTimer?
    private var starting = false

    public init(options: Options, onLog: @escaping (String) -> Void, onFrame: @escaping (Frame) -> Void) {
        self.options = options
        self.onLog = onLog
        self.onFrame = onFrame
    }

    public var windowFrame: CGRect? { lock.withLock { _windowFrame } }
    public var latestFrame: Frame? { lock.withLock { _latest } }
    public var isCapturing: Bool { lock.withLock { stream != nil } }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        watchdog = timer
    }

    /// Runs every second: finds the window when absent, tracks moves/resizes/rotation when present.
    private func tick() {
        if let id = windowID {
            guard let bounds = Self.bounds(of: id) else {
                onLog("iPhone Mirroring window \(id) disappeared; waiting for it to return")
                stopStream()
                return
            }
            lock.withLock { _windowFrame = bounds }
            let size = pixelSize(for: bounds)
            if size != configuredSize, let stream {
                configuredSize = size
                stream.updateConfiguration(configuration(size: size)) { [weak self] error in
                    if let error { self?.onLog("Failed to resize capture: \(error.localizedDescription)") }
                }
            }
        } else if !starting {
            starting = true
            Task { [weak self] in
                await self?.attach()
                self?.queue.async { self?.starting = false }
            }
        }
    }

    private func attach() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            logOnce("Screen capture unavailable: \(error.localizedDescription) (grant Screen Recording permission)")
            return
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Self.bundleIdentifier && $0.windowLayer == 0
                && $0.frame.width >= 100 && $0.frame.height >= 100
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            logOnce("Waiting for the iPhone Mirroring window (is the app open and connected?)")
            return
        }
        logOnce(nil)
        let display = content.displays.first { $0.frame.intersects(window.frame) }
        let backing = display.flatMap { Self.backingScale(displayID: $0.displayID) } ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = pixelSize(for: window.frame, backing: backing)
        let stream = SCStream(filter: filter, configuration: configuration(size: size), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            onLog("Failed to start capture: \(error.localizedDescription)")
            return
        }
        queue.sync {
            self.backingScale = backing
            self.configuredSize = size
            self.windowID = window.windowID
            self.lock.withLock {
                self.stream = stream
                self._windowFrame = window.frame
            }
        }
        onLog("Capturing iPhone Mirroring window \(window.windowID) at \(Int(size.width))x\(Int(size.height))")
    }

    private var backingScale: Double = 2
    private var lastWaitMessage: String?

    /// Logs repeated wait conditions only when they change; nil resets.
    private func logOnce(_ message: String?) {
        queue.async {
            guard message != self.lastWaitMessage else { return }
            self.lastWaitMessage = message
            if let message { self.onLog(message) }
        }
    }

    private func pixelSize(for frame: CGRect, backing: Double? = nil) -> CGSize {
        let s = options.scale > 0 ? options.scale : (backing ?? backingScale)
        return CGSize(width: (frame.width * s).rounded(), height: (frame.height * s).rounded())
    }

    private func configuration(size: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(size.width)
        c.height = Int(size.height)
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(options.fps, 60))))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 3
        c.capturesAudio = false
        return c
    }

    private func stopStream() {
        let s = lock.withLock { () -> SCStream? in
            let s = stream
            stream = nil
            _windowFrame = nil
            return s
        }
        windowID = nil
        configuredSize = .zero
        s?.stopCapture { _ in }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onLog("Capture stopped: \(error.localizedDescription)")
        queue.async { self.stopStream() }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                  of: image, colorSpace: colorSpace,
                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): options.jpegQuality]
              ) else { return }
        let frame = lock.withLock { () -> Frame? in
            guard let wf = _windowFrame else { return nil }
            let f = Frame(jpeg: jpeg, pixelSize: image.extent.size, windowFrame: wf)
            _latest = f
            return f
        }
        if let frame { onFrame(frame) }
    }

    static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first, (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
        return rect
    }

    static func backingScale(displayID: CGDirectDisplayID) -> Double? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return nil }
        return Double(mode.pixelWidth) / Double(mode.width)
    }
}
