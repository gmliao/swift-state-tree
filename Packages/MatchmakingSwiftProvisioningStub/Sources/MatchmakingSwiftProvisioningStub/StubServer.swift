import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

struct StubServer {
    func run(port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPHandler())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let host = "127.0.0.1"

        // Use async get() extension as direct await is not available without stricter concurrency checks
        let channel = try await bootstrap.bind(host: host, port: port).get()

        print("🚀 Stub Server started on http://\(host):\(port)")
        print("Routes:")
        print("  GET /health")
        print("  POST /v1/provisioning/allocate")

        // Use async get() extension
        try await channel.closeFuture.get()
        try await group.shutdownGracefully()
    }
}

final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
// ... rest is same

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)

        switch part {
        case .head(let head):
            self.requestHead = head
            self.requestBody = nil // Reset body

        case .body(var buffer):
            if self.requestBody == nil {
                self.requestBody = buffer
            } else {
                self.requestBody!.writeBuffer(&buffer)
            }

        case .end:
            guard let head = self.requestHead else { return }
            self.handleRequest(context: context, head: head, body: self.requestBody)
        }
    }

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead, body: ByteBuffer?) {
        let uri = head.uri

        if head.method == .GET && uri == "/health" {
            self.respond(context: context, status: .ok, body: "OK")
        } else if head.method == .POST && uri == "/v1/provisioning/allocate" {
            // In a real implementation, we would parse the body to get group info.
            // For the stub, we return a fixed deterministic response.
            
            let response = AllocationResponse(
                serverId: "stub-server-1",
                landId: "standard:stub-room-1",
                connectUrl: "ws://127.0.0.1:8080/game/standard?landId=standard:stub-room-1"
            )

            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(response)
                var buffer = context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                self.respond(context: context, status: .ok, body: buffer, contentType: "application/json")
            } catch {
                self.respond(context: context, status: .internalServerError, body: "Encoding error")
            }
        } else {
            self.respond(context: context, status: .notFound, body: "Not Found")
        }
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        self.respond(context: context, status: status, body: buffer)
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, body: ByteBuffer, contentType: String = "text/plain") {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: "\(body.readableBytes)")

        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: status, headers: headers)

        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
