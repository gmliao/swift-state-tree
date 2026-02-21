<template>
  <v-app>
    <v-app-bar color="primary">
      <v-app-bar-title>Control Plane Admin</v-app-bar-title>
      <v-spacer />
      <v-btn to="/" variant="text">Dashboard</v-btn>
      <v-btn to="/servers" variant="text">Servers</v-btn>
    </v-app-bar>
    <v-main>
      <router-view />
    </v-main>
  </v-app>
</template>

<script setup lang="ts">
</script>
