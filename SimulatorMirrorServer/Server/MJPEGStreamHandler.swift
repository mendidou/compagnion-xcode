import Network
import Foundation

final class MJPEGStreamHandler {
    static func stream(to connection: NWConnection, frameBuffer: FrameBuffer) {
        let preamble = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: preamble.data(using: .utf8), completion: .idempotent)

        Task {
            let (stream, _) = await frameBuffer.makeStream()
            for await frameData in stream {
                let header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frameData.count)\r\n\r\n"
                var packet = Data()
                packet.append(header.data(using: .utf8)!)
                packet.append(frameData)
                packet.append("\r\n".data(using: .utf8)!)

                let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    connection.send(content: packet, completion: .contentProcessed { error in
                        cont.resume(returning: error == nil)
                    })
                }
                if !ok { break }
            }
            connection.cancel()
        }
    }
}
