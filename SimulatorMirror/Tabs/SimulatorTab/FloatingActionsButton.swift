import SwiftUI

struct FloatingActionsButton: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RelayManager.self) private var relayManager
    var onAction: (() -> Void)? = nil

    var body: some View {
        Menu {
            Button { fire(path: "/keyboard", url: settings.keyboardURL); onAction?() } label: {
                Label("Toggle Keyboard", systemImage: "keyboard")
            }
            Button { fire(path: "/home", url: settings.homeURL); onAction?() } label: {
                Label("Home", systemImage: "house")
            }
            Button { fire(path: "/rotate", url: settings.rotateURL); onAction?() } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            Divider()
            Button { fire(path: "/movefront", url: settings.moveFrontURL); onAction?() } label: {
                Label("Move to Front", systemImage: "square.on.square")
            }
            Divider()
            Button { fire(path: "/screenshot", url: settings.screenshotURL); onAction?() } label: {
                Label("Screenshot", systemImage: "camera")
            }
            Button { fire(path: "/shake", url: settings.shakeURL); onAction?() } label: {
                Label("Shake", systemImage: "iphone.radiowaves.left.and.right")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.4))
                .font(.system(size: 42, weight: .medium))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
                .frame(width: 58, height: 58)
        }
    }

    private func fire(path: String, url: URL?) {
        if relayManager.isConnected {
            relayManager.sendFireAndForget(method: "POST", path: path)
        } else {
            guard let url else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 3
            URLSession.shared.dataTask(with: req).resume()
        }
    }
}
