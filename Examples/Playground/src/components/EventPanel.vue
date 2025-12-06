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
        v-if="activeLand && availableEvents.length > 0"
        v-model="selectedEvent"
        :items="availableEvents"
        label="選擇 Event"
        variant="outlined"
        density="compact"
        class="mb-4"
      ></v-select>

      <v-alert
        v-if="selectedLand && availableEvents.length === 0"
        type="warning"
        density="compact"
        class="mb-4"
      >
        此 Land 沒有定義 Client Events（客戶端可發送的事件）
      </v-alert>

      <div v-if="selectedEvent">
        <div
          v-if="eventFields.length > 0"
          class="mb-4"
        >
          <div
            v-for="field in eventFields"
            :key="field.name"
            class="mb-2"
          >
            <v-text-field
              v-model="payloadModel[field.name]"
              :label="field.required ? `${field.name} *` : field.name"
              :hint="`type: ${field.type}`"
              variant="outlined"
              density="compact"
              persistent-hint
            ></v-text-field>
          </div>
        </div>

        <v-textarea
          v-else
          v-model="eventPayload"
          label="Event Payload (JSON 或直接輸入字符串)"
          rows="4"
          variant="outlined"
          density="compact"
          placeholder='{"message": "Hello"} 或直接輸入字串'
          class="mb-4"
        ></v-textarea>
      </div>

      <v-textarea
        v-else
        v-model="eventPayload"
        label="Event Payload (JSON 或直接輸入字符串)"
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
        :disabled="!connected || !selectedEvent || !activeLand"
      >
        <v-icon icon="mdi-send" class="mr-2"></v-icon>
        發送 EVENT
      </v-btn>
    </div>
  </v-card-text>
</template>

<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import type { Schema } from '@/types'

interface EventField {
  name: string
  type: string
  required: boolean
}

const props = defineProps<{
  schema: Schema | null
  connected: boolean
}>()

const emit = defineEmits<{
  'send-event': [eventName: string, payload: any, landID: string]
}>()

const selectedLand = ref<string>('')
const selectedEvent = ref<string>('')
const eventName = ref('')
const eventPayload = ref('')
const payloadModel = ref<Record<string, any>>({})

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

const availableEvents = computed(() => {
  const landID = activeLand.value
  if (!props.schema || !landID) return []
  
  const land = props.schema.lands[landID]
  // Only show client events (events that client can send to server)
  // Server events (land.events) are sent FROM server TO client
  if (!land?.clientEvents) return []
  
  return Object.keys(land.clientEvents).map(key => ({
    title: key,
    value: key
  }))
})

const selectedEventSchemaRef = computed(() => {
  const landID = activeLand.value
  if (!props.schema || !landID || !selectedEvent.value) return null

  const land = props.schema.lands[landID]
  // Use clientEvents (events that client can send)
  const event = land?.clientEvents?.[selectedEvent.value]
  return event?.$ref ?? null
})

const selectedEventSchema = computed(() => {
  if (!props.schema) return null
  const ref = selectedEventSchemaRef.value
  if (!ref) return null

  const match = ref.match(/#\/defs\/(.+)$/)
  if (!match) return null

  const defName = match[1]
  return props.schema.defs[defName] ?? null
})

const eventFields = computed<EventField[]>(() => {
  const schema = selectedEventSchema.value
  if (!schema || schema.type !== 'object' || !schema.properties) return []

  const requiredSet = new Set(schema.required ?? [])

  return Object.entries(schema.properties).map(([name, prop]) => ({
    name,
    type: prop.type ?? 'string',
    required: requiredSet.has(name)
  }))
})

watch(
  () => [selectedEvent.value, activeLand.value, props.schema],
  () => {
    const fields = eventFields.value
    const nextPayload: Record<string, any> = {}

    for (const field of fields) {
      nextPayload[field.name] = ''
    }

    payloadModel.value = nextPayload
  }
)

const handleSend = () => {
  const landID = activeLand.value
  const finalEventName = selectedEvent.value
  if (!landID || !finalEventName) return

  let payload: any = null

  if (selectedEvent.value && eventFields.value.length > 0) {
    // Use generated fields
    payload = { ...payloadModel.value }
  } else if (eventPayload.value.trim()) {
    try {
      // Try to parse as JSON
      payload = JSON.parse(eventPayload.value)
    } catch {
      // If not valid JSON, use as string
      payload = eventPayload.value
    }
  }

  emit('send-event', finalEventName, payload, landID)
  
  // Reset form
  if (selectedEvent.value && eventFields.value.length > 0) {
    const nextPayload: Record<string, any> = {}
    for (const field of eventFields.value) {
      nextPayload[field.name] = ''
    }
    payloadModel.value = nextPayload
  } else {
    eventPayload.value = ''
  }
}
</script>
