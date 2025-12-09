<template>
  <v-app>
    <v-main class="pa-4">
      <v-container fluid>
        <v-row>
          <v-col cols="12" md="6">
            <ConnectionPanel />
          </v-col>
          <v-col cols="12" md="6">
            <GameActions />
          </v-col>
        </v-row>
        <v-row>
          <v-col cols="12" md="6">
            <GameStateView />
          </v-col>
          <v-col cols="12" md="6">
            <LogsPanel />
          </v-col>
        </v-row>
      </v-container>
    </v-main>
  </v-app>
</template>

<script setup lang="ts">
import ConnectionPanel from "./components/ConnectionPanel.vue";
import GameActions from "./components/GameActions.vue";
import GameStateView from "./components/GameStateView.vue";
import LogsPanel from "./components/LogsPanel.vue";
</script>
