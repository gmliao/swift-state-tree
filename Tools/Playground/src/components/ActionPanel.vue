<template>
  <v-card-text class="action-panel">
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

      <div v-if="selectedAction">
        <div
          v-if="actionFields.length > 0"
          class="mb-4"
        >
          <div
            v-for="field in actionFields"
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
          v-model="actionPayload"
          label="Action Payload (JSON)"
          rows="6"
          variant="outlined"
          density="compact"
          placeholder='{"name": "Player1"}'
          class="mb-4"
        ></v-textarea>
      </div>

      <v-alert
        v-if="selectedAction && validationErrors.length > 0"
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
        :disabled="!connected || !selectedAction || !activeLand || !isPayloadValid"
        class="mb-4"
      >
        <v-icon icon="mdi-send" class="mr-2"></v-icon>
        發送 Action
      </v-btn>
      
      <!-- Action Result Display -->
      <v-alert
        v-if="lastActionResult"
        :type="lastActionResult.success ? 'success' : 'error'"
        density="compact"
        class="mb-2"
        closable
        @click:close="lastActionResult = null"
      >
        <div class="d-flex align-center">
          <v-icon :icon="lastActionResult.success ? 'mdi-check-circle' : 'mdi-alert-circle'" class="mr-2"></v-icon>
          <div style="flex: 1;">
            <div class="font-weight-bold mb-1">
              {{ lastActionResult.success ? 'Action 成功' : 'Action 失敗' }}
            </div>
            <div class="text-caption">
              <strong>Action:</strong> {{ lastActionResult.actionName }}
            </div>
            <div v-if="lastActionResult.response" class="mt-2">
              <strong>回應:</strong>
              <pre class="response-json">{{ JSON.stringify(lastActionResult.response, null, 2) }}</pre>
            </div>
            <div v-if="lastActionResult.error" class="mt-2 text-error">
              <strong>錯誤:</strong> {{ lastActionResult.error }}
            </div>
          </div>
        </div>
      </v-alert>
    </div>
  </v-card-text>
</template>

<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import type { Schema } from '@/types'

interface ActionField {
  name: string
  type: string
  required: boolean
}

const props = defineProps<{
  schema: Schema | null
  connected: boolean
  actionResults?: Array<{
    actionName: string
    success: boolean
    response?: any
    error?: string
    timestamp: Date
  }>
}>()

const emit = defineEmits<{
  'send-action': [actionName: string, payload: any, landID: string]
}>()

const selectedLand = ref<string>('')
const selectedAction = ref<string>('')
const actionPayload = ref('{}')
const payloadModel = ref<Record<string, any>>({})
const lastActionResult = ref<{
  actionName: string
  success: boolean
  response?: any
  error?: string
} | null>(null)

// Watch for action results
watch(() => props.actionResults, (results) => {
  if (results && results.length > 0) {
    // Find the latest result for the currently selected action
    const matchingResults = results.filter(r => r.actionName === selectedAction.value)
    if (matchingResults.length > 0) {
      const latest = matchingResults[matchingResults.length - 1]
      lastActionResult.value = {
        actionName: latest.actionName,
        success: latest.success,
        response: latest.response,
        error: latest.error
      }
    }
  }
}, { deep: true, immediate: true })

// Clear result when action changes
watch(selectedAction, () => {
  lastActionResult.value = null
})

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

const selectedActionSchemaRef = computed(() => {
  const landID = activeLand.value
  if (!props.schema || !landID || !selectedAction.value) return null

  const land = props.schema.lands[landID]
  const action = land?.actions?.[selectedAction.value]
  return action?.$ref ?? null
})

const selectedActionSchema = computed(() => {
  if (!props.schema) return null
  const ref = selectedActionSchemaRef.value
  if (!ref) return null

  const match = ref.match(/#\/defs\/(.+)$/)
  if (!match) return null

  const defName = match[1]
  return props.schema.defs[defName] ?? null
})

const actionFields = computed<ActionField[]>(() => {
  const schema = selectedActionSchema.value
  if (!schema || schema.type !== 'object' || !schema.properties) return []

  const requiredSet = new Set(schema.required ?? [])

  return Object.entries(schema.properties).map(([name, prop]) => ({
    name,
    type: prop.type ?? 'string',
    required: requiredSet.has(name)
  }))
})

watch(
  () => [selectedAction.value, activeLand.value, props.schema],
  () => {
    const fields = actionFields.value
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
  
  if (!selectedAction.value || actionFields.value.length === 0) {
    return errors
  }
  
  for (const field of actionFields.value) {
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
  return validationErrors.value.length === 0
})

const handleSend = () => {
  const landID = activeLand.value
  if (!landID || !selectedAction.value) return

  // Double-check validation before sending
  if (!isPayloadValid.value) {
    return
  }

  try {
    let payload: any

    if (actionFields.value.length > 0) {
      // Convert form values to correct types based on schema
      payload = {}
      for (const field of actionFields.value) {
        const rawValue = payloadModel.value[field.name]
        // Include all values (required fields are guaranteed to be present)
        if (rawValue !== '' && rawValue !== null && rawValue !== undefined) {
          payload[field.name] = convertPayloadValue(rawValue, field.type)
        }
      }
      
      // Ensure all required fields are included
      for (const field of actionFields.value) {
        if (field.required && !(field.name in payload)) {
          // This shouldn't happen if validation passed, but add as safety check
          throw new Error(`必填欄位 ${field.name} 缺失`)
        }
      }
    } else {
      // No fields in schema, send empty object (no need to input JSON)
      payload = {}
    }

    emit('send-action', selectedAction.value, payload, landID)
  } catch (err) {
    alert(`發送失敗: ${err}`)
  }
}
</script>

<style scoped>
.action-panel {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding-bottom: 16px;
}

.response-json {
  margin-top: 8px;
  padding: 12px;
  background-color: #f5f5f5;
  border-radius: 4px;
  border: 1px solid #e0e0e0;
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
  font-size: 12px;
  line-height: 1.5;
  max-height: 300px;
  overflow-y: auto;
  white-space: pre-wrap;
  word-wrap: break-word;
  color: #212121;
}
</style>
