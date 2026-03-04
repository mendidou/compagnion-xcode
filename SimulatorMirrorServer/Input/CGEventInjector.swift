import CoreGraphics
import AppKit
import Foundation

final class CGEventInjector {
    static func inject(_ touch: TouchEvent) {
        guard let bounds = simulatorWindowBounds() else { return }

        let cgX = bounds.origin.x + CGFloat(touch.x) * bounds.width
        let cgY = bounds.origin.y + CGFloat(touch.y) * bounds.height
        let point = CGPoint(x: cgX, y: cgY)

        switch touch.type {
        case "down":
            post(type: .leftMouseDown, point: point, clickCount: 1)
        case "move":
            post(type: .leftMouseDragged, point: point, clickCount: 1)
        case "up":
            post(type: .leftMouseUp, point: point, clickCount: 1)
        default:
            post(type: .leftMouseDown, point: point, clickCount: 1)
            post(type: .leftMouseUp, point: point, clickCount: 1)
        }
    }

    // Cache window bounds for 1 second — CGWindowListCopyWindowInfo is an expensive system call.
    private static var cachedBounds: CGRect?
    private static var cacheTimestamp: Date = .distantPast

    /// Returns the largest Simulator window bounds in CGEvent coordinate space (top-left origin, logical points).
    private static func simulatorWindowBounds() -> CGRect? {
        let now = Date()
        if now.timeIntervalSince(cacheTimestamp) < 1.0, let cached = cachedBounds {
            return cached
        }

        let pids = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
            .map { $0.processIdentifier }
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let bounds = list
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t).map { pids.contains($0) } ?? false }
            .compactMap { info -> CGRect? in
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: dict)
            }
            .max(by: { $0.width * $0.height < $1.width * $1.height })

        cachedBounds = bounds
        cacheTimestamp = now
        return bounds
    }

    private static func post(type: CGEventType, point: CGPoint, clickCount: Int) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.post(tap: .cghidEventTap)
    }
}
