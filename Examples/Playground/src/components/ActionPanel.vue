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
}>()

const emit = defineEmits<{
  'send-action': [actionName: string, payload: any, landID: string]
}>()

const selectedLand = ref<string>('')
const selectedAction = ref<string>('')
const actionPayload = ref('{}')
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

const handleSend = () => {
  const landID = activeLand.value
  if (!landID || !selectedAction.value) return

  try {
    let payload: any

    if (actionFields.value.length > 0) {
      payload = { ...payloadModel.value }
    } else {
      payload = actionPayload.value ? JSON.parse(actionPayload.value) : {}
    }

    emit('send-action', selectedAction.value, payload, landID)

    if (actionFields.value.length > 0) {
      const nextPayload: Record<string, any> = {}
      for (const field of actionFields.value) {
        nextPayload[field.name] = ''
      }
      payloadModel.value = nextPayload
    } else {
      actionPayload.value = '{}'
    }
  } catch (err) {
    alert(`Payload JSON 格式錯誤: ${err}`)
  }
}
</script>
