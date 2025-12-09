/**
 * Manages a single WebSocket connection and multiple LandViewRuntime instances.
 * Register factories per land key; connector will create/dispose runtimes on connect/disconnect.
 */
import { LandViewRuntime, LandViewRuntimeOptions } from "./LandViewRuntime";

type RuntimeFactory = (ws: WebSocket) => LandViewRuntime<any, any, any, any, any, any, any, any, any>;
type RuntimeReadyHandler = (runtime: RuntimeFactoryReturn) => void;
type RuntimeFactoryReturn = ReturnType<RuntimeFactory>;

export class LandViewConnector {
    private ws: WebSocket | null = null;
    private factories = new Map<string, RuntimeFactory>();
    private runtimes = new Map<string, RuntimeFactoryReturn>();
    private readyHandlers = new Map<string, RuntimeReadyHandler[]>();

    private onOpenHandlers: Array<() => void> = [];
    private onCloseHandlers: Array<() => void> = [];
    private onErrorHandlers: Array<(err: unknown) => void> = [];

    getWebSocket(): WebSocket | null {
        return this.ws;
    }

    register(key: string, factory: RuntimeFactory, onReady?: RuntimeReadyHandler): () => void {
        this.factories.set(key, factory);
        if (onReady) {
            if (!this.readyHandlers.has(key)) this.readyHandlers.set(key, []);
            this.readyHandlers.get(key)!.push(onReady);
        }
        // If already connected, create immediately
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            const runtime = factory(this.ws);
            this.runtimes.set(key, runtime);
            this.notifyReady(key, runtime);
        }
        return () => this.unregister(key);
    }

    getRuntime<T = RuntimeFactoryReturn>(key: string): T | null {
        return (this.runtimes.get(key) as T | undefined) ?? null;
    }

    connect(url: string) {
        this.disconnect();
        this.ws = new WebSocket(url);
        // Ensure we receive ArrayBuffer instead of Blob for binary frames.
        this.ws.binaryType = "arraybuffer";
        this.ws.addEventListener("open", this.handleOpen);
        this.ws.addEventListener("close", this.handleClose);
        this.ws.addEventListener("error", this.handleError);
    }

    disconnect() {
        // Dispose runtimes
        for (const runtime of this.runtimes.values()) {
            runtime.dispose();
        }
        this.runtimes.clear();
        if (this.ws) {
            this.ws.removeEventListener("open", this.handleOpen);
            this.ws.removeEventListener("close", this.handleClose);
            this.ws.removeEventListener("error", this.handleError);
            this.ws.close();
            this.ws = null;
        }
    }

    onOpen(handler: () => void): () => void {
        this.onOpenHandlers.push(handler);
        return () => this.removeHandler(this.onOpenHandlers, handler);
    }

    onClose(handler: () => void): () => void {
        this.onCloseHandlers.push(handler);
        return () => this.removeHandler(this.onCloseHandlers, handler);
    }

    onError(handler: (err: unknown) => void): () => void {
        this.onErrorHandlers.push(handler);
        return () => this.removeHandler(this.onErrorHandlers, handler);
    }

    private unregister(key: string) {
        const runtime = this.runtimes.get(key);
        if (runtime) {
            runtime.dispose();
            this.runtimes.delete(key);
        }
        this.factories.delete(key);
        this.readyHandlers.delete(key);
    }

    private handleOpen = () => {
        if (!this.ws) return;
        // Create runtimes for all factories
        for (const [key, factory] of this.factories.entries()) {
            const runtime = factory(this.ws);
            this.runtimes.set(key, runtime);
            this.notifyReady(key, runtime);
        }
        this.onOpenHandlers.forEach((h) => h());
    };

    private handleClose = () => {
        for (const runtime of this.runtimes.values()) {
            runtime.dispose();
        }
        this.runtimes.clear();
        this.onCloseHandlers.forEach((h) => h());
    };

    private handleError = (err: unknown) => {
        this.onErrorHandlers.forEach((h) => h(err));
    };

    private notifyReady(key: string, runtime: RuntimeFactoryReturn) {
        const handlers = this.readyHandlers.get(key);
        if (handlers) handlers.forEach((h) => h(runtime));
    }

    private removeHandler<T>(arr: T[], handler: T) {
        const idx = arr.indexOf(handler);
        if (idx >= 0) arr.splice(idx, 1);
    }
}
