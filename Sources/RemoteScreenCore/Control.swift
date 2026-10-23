import CoreGraphics
import Foundation

/// A control message from a remote viewer. Coordinates are normalized to the mirrored window (0...1).
public enum ControlMessage: Equatable {
    case pointer(phase: PointerPhase, x: Double, y: Double)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case text(String)
    case key(code: String, modifiers: Set<KeyModifier>)
    case action(DeviceAction)
    /// Switch the shown/touched display mid-session: "auto", a display number or unique ID.
    case display(String)

    public enum PointerPhase: String { case down, move, up }

    /// The viewer's Stop button: `{"t":"shutdown"}`. Handled by the server, not the device backend.
    public static func isShutdown(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["t"] as? String == "shutdown"
    }

    public static func parse(_ json: String) -> ControlMessage? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["t"] as? String else { return nil }
        func num(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        switch type {
        case "down", "move", "up":
            guard let x = num("x"), let y = num("y"), x.isFinite, y.isFinite else { return nil }
            return .pointer(phase: PointerPhase(rawValue: type)!, x: x, y: y)
        case "scroll":
            guard let x = num("x"), let y = num("y"), let dx = num("dx"), let dy = num("dy"),
                  [x, y, dx, dy].allSatisfy(\.isFinite) else { return nil }
            return .scroll(x: x, y: y, dx: dx, dy: dy)
        case "text":
            guard let s = obj["s"] as? String, !s.isEmpty, s.utf16.count <= 4096 else { return nil }
            return .text(s)
        case "key":
            guard let code = obj["code"] as? String else { return nil }
            let mods = Set(((obj["mods"] as? [String]) ?? []).compactMap(KeyModifier.init(rawValue:)))
            return .key(code: code, modifiers: mods)
        case "display":
            guard let d = obj["display"] as? String, !d.isEmpty, d.count <= 64 else { return nil }
            return .display(d)
        case "action":
            guard let name = obj["name"] as? String, let action = DeviceAction(rawValue: name) else { return nil }
            return .action(action)
        default:
            return nil
        }
    }
}

public enum KeyModifier: String, CaseIterable {
    case shift, control, option, command

    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }
}

/// iPhone-level actions exposed by the iPhone Mirroring menu bar ("View" menu).
/// REA shows the commands exist (`MainSceneCommands`, "Home Screen/App Switcher toolbar button and
/// menu item title", "Spotlight menu item title"); the Cmd-1/2/3 equivalents are Apple's documented
/// shortcuts and are not yet confirmed by REA observation (see README).
public enum DeviceAction: String, CaseIterable {
    case home, appSwitcher, spotlight

    public var shortcut: (code: String, modifiers: Set<KeyModifier>) {
        switch self {
        case .home: return ("Digit1", [.command])
        case .appSwitcher: return ("Digit2", [.command])
        case .spotlight: return ("Digit3", [.command])
        }
    }
}

/// Maps DOM `KeyboardEvent.code` values to macOS ANSI virtual key codes.
public enum KeyMap {
    public static let codes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "Enter": 36, "NumpadEnter": 76, "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53,
            "Delete": 117, "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
            "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
            "Minus": 27, "Equal": 24, "BracketLeft": 33, "BracketRight": 30, "Backslash": 42,
            "Semicolon": 41, "Quote": 39, "Comma": 43, "Period": 47, "Slash": 44, "Backquote": 50,
        ]
        let letters: [Character: CGKeyCode] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
            "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17, "O": 31, "U": 32,
            "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
        ]
        for (c, v) in letters { m["Key\(c)"] = v }
        let digits: [Character: CGKeyCode] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29]
        for (c, v) in digits { m["Digit\(c)"] = v }
        return m
    }()

    public static func flags(_ modifiers: Set<KeyModifier>) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
    }
}

/// Converts normalized viewer coordinates into global display coordinates (top-left origin, points).
public struct WindowGeometry: Equatable {
    public var frame: CGRect

    public init(frame: CGRect) { self.frame = frame }

    public func point(x: Double, y: Double) -> CGPoint {
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: frame.minX + cx * frame.width, y: frame.minY + cy * frame.height)
    }
}
