<template>
  <v-card-text class="event-panel">
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
        v-if="activeLand && availableEvents.length === 0"
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
          v-else-if="showManualPayload"
          v-model="eventPayload"
          label="Event Payload (無 schema 時手動輸入)"
          rows="4"
          variant="outlined"
          density="compact"
          placeholder='{"message": "Hello"} 或直接輸入字串'
          class="mb-4"
        ></v-textarea>
      </div>

      <v-alert
        v-if="selectedEvent && validationErrors.length > 0"
        type="warning"
        density="compact"
        class="mb-4"
      >
        <div v-for="(error, index) in validationErrors" :key="index">
          {{ error }}
        </div>
      </v-alert>

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
  selectedLandID?: string
}>()

const emit = defineEmits<{
  'send-event': [eventName: string, payload: any, landID: string]
}>()

const selectedEvent = ref<string>('')
const eventPayload = ref('')
const payloadModel = ref<Record<string, any>>({})

const landKeys = computed(() => {
  if (!props.schema) return []
  return Object.keys(props.schema.lands)
})

// Use external selectedLandID if provided, otherwise fallback to first land
const activeLand = computed(() => {
  if (props.selectedLandID) {
    return props.selectedLandID
  }
  return landKeys.value[0] || ''
})

// Hide land selector since we use external selection
const showLandSelector = computed(() => false)

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

const showManualPayload = computed(() => {
  // Show manual input only when we have no schema at all for the selected event
  return Boolean(selectedEvent.value) && !selectedEventSchema.value
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

// Convert form values to correct types based on schema
const convertPayloadValue = (value: any, fieldType: string): any => {
  if (value === '' || value === null || value === undefined) {
    return value
  }
  
  switch (fieldType) {
    case 'integer':
      const intValue = parseInt(String(value), 10)
      return isNaN(intValue) ? value : intValue
    case 'number':
      const numValue = parseFloat(String(value))
      return isNaN(numValue) ? value : numValue
    case 'boolean':
      if (typeof value === 'string') {
        return value.toLowerCase() === 'true' || value === '1'
      }
      return Boolean(value)
    case 'string':
    default:
      return String(value)
  }
}

// Validate payload value type
const validatePayloadValue = (value: any, fieldType: string): { valid: boolean; error?: string } => {
  if (value === '' || value === null || value === undefined) {
    return { valid: true } // Empty values are handled separately for required check
  }
  
  switch (fieldType) {
    case 'integer':
      const intValue = parseInt(String(value), 10)
      if (isNaN(intValue)) {
        return { valid: false, error: '必須是整數' }
      }
      return { valid: true }
    case 'number':
      const numValue = parseFloat(String(value))
      if (isNaN(numValue)) {
        return { valid: false, error: '必須是數字' }
      }
      return { valid: true }
    case 'boolean':
      // Boolean is always valid after conversion
      return { valid: true }
    case 'string':
    default:
      return { valid: true }
  }
}

// Validate all required fields are present and types are correct
const validationErrors = computed(() => {
  const errors: string[] = []
  
  // Only validate if we have schema-based fields (not manual JSON input)
  if (!selectedEvent.value || eventFields.value.length === 0) {
    return errors
  }
  
  for (const field of eventFields.value) {
    const value = payloadModel.value[field.name]
    
    // Check required fields
    if (field.required) {
      if (value === '' || value === null || value === undefined) {
        errors.push(`${field.name} 是必填欄位`)
        continue
      }
    }
    
    // Check type validation (only if value is provided)
    if (value !== '' && value !== null && value !== undefined) {
      const validation = validatePayloadValue(value, field.type)
      if (!validation.valid) {
        errors.push(`${field.name}: ${validation.error}`)
      }
    }
  }
  
  return errors
})

// Check if payload is valid (all required fields filled and types correct)
const isPayloadValid = computed(() => {
  // For manual JSON input, always allow (user is responsible for correctness)
  if (showManualPayload.value) {
    return true
  }
  return validationErrors.value.length === 0
})

const handleSend = () => {
  const landID = activeLand.value
  if (!landID || !selectedEvent.value) return

  let payload: any = null

  if (selectedEventSchema.value && eventFields.value.length === 0) {
    // Schema exists but has no fields (empty object) => send empty object
    payload = {}
  } else if (selectedEvent.value && eventFields.value.length > 0) {
    // Convert form values to correct types based on schema
    payload = {}
    for (const field of eventFields.value) {
      const rawValue = payloadModel.value[field.name]
      // Include all values (required fields are guaranteed to be present)
      if (rawValue !== '' && rawValue !== null && rawValue !== undefined) {
        payload[field.name] = convertPayloadValue(rawValue, field.type)
      }
    }
    
    // Ensure all required fields are included
    for (const field of eventFields.value) {
      if (field.required && !(field.name in payload)) {
        // This shouldn't happen if validation passed, but add as safety check
        throw new Error(`必填欄位 ${field.name} 缺失`)
      }
    }
  } else if (eventPayload.value.trim()) {
    try {
      // Try to parse as JSON
      payload = JSON.parse(eventPayload.value)
    } catch {
      // If not valid JSON, use as string
      payload = eventPayload.value
    }
  }

  // Prefer using the schema ref's def name (e.g. "ClickCookieEvent") as
  // the event type identifier sent to the server, so that it matches the
  // Swift AnyClientEvent type name and EventRegistry naming.
  let finalEventName = selectedEvent.value
  const ref = selectedEventSchemaRef.value
  if (ref) {
    const match = ref.match(/#\/defs\/(.+)$/)
    if (match && match[1]) {
      finalEventName = match[1]
    }
  }

  emit('send-event', finalEventName, payload, landID)
}
</script>

<style scoped>
.event-panel {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding-bottom: 16px;
}
</style>
