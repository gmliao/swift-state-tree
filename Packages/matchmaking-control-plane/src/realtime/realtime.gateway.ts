import {
  WebSocketGateway,
  WebSocketServer,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { Server } from 'ws';
import { IncomingMessage } from 'http';

/** Maps ticketId -> Set of WebSocket clients subscribed to that ticket. */
const ticketSubscriptions = new Map<string, Set<WebSocket>>();

@WebSocketGateway({ path: '/realtime' })
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server!: Server;

  handleConnection(client: WebSocket, request: IncomingMessage) {
    const url = new URL(request.url ?? '', `http://${request.headers.host}`);
    const ticketId = url.searchParams.get('ticketId');
    if (!ticketId) {
      client.close(4000, 'Missing ticketId query param');
      return;
    }
    let set = ticketSubscriptions.get(ticketId);
    if (!set) {
      set = new Set();
      ticketSubscriptions.set(ticketId, set);
    }
    set.add(client);
    (client as unknown as { _ticketId: string })._ticketId = ticketId;
  }

  handleDisconnect(client: WebSocket) {
    const ticketId = (client as unknown as { _ticketId?: string })._ticketId;
    if (ticketId) {
      const set = ticketSubscriptions.get(ticketId);
      if (set) {
        set.delete(client);
        if (set.size === 0) ticketSubscriptions.delete(ticketId);
      }
    }
  }

  /** Push match.assigned to all clients subscribed to this ticketId. */
  pushMatchAssigned(ticketId: string, envelope: object): void {
    const set = ticketSubscriptions.get(ticketId);
    if (!set) return;
    const msg = JSON.stringify(envelope);
    for (const ws of set) {
      if (ws.readyState === 1) ws.send(msg);
    }
  }
}
