import Hummingbird
import HummingbirdWebSocket

/// Accept only the configured loopback authority and its matching HTTP origin.
/// A missing Origin is rejected because this endpoint starts a local process.
func isAllowedWebSocketOrigin(host: String?, origin: String?, port: Int) -> Bool {
    guard (1...65535).contains(port), let host, let origin else { return false }
    let authority = host.lowercased()
    let allowed = ["127.0.0.1:\(port)", "localhost:\(port)"]
    let normalized: String
    if allowed.contains(authority) {
        normalized = port == 80 ? String(authority.dropLast(3)) : authority
    } else if port == 80 && (authority == "127.0.0.1" || authority == "localhost") {
        normalized = authority
    } else {
        return false
    }
    let suppliedOrigin = origin.lowercased()
    return suppliedOrigin == "http://\(normalized)"
        || (port == 80 && suppliedOrigin == "http://\(normalized):80")
}

/// Count active PTY sessions after a WebSocket upgrade succeeds. Failed
/// handshakes cannot retain a slot because they never acquire one.
actor WebTerminalSessionLimit {
    private var active = 0
    private let maximum: Int

    init(maximum: Int = 8) { self.maximum = maximum }

    func acquire() -> Bool {
        guard active < maximum else { return false }
        active += 1
        return true
    }

    func release() {
        if active > 0 { active -= 1 }
    }
}

func makeHTTPRouter(publicDirectory: String, assetDirectory: String) -> Router<BasicRequestContext> {
    let routes = Router()
    routes.middlewares.add(
        FileMiddleware(publicDirectory, searchForIndexHtml: true)
    )
    routes.middlewares.add(
        FileMiddleware(assetDirectory, urlBasePath: "/assets")
            .withAdditionalMediaType(
                .init(type: .application, subType: "wasm"),
                mappedToFileExtension: "wasm"
            )
    )
    return routes
}

func runServer(configuration: ServerConfiguration) async throws {
    let routes = makeHTTPRouter(
        publicDirectory: configuration.publicDirectory,
        assetDirectory: configuration.assetDirectory
    )
    let sessionLimit = WebTerminalSessionLimit()
    let sockets = Router(context: BasicWebSocketRequestContext.self)
    sockets.ws("/terminal") { request, _ in
        // HTTPTypes stores the HTTP/1 Host field in the request authority.
        let host = request.head.authority
        guard isAllowedWebSocketOrigin(
            host: host,
            origin: request.headers[.origin],
            port: configuration.port
        ) else {
            return .dontUpgrade
        }
        return .upgrade()
    } onUpgrade: { incoming, outgoing, _ in
        guard await sessionLimit.acquire() else {
            try await outgoing.close(.policyViolation, reason: "The server has eight active terminal sessions.")
            return
        }
        await TerminalSession.run(
            incoming: incoming,
            outgoing: outgoing,
            configuration: configuration
        )
        await sessionLimit.release()
    }

    let webSocketConfiguration = HTTP1WebSocketUpgradeChannel.Configuration(
        ws: .init(maxFrameSize: 64 * 1024, validateUTF8: true)
    )
    let application = Application(
        router: routes,
        server: .http1WebSocketUpgrade(
            webSocketRouter: sockets,
            configuration: webSocketConfiguration
        ),
        configuration: .init(
            address: .hostname("127.0.0.1", port: configuration.port)
        )
    )
    try await application.runService()
}
