import Foundation

struct TouchEvent: Decodable {
    let type: String
    let x: Float
    let y: Float
}

final class TouchReceiver {
    static func handle(data: Data) {
        guard let event = try? JSONDecoder().decode(TouchEvent.self, from: data) else { return }
        CGEventInjector.inject(event)
    }
}
