import AppKit
import ApplicationServices

final class SimulatorWindowManager {
    static func isSimulatorFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.iphonesimulator"
    }

    static func moveToFront() {
        // AppleScript is the only reliable way to bring an app to front across Spaces,
        // including when a full-screen window is active on a different Space.
        // NSAppleScript must run on the main thread for Apple Events to be dispatched correctly.
        DispatchQueue.main.async {
            let script = NSAppleScript(source: "tell application \"Simulator\" to activate")
            script?.executeAndReturnError(nil)
        }
    }

    /// Returns a normalised (0–1) CGRect that represents the device-screen area within the
    /// captured window frame, cropping out the toolbar, side padding, and device bezel.
    static func screenRect() -> CGRect {
        guard let (windowOrigin, windowSize) = largestSimulatorWindowFrame(),
              windowSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if let rect = axDeviceContentRect(windowOrigin: windowOrigin, windowSize: windowSize) {
            return rect
        }
        // Fallback: only crop toolbar
        let toolbarH = axToolbarHeight() ?? 32.0
        let yFraction = min(toolbarH / windowSize.height, 0.15)
        return CGRect(x: 0, y: yFraction, width: 1, height: 1 - yFraction)
    }

    // MARK: - Private

    /// Returns the origin (top-left, screen coords) and size of the largest Simulator window.
    private static func largestSimulatorWindowFrame() -> (CGPoint, CGSize)? {
        let pids = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .map { $0.processIdentifier }
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        return list
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t).map { pids.contains($0) } ?? false }
            .compactMap { info -> (CGPoint, CGSize)? in
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
                return (rect.origin, rect.size)
            }
            .max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height })
    }

    private static func largestSimulatorWindowSize() -> CGSize? {
        largestSimulatorWindowFrame()?.1
    }

    /// Walks the Simulator AX tree to find the deepest child element that:
    ///  - is not the toolbar
    ///  - is narrower than the full window (i.e. has side padding cropped)
    ///  - has a portrait phone-like aspect ratio (h/w > 1.5)
    /// Returns a normalised CGRect relative to the window.
    private static func axDeviceContentRect(windowOrigin: CGPoint,
                                            windowSize: CGSize) -> CGRect? {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .first?.processIdentifier else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString,
                                            &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let axWindow = windows.first else { return nil }

        return bestContentRect(in: axWindow,
                               windowOrigin: windowOrigin,
                               windowSize: windowSize,
                               depth: 0)
    }

    /// Recursive helper — returns the tightest normalised rect that looks like a device screen.
    private static func bestContentRect(in element: AXUIElement,
                                        windowOrigin: CGPoint,
                                        windowSize: CGSize,
                                        depth: Int) -> CGRect? {
        guard depth < 6 else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        var best: CGRect? = nil

        for child in children {
            // Skip toolbar
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXToolbar" { continue }

            // Get child frame in screen coords
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString,
                                                &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString,
                                                &sizeRef) == .success,
                  let posVal = posRef, let sizeVal = sizeRef else { continue }

            var pos  = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posVal  as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeVal as! AXValue, .cgSize,  &size)
            guard size.width > 60, size.height > 60 else { continue }

            // Normalise relative to window
            let nx = (pos.x - windowOrigin.x) / windowSize.width
            let ny = (pos.y - windowOrigin.y) / windowSize.height
            let nw = size.width  / windowSize.width
            let nh = size.height / windowSize.height

            // Must be inside the window and meaningfully narrower (has side padding)
            guard nx >= 0, ny >= 0, nw > 0.1, nh > 0.1,
                  nx + nw <= 1.05, ny + nh <= 1.05 else { continue }

            let candidate = CGRect(x: nx, y: ny, width: nw, height: nh)

            // Prefer portrait-ratio elements that don't span the full width
            let isNarrow   = nw < 0.98
            let isPortrait = size.height / size.width > 1.4

            if isNarrow && isPortrait {
                // Try going deeper for an even tighter crop
                if let deeper = bestContentRect(in: child,
                                                windowOrigin: windowOrigin,
                                                windowSize: windowSize,
                                                depth: depth + 1) {
                    best = deeper
                } else {
                    best = candidate
                }
            }
        }
        return best
    }

    private static func axToolbarHeight() -> CGFloat? {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .first?.processIdentifier else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        for axWindow in windows {
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXChildrenAttribute as CFString,
                                                &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }

            for child in children {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                guard (roleRef as? String) == "AXToolbar" else { continue }

                var sizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString,
                                                    &sizeRef) == .success,
                      let sizeVal = sizeRef,
                      CFGetTypeID(sizeVal) == AXValueGetTypeID() else { continue }
                var size = CGSize.zero
                AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
                return size.height
            }
        }
        return nil
    }
}
