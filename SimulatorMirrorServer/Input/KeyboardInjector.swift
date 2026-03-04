import CoreGraphics
import AppKit

final class KeyboardInjector {
    /// Sends Cmd+K directly to the Simulator process, toggling its iOS software keyboard.
    static func toggleKeyboard() {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .first?.processIdentifier else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        // VK 40 = 'k'; Cmd+K is Simulator's "Toggle Software Keyboard" shortcut
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 40, keyDown: true) {
            down.flags = .maskCommand
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 40, keyDown: false) {
            up.flags = .maskCommand
            up.postToPid(pid)
        }
    }
}
