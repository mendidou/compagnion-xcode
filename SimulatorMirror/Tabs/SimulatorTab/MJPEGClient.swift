import SwiftUI

@Observable
final class MJPEGClient {
    var currentImage: UIImage?
    var isConnected = false

    private var mjpegDelegate: MJPEGSessionDelegate?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var currentURL: URL?
    private var retryDelay: Double = 1.0
    /// Incremented on every connect() and disconnect() so stale onError/retry
    /// callbacks from a previous session are silently discarded.
    private var generation = 0

    func connect(to url: URL) {
        generation += 1
        currentURL = url
        retryDelay = 0.5
        startStream(url: url, generation: generation)
    }

    func disconnect() {
        generation += 1          // invalidate any in-flight retries from old session
        currentURL = nil
        dataTask?.cancel()
        session?.invalidateAndCancel()
        mjpegDelegate = nil
        session = nil
        dataTask = nil
        isConnected = false
        currentImage = nil
    }

    private func startStream(url: URL, generation: Int) {
        let del = MJPEGSessionDelegate(
            onFrame: { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    self.currentImage = image
                    self.isConnected = true
                }
            },
            onError: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    self.isConnected = false
                    // Keep currentImage so there's no flash to black during reconnect
                    self.scheduleRetry(generation: generation)
                }
            }
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        let s = URLSession(configuration: config, delegate: del, delegateQueue: nil)
        mjpegDelegate = del
        session = s
        let task = s.dataTask(with: url)
        dataTask = task
        task.resume()
    }

    private func scheduleRetry(generation: Int) {
        guard self.generation == generation, let url = currentURL else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation, let url = self.currentURL else { return }
            self.startStream(url: url, generation: generation)
        }
    }
}

// URLSession parses multipart/x-mixed-replace itself:
// - didReceive response fires once per JPEG frame with Content-Type: image/jpeg
// - didReceive data delivers the raw JPEG bytes (no boundary headers)
private final class MJPEGSessionDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var expectedLength = 0
    private let onFrame: (UIImage) -> Void
    private let onError: () -> Void

    init(onFrame: @escaping (UIImage) -> Void, onError: @escaping () -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // Each frame arrives as a new "response" — reset buffer for this frame
        buffer = Data()
        expectedLength = (response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Content-Length") }
            .flatMap { Int($0) } ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // Emit as soon as we have all expected bytes (or immediately if no Content-Length)
        if expectedLength == 0 || buffer.count >= expectedLength {
            if let image = UIImage(data: buffer) {
                onFrame(image)
            }
            buffer = Data()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { onError() }
    }
}
