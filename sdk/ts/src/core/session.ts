import { StateTreeRuntime } from './runtime'

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

  private async reconnect(
    operation: SessionModeError['operation'],
    targetMode: SessionMode,
    targetSpec: SessionConnectSpec
  ): Promise<void> {
    try {
      if (this.runtimeImpl.connected) {
        const currentSpec = this.getSpec(this.mode)
        await currentSpec.onBeforeDisconnect?.(this.runtimeImpl)
        this.runtimeImpl.disconnect()
      }

      await this.runtimeImpl.connect(targetSpec.url)
      await targetSpec.onAfterConnect?.(this.runtimeImpl)
      this.mode = targetMode
    } catch (cause) {
      this.onError?.({
        operation,
        targetMode,
        cause
      })
      throw cause
    }
  }
}
