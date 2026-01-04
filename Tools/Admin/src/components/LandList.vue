<template>
  <v-card>
    <v-card-title>
      <v-icon icon="mdi-map-marker-multiple" class="mr-2"></v-icon>
      Lands 列表
      <v-spacer></v-spacer>
      <v-btn
        icon="mdi-refresh"
        variant="text"
        size="small"
        @click="$emit('refresh')"
        :loading="loading"
      ></v-btn>
    </v-card-title>
    <v-card-text>
      <v-alert
        v-if="error"
        type="error"
        density="compact"
        class="mb-4"
        closable
        @click:close="$emit('clear-error')"
      >
        {{ error }}
      </v-alert>

      <div v-if="loading && lands.length === 0" class="text-center py-8">
        <v-progress-circular indeterminate color="primary"></v-progress-circular>
        <div class="mt-4 text-caption">載入中...</div>
      </div>

      <v-list v-else-if="lands.length > 0">
        <v-list-item
          v-for="(landID, index) in lands"
          :key="landID"
          :value="landID"
          @click="$emit('select-land', landID)"
          :class="{ 'bg-blue-lighten-5': selectedLandID === landID }"
        >
          <template v-slot:prepend>
            <v-icon icon="mdi-map-marker" color="primary"></v-icon>
          </template>
          
          <v-list-item-title>{{ landID }}</v-list-item-title>
          <v-list-item-subtitle>Land #{{ index + 1 }}</v-list-item-subtitle>

          <template v-slot:append>
            <v-btn
              icon="mdi-information"
              variant="text"
              size="small"
              @click.stop="$emit('view-land', landID)"
            ></v-btn>
            <v-btn
              icon="mdi-delete"
              variant="text"
              size="small"
              color="error"
              @click.stop="$emit('delete-land', landID)"
            ></v-btn>
          </template>
        </v-list-item>
      </v-list>

      <v-alert v-else type="info" density="compact">
        目前沒有 lands
      </v-alert>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
defineProps<{
  lands: string[]
  loading: boolean
  error: string | null
  selectedLandID?: string
}>()

defineEmits<{
  'select-land': [landID: string]
  'view-land': [landID: string]
  'delete-land': [landID: string]
  'refresh': []
  'clear-error': []
}>()
</script>
