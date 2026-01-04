<template>
  <div class="response-display">
    <ResponseValue 
      :value="value" 
      :schema="schema"
      :defs="defs"
      :path="''"
    />
  </div>
</template>

<script setup lang="ts">
import type { SchemaDef } from '@/types'
import ResponseValue from './ResponseValue.vue'

const props = defineProps<{
  value: any
  schema: SchemaDef | null
  defs?: Record<string, SchemaDef>
  path?: string
}>()
</script>

<style scoped>
.response-display {
  margin-top: 8px;
}
</style>

