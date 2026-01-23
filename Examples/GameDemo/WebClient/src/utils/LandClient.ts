import { StateTreeRuntime, StateTreeView } from "@swiftstatetree/sdk/core";

export class LandClient {
  private runtime: StateTreeRuntime;
  private view: StateTreeView | null = null;
  private landID: string;
  private wsUrl: string;

  constructor(wsUrl: string, landID: string) {
    this.wsUrl = wsUrl;
    this.landID = landID;

    // Create runtime with browser-compatible configuration
    this.runtime = new StateTreeRuntime({
      transportEncoding: {
        message: "json",
        stateUpdate: "opcodeJsonArray",
        stateUpdateDecoding: "auto",
      },
    });
  }

  async connect(): Promise<void> {
    try {
      await this.runtime.connect(this.wsUrl);

      // Fetch schema explicitly
      const schemaResponse = await fetch("http://localhost:8080/schema");
      if (!schemaResponse.ok) {
        throw new Error(`Failed to fetch schema: ${schemaResponse.statusText}`);
      }
      const schema = await schemaResponse.json();

      this.view = this.runtime.createView(this.landID, {
        schema: schema,
        // We will inject onStateUpdate later via property if needed
      });

      const joinResult = await this.view.join();

      if (!joinResult.success) {
        throw new Error(`Join failed: ${joinResult.reason}`);
      }

      console.log(`✅ LandClient connected to ${this.landID}`);
    } catch (error) {
      console.error("LandClient connect error:", error);
      throw error;
    }
  }

  onStateUpdate(callback: (state: any) => void) {
    // Re-create view with new callback if needed, or better yet, simple hack:
    // We can't easily swap the callback in current SDK ViewOptions design without re-creation or using a wrapper.
    // Let's use a wrapper property on the class if we want to change it.

    // Actually, looking at SDK ViewOptions source: onStateUpdate is passed in constructor.
    // We should allow setting it before connect, or hack injection.

    if (this.view) {
      // Direct property injection if public/accessible? No, it's private usually or via options.
      // But we can overwrite the internal reference if we typecast to any
      (this.view as any).onStateUpdate = callback;
    }
  }

  onEvent(eventName: string, callback: (payload: any) => void) {
    if (this.view) {
      this.view.onServerEvent(eventName, callback);
    }
  }

  async sendAction(actionName: string, payload: any): Promise<void> {
    if (!this.view) throw new Error("Not connected");

    await this.view.sendAction(actionName, payload);
  }

  disconnect() {
    this.runtime.disconnect();
  }
}
