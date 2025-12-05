<template>
  <v-card-text>
    <v-alert
      v-if="!schema"
      type="info"
      density="compact"
      class="mb-4"
    >
      請先上傳並解析 Schema
    </v-alert>

    <div v-else>
      <v-select
        v-if="showLandSelector"
        v-model="selectedLand"
        :items="landItems"
        label="選擇 Land"
        variant="outlined"
        density="compact"
        class="mb-4"
      ></v-select>

      <v-text-field
        v-model="eventName"
        label="Event 名稱"
        variant="outlined"
        density="compact"
        placeholder="chat"
        class="mb-4"
        hint="例如: chat, ping"
      ></v-text-field>

      <v-textarea
        v-model="eventPayload"
        label="Event Payload (JSON)"
        rows="4"
        variant="outlined"
        density="compact"
        placeholder='{"message": "Hello"} 或直接輸入字串'
        class="mb-4"
      ></v-textarea>

      <v-btn
        color="primary"
        block
        @click="handleSend"
        :disabled="!connected || !eventName || !activeLand"
      >
        <v-icon icon="mdi-send" class="mr-2"></v-icon>
        發送 Event
      </v-btn>
    </div>
  </v-card-text>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import type { Schema } from '@/types'

const props = defineProps<{
  schema: Schema | null
  connected: boolean
}>()

const emit = defineEmits<{
  'send-event': [eventName: string, payload: any, landID: string]
}>()

const selectedLand = ref<string>('')
const eventName = ref('')
const eventPayload = ref('')

const landKeys = computed(() => {
  if (!props.schema) return []
  return Object.keys(props.schema.lands)
})

const showLandSelector = computed(() => landKeys.value.length > 1)

const landItems = computed(() => {
  if (!props.schema) return []
  return landKeys.value.map(key => ({
    title: key,
    value: key
  }))
})

const activeLand = computed(() => {
  return selectedLand.value || landKeys.value[0] || ''
})

const handleSend = () => {
  const landID = activeLand.value
  if (!landID || !eventName.value) return

  let payload: any = null
  
  if (eventPayload.value.trim()) {
    try {
      // Try to parse as JSON
      payload = JSON.parse(eventPayload.value)
    } catch {
      // If not valid JSON, use as string
      payload = eventPayload.value
    }
  }

  emit('send-event', eventName.value, payload, landID)
  eventPayload.value = ''
}
</script>
