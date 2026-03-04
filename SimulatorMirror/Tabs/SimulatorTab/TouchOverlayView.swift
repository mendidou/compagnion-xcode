import SwiftUI

struct TouchOverlayView: View {
    let touchURL: URL?
    /// Maps a raw touch point in the overlay's coordinate space to normalised (0–1)
    /// full-image coordinates that the server understands.
    var coordinateMapper: (CGPoint) -> CGPoint
    var onAction: (() -> Void)? = nil

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let mapped = coordinateMapper(value.location)
                        let type = value.translation == .zero ? "down" : "move"
                        sendTouch(type: type, point: mapped)
                        if type == "down" { onAction?() }
                    }
                    .onEnded { value in
                        let mapped = coordinateMapper(value.location)
                        sendTouch(type: "up", point: mapped)
                        onAction?()
                    }
            )
    }

    private func sendTouch(type: String, point: CGPoint) {
        guard let url = touchURL else { return }
        let event = TouchEvent(type: type, x: Float(point.x), y: Float(point.y))
        TouchSender.send(event, to: url)
    }
}
