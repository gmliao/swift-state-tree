/**
 * Built-in system-level server events shared across all lands.
 * These events are provided by the SwiftStateTree runtime (e.g. reevaluation/replay)
 * and are not part of per-land schema. The SDK decodes them automatically so that
 * replay and verification flows work without requiring schema/codegen for these types.
 *
 * Field order must match Swift payload order (e.g. @Payload struct property order).
 */

/** Field order for ReplayTickEvent (Swift: ReplayTickEvent). Used for array payload decoding. */
export const REPLAY_TICK_FIELD_ORDER = ['tickId', 'isMatch', 'expectedHash', 'actualHash'] as const

/**
 * Built-in server event type names. When the view receives these events and they
 * are not in the land schema, we do not log "No schema found" and return payload as-is.
 */
export const BUILTIN_SERVER_EVENT_NAMES = new Set<string>(['ReplayTick'])

/**
 * Map of built-in server event type name -> field order for array payload decoding.
 * Used as fallback in protocol when eventFieldOrder (from schema) does not contain the event.
 */
export const BUILTIN_SERVER_EVENT_FIELD_ORDER = new Map<string, readonly string[]>([
  ['ReplayTick', REPLAY_TICK_FIELD_ORDER]
])
