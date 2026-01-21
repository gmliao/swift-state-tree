<script setup lang="ts">
interface Metric {
  label: string
  value: string | number
  icon?: string
  color?: string
}

interface Props {
  metrics: Metric[]
  columns?: number // Default: 2
}

withDefaults(defineProps<Props>(), {
  columns: 2
})
</script>

<template>
  <v-row dense>
    <v-col
      v-for="(metric, index) in metrics"
      :key="index"
      cols="12"
      :sm="12 / columns"
    >
      <div class="metric-item pa-3 bg-surface-variant rounded">
        <div class="d-flex align-center mb-1">
          <v-icon
            v-if="metric.icon"
            :icon="metric.icon"
            :color="metric.color"
            size="small"
            class="mr-1"
          />
          <span class="text-caption text-medium-emphasis">{{ metric.label }}</span>
        </div>
        <div class="text-h6 font-weight-bold">{{ metric.value }}</div>
      </div>
    </v-col>
  </v-row>
</template>

<style scoped>
.metric-item {
  border: 1px solid rgba(var(--v-border-color), var(--v-border-opacity));
}
</style>
