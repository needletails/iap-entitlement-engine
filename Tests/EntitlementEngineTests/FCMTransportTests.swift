import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing
@testable import IAPEntitlementEngine

/// Answers every POST with a fixed status, and records what arrived on the wire.
private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct Received: Sendable {
        var method = ""
        var authorization = ""
        var body = ""
    }

    private let received: Mutex<Received>.Box
    private let status: HTTPResponseStatus
    private var current = Received()

    init(received: Mutex<Received>.Box, status: HTTPResponseStatus) {
        self.received = received
        self.status = status
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            current.method = "\(head.method)"
            current.authorization = head.headers.first(name: "Authorization") ?? ""
        case .body(let buffer):
            current.body += String(buffer: buffer)
        case .end:
            received.mutex.withLock { $0 = current }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "2")
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "{}")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private extension Mutex where Value: Sendable {
    final class Box: Sendable {
        let mutex: Mutex<Value>

        init(_ value: Value) {
            mutex = Mutex(value)
        }
    }
}

@Suite("AsyncHTTPClient transport")
struct AsyncHTTPClientTransportTests {
    @Test func sendsARealHTTPRequestAndReadsTheResponse() async throws {
        let received = Mutex<EchoHandler.Received>.Box(.init())
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(EchoHandler(received: received, status: .created))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(server.localAddress?.port)

        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        let response: FCMTransportResponse
        do {
            response = try await AsyncHTTPClientFCMTransport(client: client).post(
                url: "http://127.0.0.1:\(port)/send",
                headers: ["Authorization": "Bearer t"],
                body: Data("hello".utf8))
        } catch {
            try await client.shutdown()
            try await server.close()
            throw error
        }
        try await client.shutdown()
        try await server.close()

        #expect(response.status == 201)
        #expect(response.body == Data("{}".utf8))
        let wire = received.mutex.withLock { $0 }
        #expect(wire.method == "POST")
        #expect(wire.authorization == "Bearer t")
        #expect(wire.body == "hello")
    }
}
