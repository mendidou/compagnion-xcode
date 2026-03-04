import Foundation
import NIOCore
import NIOPosix
import NIOSSH

final class SSHConnection: TerminalConnection {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let group: EventLoopGroup
    private var channel: Channel?
    private var sshChannel: Channel?

    init(host: String, port: Int, username: String, password: String) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        connect(host: host, port: port, username: username, password: password)
    }

    func send(data: Data) {
        guard let sshChannel else { return }
        // Chunk large payloads into 1KB pieces
        let chunkSize = 1024
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = Data(bytes[offset..<end])
            let buffer = sshChannel.allocator.buffer(data: chunk)
            let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            sshChannel.writeAndFlush(channelData, promise: nil)
            offset = end
        }
    }

    func resize(cols: Int, rows: Int) {
        guard let sshChannel else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        _ = sshChannel.triggerUserOutboundEvent(request)
    }

    func disconnect() {
        sshChannel?.close(promise: nil)
        channel?.close(promise: nil)
        try? group.syncShutdownGracefully()
    }

    private func connect(host: String, port: Int, username: String, password: String) {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(
                        .init(
                            userAuthDelegate: PasswordAuthDelegate(username: username, password: password),
                            serverAuthDelegate: AcceptAllHostKeysDelegate()
                        )
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler)
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(10))

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.channel = channel
                self.openSession(on: channel)
            case .failure(let error):
                self.onDisconnect?(error)
            }
        }
    }

    private func openSession(on channel: Channel) {
        let dataHandler = ShellDataHandler(connection: self)
        let createChannel = channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            handler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHConnectionError.unsupportedChannelType)
                }
                return childChannel.pipeline.addHandler(dataHandler)
            }
            return promise.futureResult
        }

        createChannel.whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sshChannel):
                self.sshChannel = sshChannel
                self.requestPTYAndShell(on: sshChannel)
            case .failure(let error):
                self.onDisconnect?(error)
            }
        }
    }

    private func requestPTYAndShell(on channel: Channel) {
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )

        channel.triggerUserOutboundEvent(ptyRequest).flatMap {
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            return channel.triggerUserOutboundEvent(shellRequest)
        }.whenFailure { [weak self] error in
            self?.onDisconnect?(error)
        }
    }
}

// MARK: - Shell Data Handler

private final class ShellDataHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private weak var connection: SSHConnection?

    init(connection: SSHConnection) {
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        let d = Data(bytes)
        connection?.onReceive?(d)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        connection?.onDisconnect?(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection?.onDisconnect?(nil)
    }
}

// MARK: - Auth Delegates

private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.password) {
            nextChallengePromise.succeed(
                .init(username: username, serviceName: "", offer: .password(.init(password: password)))
            )
        } else {
            nextChallengePromise.succeed(nil)
        }
    }
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - Error

private enum SSHConnectionError: Error {
    case unsupportedChannelType
}
