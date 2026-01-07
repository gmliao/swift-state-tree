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
        v-if="activeLand && availableActions.length > 0"
        v-model="selectedAction"
        :items="availableActions"
        label="選擇 Action"
        variant="outlined"
        density="compact"
        class="mb-4"
      ></v-select>

      <v-alert
        v-if="activeLand && availableActions.length === 0"
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
            class="mb-4"
          >
            <!-- Deterministic Math Types: Special Input UI -->
            <template v-if="field.isDeterministicMath">
              <v-card variant="outlined" class="pa-3">
                <v-card-subtitle class="pa-0 mb-2">
                  {{ field.name }} <span v-if="field.required" class="text-error">*</span>
                  <v-chip size="x-small" color="primary" variant="flat" class="ml-2">
                    {{ field.mathType }}
                  </v-chip>
                </v-card-subtitle>
                
                <!-- Position2 / IVec2 / Velocity2 / Acceleration2: x, y inputs -->
                <template v-if="field.mathType === 'Position2' || field.mathType === 'IVec2' || field.mathType === 'Velocity2' || field.mathType === 'Acceleration2'">
                  <v-row dense>
                    <v-col cols="6">
                      <v-text-field
                        v-model.number="payloadModel[`${field.name}_x`]"
                        label="X"
                        type="number"
                        variant="outlined"
                        density="compact"
                        hint="浮點數（會自動轉換為固定點整數）"
                        persistent-hint
                      ></v-text-field>
                    </v-col>
                    <v-col cols="6">
                      <v-text-field
                        v-model.number="payloadModel[`${field.name}_y`]"
                        label="Y"
                        type="number"
                        variant="outlined"
                        density="compact"
                        hint="浮點數（會自動轉換為固定點整數）"
                        persistent-hint
                      ></v-text-field>
                    </v-col>
                  </v-row>
                  <template v-if="field.mathType === 'Position2'">
                    <v-alert type="info" density="compact" class="mt-2">
                      Position2 需要 v 屬性（IVec2），將自動構建
                    </v-alert>
                  </template>
                </template>
                
                <!-- Angle: degrees input -->
                <template v-else-if="field.mathType === 'Angle'">
                  <v-text-field
                    v-model.number="payloadModel[`${field.name}_degrees`]"
                    label="Degrees"
                    type="number"
                    variant="outlined"
                    density="compact"
                    hint="角度（浮點數，會自動轉換為固定點整數）"
                    persistent-hint
                  ></v-text-field>
                </template>
              </v-card>
            </template>
            
            <!-- Regular Types: Standard Input -->
            <v-text-field
              v-else
              v-model="payloadModel[field.name]"
              :label="field.required ? `${field.name} *` : field.name"
              :hint="`type: ${field.type}${field.$ref ? ` (${field.$ref.replace('#/defs/', '')})` : ''}`"
              variant="outlined"
              density="compact"
              persistent-hint
            ></v-text-field>
          </div>
        </div>

        <!-- Show manual input only when we have no schema at all for the selected action -->
        <v-textarea
          v-else-if="!selectedActionSchema"
          v-model="actionPayload"
          label="Action Payload (無 schema 時手動輸入 JSON)"
          rows="6"
          variant="outlined"
          density="compact"
          placeholder='{"name": "Player1"}'
          class="mb-4"
        ></v-textarea>
        
        <!-- Show info when action has schema but no fields (empty object) -->
        <v-alert
          v-else-if="selectedActionSchema && actionFields.length === 0"
          type="info"
          density="compact"
          class="mb-4"
        >
          此 Action 不需要參數（空對象）
        </v-alert>
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
import { IVec2, Position2, Velocity2, Acceleration2, Angle } from '@swiftstatetree/sdk/core'

interface ActionField {
  name: string
  type: string
  required: boolean
  isDeterministicMath?: boolean
  mathType?: 'Position2' | 'IVec2' | 'Angle' | 'Velocity2' | 'Acceleration2'
  $ref?: string // For $ref types
}

