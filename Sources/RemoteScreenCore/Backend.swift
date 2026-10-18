import CoreGraphics
import Foundation

/// One encoded video frame for viewers.
public struct RelayFrame {
    public var jpeg: Data
    public var pixelSize: CGSize
}

/// A screen source plus the input path for the same device.
public protocol RelayBackend: AnyObject {
    var latestFrame: RelayFrame? { get }
    /// Extra fields for /status and the viewer's status line.
    var status: [String: Any] { get }
    /// Whether viewer input can currently reach the device.
    var inputAvailable: Bool { get }
    func start(onFrame: @escaping (RelayFrame) -> Void)
    func handle(_ message: ControlMessage)
    /// Releases held touches or buttons, e.g. when a viewer disconnects mid-drag.
    func releaseAll()
}

/// The macOS iPhone Mirroring window: ScreenCaptureKit capture plus synthesized Mac input.
public final class MirroringBackend: RelayBackend {
    private var capture: MirrorCapture!
    let input: InputInjector
    private let inputQueue = DispatchQueue(label: "ios-remote-screen.input")
    private var frameHandler: ((RelayFrame) -> Void)?

    public init(captureOptions: MirrorCapture.Options, inputMode: InputInjector.Mode, log: @escaping (String) -> Void) {
        input = InputInjector(mode: inputMode, onLog: log)
        capture = MirrorCapture(options: captureOptions, onLog: log) { [weak self] frame in
            self?.frameHandler?(RelayFrame(jpeg: frame.jpeg, pixelSize: frame.pixelSize))
        }
    }

    public var latestFrame: RelayFrame? {
        capture.latestFrame.map { RelayFrame(jpeg: $0.jpeg, pixelSize: $0.pixelSize) }
    }

    public var inputAvailable: Bool { InputInjector.isTrusted }

    public var status: [String: Any] {
        [
            "source": "mirroring",
            "capturing": capture.isCapturing,
            "window": capture.windowFrame.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] } as Any? ?? NSNull(),
            "accessibilityTrusted": InputInjector.isTrusted,
        ]
    }

    public func start(onFrame: @escaping (RelayFrame) -> Void) {
        frameHandler = onFrame
        capture.start()
    }

    public func handle(_ message: ControlMessage) {
        guard let frame = capture.windowFrame else { return }
        let geometry = WindowGeometry(frame: frame)
        inputQueue.async { self.input.handle(message, geometry: geometry) }
    }

    public func releaseAll() {
        let geometry = capture.windowFrame.map(WindowGeometry.init(frame:))
        inputQueue.async { self.input.releaseAll(geometry: geometry) }
    }
}
