import AppKit
import CoreDeviceInput
import CoreGraphics
import Foundation
import RemoteScreenCore

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(s)\n".utf8))
}

let usage = """
Usage: ios-remote-screen [options]

Streams an iPhone screen and accepts remote input on a loopback port.
Forward it to another machine with:  ssh -L 8765:127.0.0.1:8765 user@server

Sources:
  --source usb        A USB-connected iPhone (default): CoreMediaIO video (needs Camera permission,
                      falls back to ~1 fps devicectl screenshots) plus CoreDevice touch/keyboard
                      input (needs Developer Mode on the phone and Xcode 27+ on this Mac)
  --source mirroring  The macOS iPhone Mirroring window (needs the same Apple Account)
  --device D          usb: device name, UDID or CoreDevice identifier (default: the only one)
  --max-width W       usb: downscale frames wider than W pixels (default: native)
  --display D         usb screenshot video: display unique ID or number, or auto (default: the
                      active display; foldables such as iPhone Duo have two)
  --video V           usb: auto (default), usb (CoreMediaIO, needs Camera permission) or
                      screenshot (devicectl, ~1 fps, works from SSH sessions without permissions)

Options:
  --port N            Loopback port (default 8765)
  --fps N             Max capture frame rate, 1-60 (default 30)
  --quality Q         JPEG quality 0.1-1.0 (default 0.6)
  --scale S           Output pixels per window point (default: display backing scale)
  --token T           Access token (default: random; printed at startup)
  --no-token          Disable the access token (any local process can connect)
  --input-mode M      hid (default): post to the HID event tap, bringing iPhone Mirroring to front
                      pid: post directly to the app process (experimental)
  --view-only         Ignore all input from viewers
  --launch            Open iPhone Mirroring if it is not running
  --request-permissions  Ask macOS for Screen Recording and Accessibility, then exit
  --check             Print permission and window status, then exit
  --dump-menu         Print iPhone Mirroring menu items and shortcuts (needs Accessibility), then exit
  --list-devices      Print USB/CoreDevice iPhones as JSON, then exit
  --allow-shutdown    Show a Stop button in the viewer that ends this process
  --exit-with-stdin   Exit when stdin closes (used by the launcher so an SSH disconnect stops the relay)
  -h, --help          Show this help
"""

var serverOptions = RelayServer.Options()
var captureOptions = MirrorCapture.Options()
var inputMode = InputInjector.Mode.hid
var launch = false
var check = false
var requestPermissions = false
var noToken = false
var dumpMenu = false
var source = "usb"
var listDevices = false
var exitWithStdin = false
var usbOptions = UsbScreenBackend.Options()

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String {
    guard !args.isEmpty else {
        log("\(flag) needs a value")
        exit(2)
    }
    return args.removeFirst()
}

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--source":
        source = value(a)
        guard ["mirroring", "usb"].contains(source) else { log("invalid --source"); exit(2) }
    case "--device": usbOptions.device = value(a)
    case "--video":
        usbOptions.video = value(a)
        guard ["auto", "usb", "screenshot"].contains(usbOptions.video) else { log("invalid --video"); exit(2) }
    case "--display": usbOptions.display = value(a)
    case "--max-width":
        guard let w = Int(value(a)), w >= 0 else { log("invalid --max-width"); exit(2) }
        usbOptions.maxWidth = w
    case "--port":
        guard let p = UInt16(value(a)), p > 0 else { log("invalid --port"); exit(2) }
        serverOptions.port = p
    case "--fps":
        guard let f = Int(value(a)), (1...60).contains(f) else { log("invalid --fps"); exit(2) }
        captureOptions.fps = f
        usbOptions.fps = f
    case "--quality":
        guard let q = Double(value(a)), (0.1...1).contains(q) else { log("invalid --quality"); exit(2) }
        captureOptions.jpegQuality = q
        usbOptions.jpegQuality = q
    case "--scale":
        guard let s = Double(value(a)), s > 0, s <= 4 else { log("invalid --scale"); exit(2) }
        captureOptions.scale = s
    case "--token": serverOptions.token = value(a)
    case "--no-token": noToken = true
    case "--input-mode":
        guard let m = InputInjector.Mode(rawValue: value(a)) else { log("invalid --input-mode"); exit(2) }
        inputMode = m
    case "--view-only": serverOptions.viewOnly = true
    case "--allow-shutdown": serverOptions.allowShutdown = true
    case "--exit-with-stdin": exitWithStdin = true
    case "--list-devices": listDevices = true
    case "--launch": launch = true
    case "--check": check = true
    case "--dump-menu": dumpMenu = true
    case "--request-permissions": requestPermissions = true
    case "-h", "--help": print(usage); exit(0)
    default:
        log("unknown option \(a)\n\(usage)")
        exit(2)
    }
}

