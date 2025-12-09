import { defineStore } from "pinia";
import { computed, ref, shallowRef } from "vue";
import { DemoGameLandView } from "@/generated/land-views";
import type { ChatMessageEvent, DemoGameState, PongEvent, StateDiff } from "@/generated";
import type { LandViewRuntime } from "@sdk-runtime/LandViewRuntime";
import { LandViewConnector } from "@sdk-runtime/LandViewConnector";
import { generateJWT } from "@/utils/jwt";

type Cleanup = () => void;

export const useGameStore = defineStore("game", () => {
  // Default to the server's configured WebSocket path (/game).
  const wsUrl = ref("ws://localhost:8080/game");
  const useJwt = ref(false);
  const jwtSecret = ref("demo-secret-key-change-in-production");
  const jwtPlayerID = ref("");
  const jwtToken = ref("");
  const jwtError = ref<string | null>(null);

  const effectiveWsUrl = computed(() => {
    if (!useJwt.value || !jwtToken.value) return wsUrl.value;
    const sep = wsUrl.value.includes("?") ? "&" : "?";
    return `${wsUrl.value}${sep}token=${encodeURIComponent(jwtToken.value)}`;
  });
  const isConnected = ref(false);
  const latestSnapshot = ref<DemoGameState | null>(null);
  const lastDiff = ref<StateDiff | null>(null);
  const logs = ref<string[]>([]);

  const landView = shallowRef<DemoGameLandView | null>(null);
  const connector = shallowRef<LandViewConnector | null>(null);
  const unsubs = shallowRef<Cleanup[]>([]);

  const addLog = (msg: string) => {
    logs.value.unshift(`${new Date().toISOString()} ${msg}`);
    if (logs.value.length > 200) logs.value.pop();
  };

  const disconnect = () => {
    unsubs.value.forEach((f) => f());
    unsubs.value = [];
    connector.value?.disconnect();
    connector.value = null;
    landView.value = null;
    isConnected.value = false;
  };

  const connect = () => {
    disconnect();
    const conn = new LandViewConnector();
    connector.value = conn;

    const offOpen = conn.onOpen(() => {
      addLog("WebSocket connected");
      isConnected.value = true;
    });
    const offClose = conn.onClose(() => {
      addLog("WebSocket closed");
      isConnected.value = false;
      landView.value = null;
    });
    const offError = conn.onError((err: unknown) => addLog(`WebSocket error: ${String(err)}`));

    conn.register(
      "demo-game",
      (ws: WebSocket) =>
        new DemoGameLandView(ws, "demo-game", (msg, meta) =>
          addLog(`[runtime] ${msg} ${meta ? JSON.stringify(meta) : ""}`)
        ) as unknown as LandViewRuntime<any, any, any, any, any, any, any, any, any>,
      (runtime) => {
        const view = runtime as unknown as DemoGameLandView;
        landView.value = view;

        const offSnapshot = view.state.onSnapshot((s: DemoGameState) => {
          latestSnapshot.value = structuredClone(s);
        });
        const offDiff = view.state.onDiff((d: StateDiff) => {
          lastDiff.value = structuredClone(d);
          const current = view.state.getLatest();
          latestSnapshot.value = current ? structuredClone(current) : null;
        });
        const offPong = view.serverEvents.onPong((_p: PongEvent) => addLog("Pong received"));
        const offChat = view.serverEvents.onChatMessage((p: ChatMessageEvent) =>
          addLog(`Chat from ${p.from}: ${p.message}`)
        );
        unsubs.value = [offSnapshot, offDiff, offPong, offChat];

        // Auto-join the land when runtime is ready.
        const joinRequestID = view.join();
        addLog(`Join requested (${joinRequestID})`);
      }
    );

    conn.connect(effectiveWsUrl.value);
    unsubs.value.push(offOpen, offClose, offError);
  };

  const generateToken = async () => {
    jwtError.value = null;
    try {
      if (!jwtSecret.value || !jwtPlayerID.value) {
        throw new Error("Secret and Player ID are required");
      }
      jwtToken.value = await generateJWT(jwtSecret.value, { playerID: jwtPlayerID.value });
      useJwt.value = true;
    } catch (err) {
      jwtError.value = err instanceof Error ? err.message : String(err);
      jwtToken.value = "";
    }
  };

  const sendChat = (message: string) => {
    landView.value?.clientEvents.chat({ message });
  };

  const sendPing = () => {
    landView.value?.clientEvents.ping({});
  };

  const addGold = (amount: number) => {
    landView.value?.actions.addGold({ amount });
  };

  return {
    wsUrl,
    isConnected,
    latestSnapshot,
    lastDiff,
    logs,
    useJwt,
    jwtSecret,
    jwtPlayerID,
    jwtToken,
    jwtError,
    effectiveWsUrl,
    generateToken,
    connect,
    disconnect,
    sendChat,
    sendPing,
    addGold,
  };
});
