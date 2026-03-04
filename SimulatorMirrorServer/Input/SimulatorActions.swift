import CoreGraphics
import AppKit

/// Sends Simulator keyboard shortcuts to trigger device actions.
final class SimulatorActions {
    static func home()       { send(vk: 4,   flags: [.maskCommand, .maskShift]) } // Cmd+Shift+H
    static func screenshot() { send(vk: 1,   flags: .maskCommand)               } // Cmd+S
    static func rotate()     { send(vk: 123, flags: .maskCommand)               } // Cmd+Left
    static func shake()      { send(vk: 6,   flags: [.maskCommand, .maskControl]) } // Cmd+Ctrl+Z

    private static func send(vk: CGKeyCode, flags: CGEventFlags) {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .first?.processIdentifier else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: vk,
                                      keyDown: keyDown) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }
}
