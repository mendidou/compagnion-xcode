import ScreenCaptureKit
import CoreImage
import AppKit

final class ScreenCaptureManager: NSObject {
    let frameBuffer = FrameBuffer()
    private var stream: SCStream?
    private let ciContext = CIContext()
    private var currentWindow: SCWindow?

    func start() async throws {
        let content = try await SCShareableContent.current
        // Pick the largest Simulator window — that's the device screen, not toolbars/overlays
        guard let window = content.windows
            .filter({ $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator" })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            throw CaptureError.simulatorNotFound
        }

        currentWindow = window
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    func currentWindowFrame() -> CGRect? {
        currentWindow?.frame
    }

    enum CaptureError: Error {
        case simulatorNotFound
    }
}

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // Extract image data synchronously while CMSampleBuffer is still valid
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let nsImage = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = nsImage.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) else { return }
        Task {
            await frameBuffer.update(frame: jpegData)
        }
    }
}
