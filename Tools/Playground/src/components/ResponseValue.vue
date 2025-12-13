<template>
  <div class="response-value" :class="valueClass">
    <!-- Primitive types -->
    <template v-if="isPrimitive">
      <span class="value-primitive" :class="primitiveClass">
        {{ formatPrimitive(value) }}
      </span>
    </template>
    
    <!-- Array type -->
    <template v-else-if="isArray">
      <div class="value-array">
        <div class="array-header">
          <v-icon icon="mdi-format-list-bulleted" size="small" class="mr-1"></v-icon>
          <span class="array-label">陣列 ({{ arrayLength }})</span>
        </div>
        <v-list density="compact" class="array-items">
          <v-list-item
            v-for="(item, index) in value"
            :key="index"
            class="array-item"
          >
            <template v-slot:prepend>
              <span class="array-index">{{ index }}:</span>
            </template>
            <ResponseValue 
              :value="item" 
              :schema="itemSchema"
              :defs="defs"
              :path="`${path}[${index}]`"
            />
          </v-list-item>
          <v-list-item v-if="arrayLength === 0" class="text-caption text-medium-emphasis">
            (空陣列)
          </v-list-item>
        </v-list>
      </div>
    </template>
    
    <!-- Object type -->
    <template v-else-if="isObject">
      <div class="value-object">
        <v-expansion-panels v-if="objectKeys.length > 0" variant="accordion" density="compact">
          <v-expansion-panel
            v-for="key in objectKeys"
            :key="key"
            :title="key"
          >
            <template v-slot:text>
              <ResponseValue 
                :value="value[key]" 
                :schema="getPropertySchema(key)"
                :defs="defs"
                :path="path ? `${path}.${key}` : key"
              />
            </template>
          </v-expansion-panel>
        </v-expansion-panels>
        <div v-else class="text-caption text-medium-emphasis">
          (空物件)
        </div>
      </div>
    </template>
    
    <!-- Null/undefined -->
    <template v-else>
      <span class="value-null text-medium-emphasis">null</span>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import type { SchemaDef } from '@/types'

const props = defineProps<{
  value: any
  schema: SchemaDef | null
  defs?: Record<string, SchemaDef>
  path?: string
}>()

const isPrimitive = computed(() => {
  const val = props.value
  return val === null || 
         val === undefined || 
         typeof val === 'string' || 
         typeof val === 'number' || 
         typeof val === 'boolean'
})

const isArray = computed(() => {
  return Array.isArray(props.value)
})

const isObject = computed(() => {
  return props.value !== null && 
         typeof props.value === 'object' && 
         !Array.isArray(props.value)
})

const valueClass = computed(() => {
  if (isArray.value) return 'value-type-array'
  if (isObject.value) return 'value-type-object'
  return 'value-type-primitive'
})

const primitiveClass = computed(() => {
  const val = props.value
  if (typeof val === 'string') return 'primitive-string'
  if (typeof val === 'number') return 'primitive-number'
  if (typeof val === 'boolean') return 'primitive-boolean'
  return 'primitive-null'
})

const arrayLength = computed(() => {
  return Array.isArray(props.value) ? props.value.length : 0
})

const itemSchema = computed(() => {
  if (!props.schema || !props.schema.items) return null
  return resolveSchemaRef(props.schema.items)
})

const objectKeys = computed(() => {
  if (!isObject.value) return []
  return Object.keys(props.value)
})

const formatPrimitive = (val: any): string => {
  if (val === null || val === undefined) return 'null'
  if (typeof val === 'string') return `"${val}"`
  return String(val)
}

const getPropertySchema = (key: string): SchemaDef | null => {
  if (!props.schema || !props.schema.properties) return null
  const prop = props.schema.properties[key]
  if (!prop) return null
  // SchemaProperty can be used as SchemaDef since they have compatible structure
  return resolveSchemaRef(prop as any)
}

const resolveSchemaRef = (schema: SchemaDef | any): SchemaDef | null => {
  if (!schema) return null
  
  // Handle $ref
  if (schema.$ref && props.defs) {
    const match = schema.$ref.match(/#\/defs\/(.+)$/)
    if (match && props.defs[match[1]]) {
      return props.defs[match[1]]
    }
  }
  
  // If schema has items, resolve it recursively
  if (schema.items) {
    return {
      ...schema,
      items: resolveSchemaRef(schema.items)
    } as SchemaDef
  }
  
  return schema as SchemaDef
}
</script>

<style scoped>
.response-value {
  font-size: 13px;
  line-height: 1.5;
}

.value-primitive {
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
  padding: 2px 4px;
  border-radius: 3px;
  display: inline-block;
}

.primitive-string {
  color: #0d7377;
  background: rgba(13, 115, 119, 0.1);
}

.primitive-number {
  color: #7c3aed;
  background: rgba(124, 58, 237, 0.1);
}

.primitive-boolean {
  color: #059669;
  background: rgba(5, 150, 105, 0.1);
}

.primitive-null {
  color: #6b7280;
  font-style: italic;
}

.value-array {
  margin-top: 4px;
}

.array-header {
  display: flex;
  align-items: center;
  font-weight: 500;
  margin-bottom: 4px;
  color: #6366f1;
}

.array-label {
  font-size: 12px;
}

.array-items {
  margin-left: 16px;
  background: rgba(99, 102, 241, 0.05);
  border-radius: 4px;
  padding: 4px 0;
}

.array-item {
  min-height: 32px;
  padding: 4px 8px;
}

.array-index {
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
  font-size: 11px;
  color: #6b7280;
  margin-right: 8px;
  min-width: 30px;
  text-align: right;
}

.value-object {
  margin-top: 4px;
}

.value-null {
  font-style: italic;
  font-family: 'Monaco', 'Menlo', 'Courier New', monospace;
}
</style>