const props = defineProps<{
  schema: Schema | null
  connected: boolean
  selectedLandID?: string
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

// Use external selectedLandID if provided, otherwise fallback to first land
const activeLand = computed(() => {
  if (props.selectedLandID) {
    return props.selectedLandID
  }
  return landKeys.value[0] || ''
})

// Land selector is hidden since we use external selection
// const showLandSelector = computed(() => false) // Not used anymore

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

// Helper to check if a $ref is a deterministic math type
const isDeterministicMathType = (ref: string | undefined): { isMath: boolean; mathType?: string } => {
  if (!ref) return { isMath: false }
  const refName = ref.replace('#/defs/', '').replace('defs/', '')
  const mathTypes = ['Position2', 'IVec2', 'Angle', 'Velocity2', 'Acceleration2', 'Semantic2']
  if (mathTypes.includes(refName)) {
    return { isMath: true, mathType: refName }
  }
  return { isMath: false }
}

const actionFields = computed<ActionField[]>(() => {
  const schema = selectedActionSchema.value
  if (!schema || schema.type !== 'object' || !schema.properties) return []

  const requiredSet = new Set(schema.required ?? [])

  return Object.entries(schema.properties).map(([name, prop]) => {
    // Check for $ref (deterministic math types)
    const ref = prop.$ref
    const mathCheck = isDeterministicMathType(ref)
    
    return {
      name,
      type: prop.type ?? (ref ? 'object' : 'string'),
      required: requiredSet.has(name),
      isDeterministicMath: mathCheck.isMath,
      mathType: mathCheck.mathType as any,
      $ref: ref
    }
  })
})

watch(
  () => [selectedAction.value, activeLand.value, props.schema],
  () => {
    const fields = actionFields.value
    const nextPayload: Record<string, any> = {}

    for (const field of fields) {
      if (field.isDeterministicMath) {
        // Initialize deterministic math fields
        if (field.mathType === 'Position2' || field.mathType === 'IVec2' || field.mathType === 'Velocity2' || field.mathType === 'Acceleration2') {
          nextPayload[`${field.name}_x`] = ''
          nextPayload[`${field.name}_y`] = ''
        } else if (field.mathType === 'Angle') {
          nextPayload[`${field.name}_degrees`] = ''
        }
      } else {
        nextPayload[field.name] = ''
      }
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
    // Check required fields
    if (field.required) {
      if (field.isDeterministicMath) {
        // For deterministic math types, check specific fields
        if (field.mathType === 'Position2' || field.mathType === 'IVec2' || field.mathType === 'Velocity2' || field.mathType === 'Acceleration2') {
          const x = payloadModel.value[`${field.name}_x`]
          const y = payloadModel.value[`${field.name}_y`]
          if (x === '' || x === null || x === undefined || y === '' || y === null || y === undefined) {
            errors.push(`${field.name} 是必填欄位（需要 x 和 y）`)
          }
        } else if (field.mathType === 'Angle') {
          const degrees = payloadModel.value[`${field.name}_degrees`]
          if (degrees === '' || degrees === null || degrees === undefined) {
            errors.push(`${field.name} 是必填欄位（需要 degrees）`)
          }
        }
      } else {
        const value = payloadModel.value[field.name]
        if (value === '' || value === null || value === undefined) {
          errors.push(`${field.name} 是必填欄位`)
        }
      }
    }
    
    // Check type validation (only if value is provided)
    if (!field.isDeterministicMath) {
      const value = payloadModel.value[field.name]
      if (value !== '' && value !== null && value !== undefined) {
        const validation = validatePayloadValue(value, field.type)
        if (!validation.valid) {
          errors.push(`${field.name}: ${validation.error}`)
        }
      }
    } else {
      // Validate deterministic math types
      if (field.mathType === 'Position2' || field.mathType === 'IVec2' || field.mathType === 'Velocity2' || field.mathType === 'Acceleration2') {
        const x = payloadModel.value[`${field.name}_x`]
        const y = payloadModel.value[`${field.name}_y`]
        if (x !== '' && x !== null && x !== undefined) {
          const numX = parseFloat(String(x))
          if (isNaN(numX)) {
            errors.push(`${field.name}.x 必須是數字`)
          }
        }
        if (y !== '' && y !== null && y !== undefined) {
          const numY = parseFloat(String(y))
          if (isNaN(numY)) {
            errors.push(`${field.name}.y 必須是數字`)
          }
        }
      } else if (field.mathType === 'Angle') {
        const degrees = payloadModel.value[`${field.name}_degrees`]
        if (degrees !== '' && degrees !== null && degrees !== undefined) {
          const numDegrees = parseFloat(String(degrees))
          if (isNaN(numDegrees)) {
            errors.push(`${field.name}.degrees 必須是數字`)
          }
        }
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
        if (field.isDeterministicMath) {
          // Build deterministic math class instances (not plain objects)
          if (field.mathType === 'Position2' || field.mathType === 'IVec2' || field.mathType === 'Velocity2' || field.mathType === 'Acceleration2') {
            const x = payloadModel.value[`${field.name}_x`]
            const y = payloadModel.value[`${field.name}_y`]
            if (x !== '' && x !== null && x !== undefined && y !== '' && y !== null && y !== undefined) {
              const xFloat = parseFloat(String(x))
              const yFloat = parseFloat(String(y))
              
              if (field.mathType === 'Position2') {
                // Position2 needs IVec2 instance wrapped in Semantic2
                const vec = new IVec2(xFloat, yFloat, false) // false = from float
                payload[field.name] = new Position2(vec)
              } else if (field.mathType === 'Velocity2') {
                const vec = new IVec2(xFloat, yFloat, false)
                payload[field.name] = new Velocity2(vec)
              } else if (field.mathType === 'Acceleration2') {
                const vec = new IVec2(xFloat, yFloat, false)
                payload[field.name] = new Acceleration2(vec)
              } else if (field.mathType === 'IVec2') {
                // IVec2 is just the vector itself
                payload[field.name] = new IVec2(xFloat, yFloat, false)
              }
            }
          } else if (field.mathType === 'Angle') {
            const degrees = payloadModel.value[`${field.name}_degrees`]
            if (degrees !== '' && degrees !== null && degrees !== undefined) {
              const degreesFloat = parseFloat(String(degrees))
              payload[field.name] = new Angle(degreesFloat, false) // false = from float
            }
          }
        } else {
          // Regular fields
          const rawValue = payloadModel.value[field.name]
          // Include all values (required fields are guaranteed to be present)
          if (rawValue !== '' && rawValue !== null && rawValue !== undefined) {
            payload[field.name] = convertPayloadValue(rawValue, field.type)
          }
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
