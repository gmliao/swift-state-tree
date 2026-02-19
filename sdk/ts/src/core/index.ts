export * from './deterministic-math'
export * from './runtime'
export * from './session'
export { StateTreeView, type ViewOptions } from './view'
export { createWebSocket, registerWebSocketFactory, type WebSocketConnection, type WebSocketFactory, WebSocketReadyState } from './websocket'
export { BrowserWebSocket } from './websocket-browser'
export { NodeWebSocket, NodeWebSocketFactory } from './websocket-node'
export * from './logger'
export * from './protocol'
export type {
  StatePatch,
  StateUpdate,
  StateSnapshot,
  StateUpdateEncoding,
  StateUpdateDecoding,
  TransportEncodingConfig
} from '../types/transport'

/**
 * Type-safe subscriptions for Map properties in state.
 * Returned by StateTreeView.createMapSubscriptions().
 */
export interface MapSubscriptions<T> {
  /**
   * Subscribe to item additions.
   * Automatically handles both patch-based updates and snapshot late-join scenarios.
   * @param callback - Called when a new item is added to the map
   * @returns Unsubscribe function
   */
  onAdd(callback: (key: string, value: T) => void): () => void
  /**
   * Subscribe to item removals.
   * @param callback - Called when an item is removed from the map
   * @returns Unsubscribe function
   */
  onRemove(callback: (key: string) => void): () => void
}
