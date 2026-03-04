import Foundation

final class KeyboardSender {
    static func toggle(url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request).resume()
    }
}
