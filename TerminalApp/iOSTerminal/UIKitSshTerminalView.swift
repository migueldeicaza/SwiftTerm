//
//  UIKitSshTerminalView.swift
//  iOS
//
//  Created by Miguel de Icaza on 4/22/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation
import UIKit
import SwiftTerm
import NIOCore
import NIOPosix
import NIOSSH

struct SSHConnectionInfo: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let term: String
    let environment: [String: String]

    init(
        host: String = "localhost",
        port: Int = 22,
        username: String,
        password: String,
        term: String = "xterm-256color",
        environment: [String: String] = ["LANG": "en_US.UTF-8"]
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.term = term
        self.environment = environment
    }
}

private enum SSHClientError: Error {
    case invalidChannelType
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: @Sendable (Error) -> Void

    init(onError: @escaping @Sendable (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class SSHShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let feedSender: TerminalFeedSender
    private let term: String
    private let environment: [String: String]
    private let initialWindowSize: (cols: Int, rows: Int)

    init(
        feedSender: TerminalFeedSender,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.feedSender = feedSender
        self.term = term
        self.environment = environment
        self.initialWindowSize = initialWindowSize
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let pipeline = context.pipeline
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            pipeline.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: term,
            terminalCharacterWidth: initialWindowSize.cols,
            terminalRowHeight: initialWindowSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        for (name, value) in environment {
            let env = SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
            context.triggerUserOutboundEvent(env, promise: nil)
        }

        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)

        guard case .byteBuffer(var buffer) = payload.data else {
            return
        }

        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
            return
        }

        let chunkSize = 1024
        var next = 0
        while next < bytes.count {
            let end = min(next + chunkSize, bytes.count)
            let chunk = bytes[next..<end]
            // feed is thread-safe as of the terminal-lock work; keep parsing on the NIO channel thread.
            feedSender.feed(byteArray: chunk)
            next = end
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            feedSender.feed(text: "\n[SSH] Session exited with status \(status.exitStatus)\n")
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            feedSender.feed(text: "\n[SSH] Session closed: \(signal.signalName)\n")
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

@MainActor
private final class SSHConnection {
    private let feedSender: TerminalFeedSender
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let term: String
    private let environment: [String: String]
    private let initialWindowSize: (cols: Int, rows: Int)
    private var group: EventLoopGroup?
    private var channel: Channel?
    private var sessionChannel: Channel?

    init(
        feedSender: TerminalFeedSender,
        host: String,
        port: Int,
        username: String,
        password: String,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.feedSender = feedSender
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.term = term
        self.environment = environment
        self.initialWindowSize = initialWindowSize
    }

    func connect() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let username = username
        let password = password
        let reportError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleError(error)
            }
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: SimplePasswordDelegate(
                                    username: username,
                                    password: password
                                ),
                                serverAuthDelegate: AcceptAllHostKeysDelegate()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler(onError: reportError)
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            Task { @MainActor [weak self] in
                self?.connectionCompleted(result)
            }
        }
    }

    func send(_ data: Data) {
        guard let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            var buffer = sessionChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            sessionChannel.writeAndFlush(payload, promise: nil)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let sessionChannel else { return }
        sessionChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            sessionChannel.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    func disconnect() {
        let channel = channel
        let group = group
        self.channel = nil
        sessionChannel = nil
        self.group = nil

        if let channel, let group {
            channel.closeFuture.whenComplete { _ in
                group.shutdownGracefully { _ in }
            }
            channel.close(promise: nil)
        } else if let group {
            group.shutdownGracefully { _ in }
        }
    }

    private func connectionCompleted(_ result: Result<Channel, Error>) {
        switch result {
        case .failure(let error):
            handleError(error)
            disconnect()
        case .success(let channel):
            guard group != nil else {
                channel.close(promise: nil)
                return
            }
            self.channel = channel
            createSessionChannel(on: channel)
        }
    }

    private func createSessionChannel(on channel: Channel) {
        let feedSender = feedSender
        let term = term
        let environment = environment
        let initialWindowSize = initialWindowSize
        let reportError: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleError(error)
            }
        }

        channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = SSHShellChannelHandler(
                        feedSender: feedSender,
                        term: term,
                        environment: environment,
                        initialWindowSize: initialWindowSize
                    )
                    let sync = childChannel.pipeline.syncOperations
                    try sync.addHandler(handler)
                    try sync.addHandler(SSHErrorHandler(onError: reportError))
                }
            }

            return promise.futureResult
        }.whenComplete { [weak self] result in
            Task { @MainActor [weak self] in
                self?.sessionChannelCompleted(result)
            }
        }
    }

    private func sessionChannelCompleted(_ result: Result<Channel, Error>) {
        switch result {
        case .failure(let error):
            handleError(error)
        case .success(let childChannel):
            guard channel != nil else {
                childChannel.close(promise: nil)
                return
            }
            sessionChannel = childChannel
            resize(cols: initialWindowSize.cols, rows: initialWindowSize.rows)
        }
    }

    private func handleError(_ error: Error) {
        feedSender.feed(text: "[ERROR] \(error)\n")
    }
}

public class SshTerminalView: TerminalView, TerminalViewDelegate {
    private var sshConnection: SSHConnection?
    private var configuredInfo: SSHConnectionInfo?
    
    public override init (frame: CGRect)
    {
        super.init (frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(connectionInfo: SSHConnectionInfo) {
        if configuredInfo == connectionInfo {
            return
        }

        configuredInfo = connectionInfo
        let previousConnection = sshConnection
        sshConnection = nil
        previousConnection?.disconnect()
        startConnection(connectionInfo: connectionInfo)
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    /// Permanently stops the SSH session. The UI owner must call this before
    /// it releases the terminal view.
    func disconnectSSH() {
        configuredInfo = nil
        let connection = sshConnection
        sshConnection = nil
        connection?.disconnect()
    }

    private func startConnection(connectionInfo: SSHConnectionInfo) {
        let dimensions = terminalDimensions
        let cols = dimensions.cols > 0 ? dimensions.cols : 80
        let rows = dimensions.rows > 0 ? dimensions.rows : 24

        let connection = SSHConnection(
            feedSender: feedSender,
            host: connectionInfo.host,
            port: connectionInfo.port,
            username: connectionInfo.username,
            password: connectionInfo.password,
            term: connectionInfo.term,
            environment: connectionInfo.environment,
            initialWindowSize: (cols: cols, rows: rows)
        )
        sshConnection = connection
        connection.connect()
    }

    // TerminalViewDelegate conformance
    public func scrolled(source: TerminalView, position: Double) {
        //
    }
    
    public func setTerminalTitle(source: TerminalView, title: String) {
        //
    }
    
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sshConnection?.resize(cols: newCols, rows: newRows)
    }
    
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sshConnection?.send(Data(data))
    }
    
    public func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String (bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
    
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        
    }

    public func requestOpenLink (source: TerminalView, link: String, params: [String:String])
    {
        if let url = URL(string: link) {
            UIApplication.shared.open (url)
        }
    }
    
    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
        // nothing
    }
    

}
