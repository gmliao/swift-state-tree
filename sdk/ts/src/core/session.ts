import { StateTreeRuntime } from './runtime'
import { ConnectionClosedError } from './errors'

export type SessionMode = 'live' | 'replay'

export interface SessionRuntime {
  connect(url: string): Promise<void>
  disconnect(): void
  readonly connected: boolean
}

export interface SessionConnectSpec {
  url: string
  onBeforeDisconnect?: (runtime: SessionRuntime) => void | Promise<void>
  onAfterConnect?: (runtime: SessionRuntime) => void | Promise<void>
}

export interface SessionModeError {
  operation: 'connectLive' | 'switchToReplay' | 'switchToLive'
  targetMode: SessionMode
  cause: unknown
}

export interface StateTreeSessionOptions {
  runtime?: SessionRuntime
  live: SessionConnectSpec
  replay: SessionConnectSpec
  initialMode?: SessionMode
  onError?: (error: SessionModeError) => void
}

export class StateTreeSession {
  private readonly runtimeImpl: SessionRuntime
  private liveSpec: SessionConnectSpec
  private replaySpec: SessionConnectSpec
  private onError?: (error: SessionModeError) => void

  mode: SessionMode
  /** Mode switches run one at a time, in call order (#143). */
  private switchChain: Promise<void> = Promise.resolve()
  /** Bumped by `disconnect()`: a running switch stops at its next await, queued ones never start. */
  private generation = 0

  constructor(options: StateTreeSessionOptions) {
    this.runtimeImpl = options.runtime ?? new StateTreeRuntime()
    this.liveSpec = options.live
    this.replaySpec = options.replay
    this.mode = options.initialMode ?? 'live'
    this.onError = options.onError
  }

  get runtime(): SessionRuntime {
    return this.runtimeImpl
  }

  async connectLive(): Promise<void> {
    await this.reconnect('connectLive', 'live', this.liveSpec)
  }

  async switchToReplay(): Promise<void> {
    await this.reconnect('switchToReplay', 'replay', this.replaySpec)
  }

  async switchToLive(): Promise<void> {
    await this.reconnect('switchToLive', 'live', this.liveSpec)
  }

  private getSpec(mode: SessionMode): SessionConnectSpec {
    return mode === 'live' ? this.liveSpec : this.replaySpec
  }

  /**
   * Disconnects and cancels mode switches (#143): a switch in progress rejects with
   * `ConnectionClosedError` (`kind: 'disconnect'`) at its next await, and so does every switch
   * queued behind it. The mode is left as it was.
   */
  disconnect(): void {
    this.generation += 1
    this.runtimeImpl.disconnect()
  }

  private reconnect(
    operation: SessionModeError['operation'],
    targetMode: SessionMode,
    targetSpec: SessionConnectSpec
  ): Promise<void> {
    const generation = this.generation
    const run = this.switchChain.then(() => this.runReconnect(operation, targetMode, targetSpec, generation))
    this.switchChain = run.catch(() => {})
    return run
  }

  private async runReconnect(
    operation: SessionModeError['operation'],
    targetMode: SessionMode,
    targetSpec: SessionConnectSpec,
    generation: number
  ): Promise<void> {
    const ensureCurrent = () => {
      if (generation !== this.generation) throw new ConnectionClosedError('disconnect')
    }
    ensureCurrent()
    try {
      if (this.runtimeImpl.connected) {
        const currentSpec = this.getSpec(this.mode)
        await currentSpec.onBeforeDisconnect?.(this.runtimeImpl)
        ensureCurrent()
        this.runtimeImpl.disconnect()
      }

      await this.runtimeImpl.connect(targetSpec.url)
      ensureCurrent()
      await targetSpec.onAfterConnect?.(this.runtimeImpl)
      ensureCurrent()
      this.mode = targetMode
    } catch (cause) {
      // Cancelled by disconnect(): it already closed the connection, and it is not a switch error
      if (generation !== this.generation) {
        if (this.runtimeImpl.connected) this.runtimeImpl.disconnect()
        throw cause instanceof ConnectionClosedError ? cause : new ConnectionClosedError('disconnect')
      }
      // connect() succeeded but onAfterConnect threw — clean up the dangling connection
      if (this.runtimeImpl.connected) {
        this.runtimeImpl.disconnect()
      }
      this.onError?.({
        operation,
        targetMode,
        cause
      })
      throw cause
    }
  }
}
