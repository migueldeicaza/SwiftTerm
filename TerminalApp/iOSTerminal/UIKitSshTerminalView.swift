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

struct SSHConnectionInfo: Equatable {
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

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class SSHShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private weak var terminalView: SshTerminalView?
    private let term: String
    private let environment: [String: String]
    private let initialWindowSize: (cols: Int, rows: Int)

    init(
        terminalView: SshTerminalView?,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.terminalView = terminalView
        self.term = term
        self.environment = environment
        self.initialWindowSize = initialWindowSize
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
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
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.feed(byteArray: chunk)
            }
            next = end
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.feed(text: "\n[SSH] Session exited with status \(status.exitStatus)\n")
            }
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            DispatchQueue.main.async { [weak terminalView] in
                terminalView?.feed(text: "\n[SSH] Session closed: \(signal.signalName)\n")
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class SSHConnection {
    private weak var terminalView: SshTerminalView?
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
        terminalView: SshTerminalView,
        host: String,
        port: Int,
        username: String,
        password: String,
        term: String,
        environment: [String: String],
        initialWindowSize: (cols: Int, rows: Int)
    ) {
        self.terminalView = terminalView
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

        let serverAuthDelegate = AcceptAllHostKeysDelegate()
        let userAuthDelegate = SimplePasswordDelegate(username: username, password: password)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else { return }
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: userAuthDelegate,
                                serverAuthDelegate: serverAuthDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHErrorHandler { [weak self] error in
                            self?.handleError(error)
                        }
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleError(error)
                self.shutdownGroup()
            case .success(let channel):
                self.channel = channel
                self.createSessionChannel(on: channel)
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
        if let channel, let group {
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.shutdownGroup()
            }
            channel.close(promise: nil)
        } else {
            shutdownGroup()
        }
    }

    private func createSessionChannel(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleError(error)
            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, channelType in
                    guard let self else {
                        return channel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                    }

                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                    }

                    return childChannel.eventLoop.makeCompletedFuture {
                        let handler = SSHShellChannelHandler(
                            terminalView: self.terminalView,
                            term: self.term,
                            environment: self.environment,
                            initialWindowSize: self.initialWindowSize
                        )
                        let sync = childChannel.pipeline.syncOperations
                        try sync.addHandler(handler)
                        try sync.addHandler(
                            SSHErrorHandler { [weak self] error in
                                self?.handleError(error)
                            }
                        )
                    }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.handleError(error)
                    case .success(let childChannel):
                        self.sessionChannel = childChannel
                        self.sendInitialResize()
                    }
                }
            }
        }
    }

    private func sendInitialResize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let terminal = self.terminalView?.getTerminal() else { return }
            self.resize(cols: terminal.cols, rows: terminal.rows)
        }
    }

    private func handleError(_ error: Error) {
        DispatchQueue.main.async { [weak terminalView] in
            terminalView?.feed(text: "[ERROR] \(error)\n")
        }
    }

    private func shutdownGroup() {
        if let group = group {
            self.group = nil
            group.shutdownGracefully { _ in }
        }
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

    deinit {
        sshConnection?.disconnect()
    }

    func configure(connectionInfo: SSHConnectionInfo) {
        if configuredInfo == connectionInfo {
            return
        }

        configuredInfo = connectionInfo
        sshConnection?.disconnect()
        startConnection(connectionInfo: connectionInfo)
        DispatchQueue.main.async { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    private func startConnection(connectionInfo: SSHConnectionInfo) {
        let terminal = getTerminal()
        let cols = terminal.cols > 0 ? terminal.cols : 80
        let rows = terminal.rows > 0 ? terminal.rows : 24

        let connection = SSHConnection(
            terminalView: self,
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
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    UIApplication.shared.open (nested)
                }
            }
        }
    }
    
    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
        // nothing
    }
    

}
