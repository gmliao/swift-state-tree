<script setup lang="ts">
// No props needed - this is a static hint component
</script>

<template>
  <v-alert
    type="info"
    variant="tonal"
    density="compact"
    prominent
    class="mb-4"
  >
    <template v-slot:prepend>
      <v-icon icon="mdi-shield-check" />
    </template>
    <div class="text-body-2">
      <strong>Server Authoritative State:</strong> All game logic runs on the server. 
      Client actions are validated and state changes are computed server-side.
    </div>
  </v-alert>
</template>
