<script setup lang="ts">
import { ref } from 'vue'

const drawer = ref(false)
</script>

<template>
  <v-app>
    <!-- Mobile drawer (temporary) -->
    <v-navigation-drawer
      v-model="drawer"
      temporary
      location="left"
    >
      <v-list nav density="comfortable">
        <v-list-item
          to="/"
          prepend-icon="mdi-home"
          title="Home"
          @click="drawer = false"
        ></v-list-item>
        <v-list-item
          to="/counter"
          prepend-icon="mdi-counter"
          title="Counter Demo"
          @click="drawer = false"
        ></v-list-item>
        <v-list-item
          to="/cookie"
          prepend-icon="mdi-cookie"
          title="Cookie Clicker"
          @click="drawer = false"
        ></v-list-item>
      </v-list>
    </v-navigation-drawer>

    <v-app-bar color="primary" prominent>
      <!-- Hamburger: only show on small screens -->
      <v-app-bar-nav-icon
        class="d-md-none"
        @click="drawer = !drawer"
      ></v-app-bar-nav-icon>

      <v-app-bar-title class="d-flex align-center">
        <v-icon icon="mdi-file-tree" class="mr-2"></v-icon>
        <span class="text-h6 font-weight-bold">SwiftStateTree Demos</span>
      </v-app-bar-title>

      <v-spacer></v-spacer>

      <!-- Always show Home icon -->
      <v-btn
        to="/"
        icon="mdi-home"
        variant="text"
        title="Home"
      ></v-btn>

      <!-- Desktop shortcuts -->
      <v-btn
        to="/counter"
        prepend-icon="mdi-counter"
        variant="text"
        class="mr-2 d-none d-md-flex"
      >
        Counter
      </v-btn>

      <v-btn
        to="/cookie"
        prepend-icon="mdi-cookie"
        variant="text"
        class="d-none d-md-flex"
      >
        Cookie
      </v-btn>
    </v-app-bar>

    <v-main>
      <v-container fluid class="pa-4">
        <RouterView />
      </v-container>
    </v-main>
  </v-app>
</template>
