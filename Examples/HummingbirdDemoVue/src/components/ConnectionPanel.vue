<template>
  <v-card>
    <v-card-title>Connection</v-card-title>
    <v-card-text class="d-flex flex-column gap-4">
      <div class="d-flex gap-2">
        <v-text-field
          v-model="store.wsUrl"
          label="WebSocket URL"
          variant="outlined"
          density="comfortable"
        />
        <v-btn color="primary" @click="store.connect" :disabled="store.isConnected">
          Connect
        </v-btn>
        <v-btn color="error" variant="tonal" @click="store.disconnect" :disabled="!store.isConnected">
          Disconnect
        </v-btn>
      </div>

      <v-expand-transition>
        <div>
          <v-checkbox
            v-model="store.useJwt"
            label="Use JWT"
            density="compact"
            hide-details
          />
          <div class="d-flex gap-2 mt-2">
            <v-text-field
              v-model="store.jwtSecret"
              label="JWT Secret"
              variant="outlined"
              density="comfortable"
              :disabled="!store.useJwt"
            />
            <v-text-field
              v-model="store.jwtPlayerID"
              label="Player ID"
              variant="outlined"
              density="comfortable"
              :disabled="!store.useJwt"
            />
            <v-btn color="secondary" variant="tonal" :disabled="!store.useJwt" @click="store.generateToken">
              Generate Token
            </v-btn>
          </div>
          <v-alert v-if="store.jwtToken" type="success" density="comfortable" class="mt-2">
            Token set ({{ store.jwtToken.substring(0, 24) }}...)
          </v-alert>
          <v-alert v-if="store.jwtError" type="error" density="comfortable" class="mt-2">
            {{ store.jwtError }}
          </v-alert>
        </div>
      </v-expand-transition>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import { useGameStore } from "../stores/game";
const store = useGameStore();
</script>
