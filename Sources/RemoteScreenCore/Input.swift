import AppKit
import CoreGraphics
import Foundation

/// Injects viewer input into the iPhone Mirroring window as ordinary macOS events.
///
/// REA finding (ScreenContinuityUI): every NSResponder input method on `CaptureViewController`
/// (mouse, scroll, key, magnify/rotate) funnels through `0x33338` into `HIDCaptureViewModel`
/// (`0x1ecbc`), which converts the NSEvent into UniversalHID reports for the phone. Text goes
/// through `RemoteTextInputView` (an NSTextInputClient bridged to RTI). So synthesizing normal
/// mouse and keyboard events at the window is sufficient; no private protocol is needed.
public final class InputInjector {
    public enum Mode: String { case hid, pid }

    let mode: Mode
    let onLog: (String) -> Void
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonDown = false
    private var lastActivation = Date.distantPast

    public init(mode: Mode, onLog: @escaping (String) -> Void) {
        self.mode = mode
        self.onLog = onLog
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Lists iPhone Mirroring's menu items with their key equivalents ("Menu > Item  ⌘1"), via Accessibility.
    public static func menuShortcuts() -> [String] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: MirrorCapture.bundleIdentifier).first?.processIdentifier else { return [] }
        func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        var lines: [String] = []
        func walk(_ e: AXUIElement, path: [String]) {
            let title = attr(e, kAXTitleAttribute) as? String ?? ""
            let here = title.isEmpty ? path : path + [title]
            if let ch = attr(e, kAXMenuItemCmdCharAttribute) as? String, !ch.isEmpty {
                let mods = (attr(e, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
                var m = ""
                if mods & 4 != 0 { m += "⌃" }
                if mods & 2 != 0 { m += "⌥" }
                if mods & 1 != 0 { m += "⇧" }
                if mods & 8 == 0 { m += "⌘" }
                lines.append("\(here.joined(separator: " > "))\t\(m)\(ch)")
            }
            for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, path: here) }
        }
        if let bar = attr(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) { walk(bar as! AXUIElement, path: []) }
        return lines
    }

    var targetPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: MirrorCapture.bundleIdentifier).first?.processIdentifier
    }

    /// HID-tap events go to whatever is frontmost, so bring iPhone Mirroring forward first.
    private func ensureFrontmost() {
        guard mode == .hid else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == MirrorCapture.bundleIdentifier { return }
        guard Date().timeIntervalSince(lastActivation) > 0.5 else { return }
        lastActivation = Date()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MirrorCapture.bundleIdentifier) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 1)
        usleep(50_000)
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        switch mode {
        case .hid: event.post(tap: .cghidEventTap)
        case .pid:
            guard let pid = targetPID else { return }
            event.postToPid(pid)
        }
    }

    public func handle(_ message: ControlMessage, geometry: WindowGeometry) {
        switch message {
        case let .pointer(phase, x, y):
            let p = geometry.point(x: x, y: y)
            switch phase {
            case .down:
                ensureFrontmost()
                post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
                let e = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: 1)
                post(e)
                buttonDown = true
            case .move:
                let type: CGEventType = buttonDown ? .leftMouseDragged : .mouseMoved
                post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left))
            case .up:
                let e = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: 1)
                post(e)
                buttonDown = false
            }
        case let .scroll(x, y, dx, dy):
            ensureFrontmost()
            let p = geometry.point(x: x, y: y)
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
            let clamp = { (v: Double) in Int32(max(-2000, min(2000, v.rounded()))) }
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: clamp(-dy), wheel2: clamp(-dx), wheel3: 0)
            e?.location = p
            post(e)
        case let .text(s):
            ensureFrontmost()
            typeText(s)
        case let .key(code, modifiers):
            ensureFrontmost()
            guard let keyCode = KeyMap.codes[code] else {
                onLog("Ignoring unmapped key code \(code)")
                return
            }
            pressKey(keyCode, flags: KeyMap.flags(modifiers))
        case .display:
            break // The iPhone Mirroring window has a single display.
        case let .action(action):
            ensureFrontmost()
            let (code, mods) = action.shortcut
            pressKey(KeyMap.codes[code]!, flags: KeyMap.flags(mods))
        }
    }

    /// Releases a held button, e.g. when the viewer disconnects mid-drag.
    public func releaseAll(geometry: WindowGeometry?) {
        guard buttonDown else { return }
        buttonDown = false
        let p = geometry?.point(x: 0.5, y: 0.5) ?? CGEvent(source: nil)?.location ?? .zero
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
    }

    private func pressKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        post(down)
        post(up)
    }

    /// Types arbitrary Unicode by attaching the string to key events (layout independent).
    private func typeText(_ s: String) {
        for ch in s {
            if ch == "\n" || ch == "\r" { pressKey(36, flags: []); continue }
            let units = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.flags = []
            up?.flags = []
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(down)
            post(up)
        }
    }
}
