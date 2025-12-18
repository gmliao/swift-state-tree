<script setup lang="ts">
import { ref, watch } from 'vue'

const props = defineProps<{
  isConnecting: boolean
  isConnected: boolean
  isJoined: boolean
  lastError: string | null
}>()

const emit = defineEmits<{
  (e: 'connect', payload: { wsUrl: string; playerName?: string }): void
  (e: 'disconnect'): void
}>()

const schemaUrl = ref('http://localhost:8080/schema')
const wsUrl = ref('ws://localhost:8080/game')
const playerName = ref('')

watch(
  () => props.isConnected,
  (connected) => {
    if (!connected) {
      // keep wsUrl but clear transient state if needed in future
    }
  }
)

function handleConnect() {
  emit('connect', {
    wsUrl: wsUrl.value,
    playerName: playerName.value.trim() || undefined
  })
}

function handleDisconnect() {
  emit('disconnect')
}
</script>

<template>
  <v-card>
    <v-card-title>
      <v-icon icon="mdi-web" class="mr-2" />
      連線設定
    </v-card-title>
    <v-card-text>
      <v-text-field
        v-model="schemaUrl"
        label="Schema URL"
        prepend-icon="mdi-link"
        variant="outlined"
        density="compact"
        readonly
        class="mb-3"
        hint="目前使用此 URL 執行 codegen"
        persistent-hint
      />

      <v-text-field
        v-model="wsUrl"
        label="WebSocket URL"
        prepend-icon="mdi-link-variant"
        variant="outlined"
        density="comfortable"
        class="mb-3"
      />

      <v-text-field
        v-model="playerName"
        label="玩家名稱（可選）"
        prepend-icon="mdi-account"
        variant="outlined"
        density="comfortable"
        class="mb-4"
        hint="若不填，伺服器會依 JWT 或 Guest 規則決定名稱"
        persistent-hint
      />

      <v-btn
        color="success"
        block
        class="mb-2"
        :loading="isConnecting"
        :disabled="!wsUrl || isConnected"
        @click="handleConnect"
      >
        <v-icon icon="mdi-link" class="mr-2" />
        連線並加入遊戲
      </v-btn>

      <v-btn
        color="error"
        block
        class="mb-2"
        :disabled="!isConnected"
        @click="handleDisconnect"
      >
        <v-icon icon="mdi-link-off" class="mr-2" />
        斷線
      </v-btn>

      <v-alert
        v-if="isConnected && !isJoined"
        type="info"
        density="compact"
        variant="tonal"
        class="mb-2"
      >
        已連線，正在等待加入遊戲...
      </v-alert>

      <v-alert
        v-if="isJoined"
        type="success"
        density="compact"
        variant="tonal"
        class="mb-2"
      >
        已加入 CookieGame 房間，可以開始點餅乾了！
      </v-alert>

      <v-alert
        v-if="lastError"
        type="error"
        density="compact"
        variant="tonal"
        class="mt-2"
      >
        {{ lastError }}
      </v-alert>
    </v-card-text>
  </v-card>
</template>

