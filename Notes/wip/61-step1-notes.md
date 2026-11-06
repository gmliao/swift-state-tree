# #61 step 1 notes

- swift-nio 2.90.1 has `ChannelOptions.bufferedWritableBytes` (Int).
  - Supported by NIOPosix SocketChannel / BaseStreamSocketChannel (the real buffered bytes in ChannelOutboundBuffer) and by EmbeddedChannel / NIOAsyncTestingChannel.
  - Embedded counts only `pendingOutboundBuffer`, i.e. writes not yet flushed. So in tests, flushed data reads as 0, and unflushed writes are needed to see a backlog.
- The WebSocketSessionHandler is ChannelInboundHandler only; send is `writeAndFlush(promise: nil)` in `sendOnLoop`. Writability: override `channelWritabilityChanged(context:)`, read `context.channel.isWritable`, record episode start/end (NIODeadline), count and longest.
- Read pending bytes from `context.channel.getOption(.bufferedWritableBytes)` on the loop (the sync options view `syncOptions?.getOption` avoids a future).
- Where to sample: on each send (max), or periodically. The profiler wants max per window.
- The child channel has no writeBufferWaterMark option set, so defaults are 32 KiB low / 64 KiB high.
- Drain-task defects are in WebSocketTransport.swift:
  - line ~18: the drain `break` without finishing the stream;
  - handleConnection ~185: overwrites sessionQueues[sessionID] without finishing the old one.
