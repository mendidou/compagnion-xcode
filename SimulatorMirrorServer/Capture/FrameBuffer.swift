import Foundation

actor FrameBuffer {
    private var latestFrame: Data?
    private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    func update(frame: Data) {
        latestFrame = frame
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }

    func makeStream() -> (AsyncStream<Data>, UUID) {
        let id = UUID()
        // bufferingNewest(1): when the consumer (network send) is slower than
        // the producer (screen capture), old frames are dropped and only the
        // most recent frame is kept — preventing ever-growing lag.
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            Task {
                await self?.register(continuation: continuation, id: id)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.unregister(id: id)
                }
            }
        }
        return (stream, id)
    }

    private func register(continuation: AsyncStream<Data>.Continuation, id: UUID) {
        continuations[id] = continuation
        if let frame = latestFrame {
            continuation.yield(frame)
        }
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    var hasClients: Bool {
        !continuations.isEmpty
    }
}