if listDevices {
    let devices = CoreDeviceLookup.physicalDevices().map { ["name": $0.name, "udid": $0.udid, "identifier": $0.identifier.uuidString] }
    let data = try! JSONSerialization.data(withJSONObject: devices, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

if exitWithStdin {
    // The launcher runs us under `ssh`; when that connection drops, stdin hits EOF and we exit,
    // releasing the device (CoreDevice usage assertion, capture session) with the process.
    Thread.detachNewThread {
        while FileHandle.standardInput.availableData.count > 0 {}
        log("stdin closed; exiting")
        exit(0)
    }
}

let screenOK = CGPreflightScreenCaptureAccess()
let axOK = InputInjector.isTrusted
let running = !NSRunningApplication.runningApplications(withBundleIdentifier: MirrorCapture.bundleIdentifier).isEmpty

if requestPermissions {
    if !screenOK { _ = CGRequestScreenCaptureAccess() }
    if !axOK {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    print("Requested. Grant access in System Settings > Privacy & Security, then restart ios-remote-screen.")
    exit(0)
}

if dumpMenu {
    let lines = InputInjector.menuShortcuts()
    print(lines.isEmpty ? "no menu items (is iPhone Mirroring running and Accessibility granted?)" : lines.joined(separator: "\n"))
    exit(lines.isEmpty ? 1 : 0)
}

if check {
    print("screenRecording: \(screenOK)")
    print("accessibility: \(axOK)")
    print("iPhoneMirroringRunning: \(running)")
    exit(screenOK && axOK && running ? 0 : 1)
}

if source == "mirroring" {
    if !screenOK { log("WARNING: Screen Recording permission is missing; run with --request-permissions") }
    if !axOK && !serverOptions.viewOnly { log("WARNING: Accessibility permission is missing; input will be dropped by macOS") }
}

if source == "mirroring", launch, !running, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MirrorCapture.bundleIdentifier) {
    log("Opening iPhone Mirroring")
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        if let error { log("Failed to open iPhone Mirroring: \(error.localizedDescription)") }
    }
}

if noToken {
    serverOptions.token = nil
} else if serverOptions.token == nil {
    var bytes = [UInt8](repeating: 0, count: 18)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    serverOptions.token = Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
}

let backend: RelayBackend
if source == "usb" {
    var input: CoreDeviceInput?
    if serverOptions.viewOnly {
        input = nil
    } else if let device = CoreDeviceLookup.find(usbOptions.device) {
        log("CoreDevice: using \(device.name) (\(device.identifier)) for input")
        input = CoreDeviceInput(deviceID: device.identifier, log: log)
        if usbOptions.device == nil { usbOptions.device = device.name }
        usbOptions.udid = device.udid
    } else {
        log("CoreDevice: no unique matching device for input; video only (use --device)")
    }
    backend = UsbScreenBackend(options: usbOptions, input: input, log: log)
} else {
    backend = MirroringBackend(captureOptions: captureOptions, inputMode: inputMode, log: log)
}
let server = RelayServer(options: serverOptions, backend: backend, log: log)

do {
    try server.start()
} catch {
    log("Failed to start server: \(error)")
    exit(1)
}
backend.start { frame in server.broadcast(frame) }

let suffix = serverOptions.token.map { "/?token=\($0)" } ?? "/"
log("Open http://127.0.0.1:\(serverOptions.port)\(suffix)")
log("Remote: ssh -L \(serverOptions.port):127.0.0.1:\(serverOptions.port) <user>@<this-mac>, then open the same URL on the laptop")

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
dispatchMain()
