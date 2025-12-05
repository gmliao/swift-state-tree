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

      <v-select
        v-if="activeLand && availableActions.length > 0"
        v-model="selectedAction"
        :items="availableActions"
        label="選擇 Action"
        variant="outlined"
        density="compact"
        class="mb-4"
      ></v-select>

      <v-alert
        v-if="selectedLand && availableActions.length === 0"
        type="warning"
        density="compact"
        class="mb-4"
      >
        此 Land 沒有定義 Actions
      </v-alert>

      <v-textarea
        v-if="selectedAction"
        v-model="actionPayload"
        label="Action Payload (JSON)"
        rows="6"
        variant="outlined"
        density="compact"
        placeholder='{"name": "Player1"}'
        class="mb-4"
      ></v-textarea>

      <v-btn
        color="primary"
        block
        @click="handleSend"
        :disabled="!connected || !selectedAction || !activeLand"
      >
        <v-icon icon="mdi-send" class="mr-2"></v-icon>
        發送 Action
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
  'send-action': [actionName: string, payload: any, landID: string]
}>()

const selectedLand = ref<string>('')
const selectedAction = ref<string>('')
const actionPayload = ref('{}')

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

const availableActions = computed(() => {
  const landID = activeLand.value
  if (!props.schema || !landID) return []
  
  const land = props.schema.lands[landID]
  if (!land?.actions) return []
  
  return Object.keys(land.actions).map(key => ({
    title: key,
    value: key
  }))
})

const handleSend = () => {
  const landID = activeLand.value
  if (!landID || !selectedAction.value) return

  try {
    const payload = actionPayload.value ? JSON.parse(actionPayload.value) : {}
    emit('send-action', selectedAction.value, payload, landID)
    actionPayload.value = '{}'
  } catch (err) {
    alert(`Payload JSON 格式錯誤: ${err}`)
  }
}
</script>
