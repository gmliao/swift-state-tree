<template>
  <v-card>
    <v-card-title>Actions</v-card-title>
    <v-card-text class="d-flex flex-wrap gap-2">
      <v-text-field
        v-model.number="amount"
        type="number"
        label="Add Gold Amount"
        density="comfortable"
        variant="outlined"
        style="max-width: 180px"
      />
      <v-btn color="primary" @click="store.addGold(amount)" :disabled="!store.isConnected">Add Gold</v-btn>
      <v-btn color="secondary" @click="store.sendPing()" :disabled="!store.isConnected">Ping</v-btn>
      <v-text-field
        v-model="chat"
        label="Chat message"
        density="comfortable"
        variant="outlined"
        style="flex: 1"
      />
      <v-btn color="primary" @click="store.sendChat(chat)" :disabled="!store.isConnected">Send Chat</v-btn>
    </v-card-text>
  </v-card>
</template>

<script setup lang="ts">
import { ref } from "vue";
import { useGameStore } from "../stores/game";

const store = useGameStore();
const amount = ref(10);
const chat = ref("Hello!");
</script>
