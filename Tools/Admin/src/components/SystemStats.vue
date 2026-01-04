<template>
  <v-card>
    <v-card-title>
      <v-icon icon="mdi-chart-box" class="mr-2"></v-icon>
      系統統計
      <v-spacer></v-spacer>
      <v-btn
        icon="mdi-refresh"
        variant="text"
        size="small"
        @click="$emit('refresh')"
        :loading="loading"
      ></v-btn>
    </v-card-title>
    <v-card-text>
      <v-alert
        v-if="error"
        type="error"
        density="compact"
        class="mb-4"
        closable
        @click:close="$emit('clear-error')"
      >
        {{ error }}
      </v-alert>

      <div v-if="loading && !stats" class="text-center py-8">
        <v-progress-circular indeterminate color="primary"></v-progress-circular>
        <div class="mt-4 text-caption">載入中...</div>
      </div>

      <v-list v-else-if="stats">
        <v-list-item>
          <template v-slot:prepend>
            <v-icon icon="mdi-map-marker-multiple" color="primary" size="large"></v-icon>
          </template>
          <v-list-item-title>總 Lands 數</v-list-item-title>
          <v-list-item-subtitle>
            <v-chip color="primary" size="large" class="mt-2">
              {{ stats.totalLands }}
            </v-chip>
          </v-list-item-subtitle>
        </v-list-item>

        <v-divider class="my-2"></v-divider>

        <v-list-item>
          <template v-slot:prepend>
            <v-icon icon="mdi-account-group" color="secondary" size="large"></v-icon>
          </template>
          <v-list-item-title>總玩家數</v-list-item-title>
          <v-list-item-subtitle>
            <v-chip color="secondary" size="large" class="mt-2">
              {{ stats.totalPlayers }}
            </v-chip>
          </v-list-item-subtitle>
        </v-list-item>
      </v-list>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import type { SystemStats } from '../types/admin'

defineProps<{
  stats: SystemStats | null
  loading: boolean
  error: string | null
}>()

defineEmits<{
  'refresh': []
  'clear-error': []
}>()
</script>
