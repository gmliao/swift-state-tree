<template>
  <v-card>
    <v-card-title>
      <v-icon icon="mdi-information" class="mr-2"></v-icon>
      Land 詳情
      <v-spacer></v-spacer>
      <v-btn
        icon="mdi-close"
        variant="text"
        size="small"
        @click="$emit('close')"
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

      <div v-if="loading && !landInfo" class="text-center py-8">
        <v-progress-circular indeterminate color="primary"></v-progress-circular>
        <div class="mt-4 text-caption">載入中...</div>
      </div>

      <div v-else-if="landInfo">
        <v-list>
          <v-list-item>
            <v-list-item-title>Land ID</v-list-item-title>
            <v-list-item-subtitle class="font-mono">{{ landInfo.landID }}</v-list-item-subtitle>
          </v-list-item>

          <v-list-item>
            <v-list-item-title>玩家數量</v-list-item-title>
            <v-list-item-subtitle>
              <v-chip color="primary" size="small">{{ landInfo.playerCount }}</v-chip>
            </v-list-item-subtitle>
          </v-list-item>

          <v-list-item>
            <v-list-item-title>建立時間</v-list-item-title>
            <v-list-item-subtitle>{{ formatDate(landInfo.createdAt) }}</v-list-item-subtitle>
          </v-list-item>

          <v-list-item>
            <v-list-item-title>最後活動時間</v-list-item-title>
            <v-list-item-subtitle>{{ formatDate(landInfo.lastActivityAt) }}</v-list-item-subtitle>
          </v-list-item>
        </v-list>

        <v-divider class="my-4"></v-divider>

        <v-card-actions>
          <v-spacer></v-spacer>
          <v-btn
            color="error"
            variant="outlined"
            @click="$emit('delete-land', landInfo.landID)"
          >
            <v-icon icon="mdi-delete" class="mr-2"></v-icon>
            刪除 Land
          </v-btn>
        </v-card-actions>
      </div>

      <v-alert v-else type="warning" density="compact">
        Land 不存在
      </v-alert>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import type { LandInfo } from '../types/admin'

defineProps<{
  landInfo: LandInfo | null
  loading: boolean
  error: string | null
  landID?: string
}>()

defineEmits<{
  'close': []
  'delete-land': [landID: string]
  'clear-error': []
}>()

function formatDate(dateString: string): string {
  try {
    const date = new Date(dateString)
    return date.toLocaleString('zh-TW')
  } catch {
    return dateString
  }
}
</script>
