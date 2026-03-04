import Foundation

struct TouchEvent: Encodable {
    let type: String
    let x: Float
    let y: Float
}

final class TouchSender {
    static func send(_ event: TouchEvent, to url: URL) {
        guard let body = try? JSONEncoder().encode(event) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request).resume()
    }
}
