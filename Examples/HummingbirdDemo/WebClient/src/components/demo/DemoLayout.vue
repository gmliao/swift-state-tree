<script setup lang="ts">
interface Props {
  title: string
  roomId: string
  landType: string // e.g., "counter", "cookie"
}

defineProps<Props>()
</script>

<parameter>
  <v-container fluid class="pa-4">
    <v-row>
      <v-col cols="12">
        <!-- Header with Title + TypeSafe Badge -->
        <div class="d-flex align-center justify-space-between mb-4">
          <div>
            <h1 class="text-h4 font-weight-bold mb-1">{{ title }}</h1>
            <p class="text-body-2 text-medium-emphasis">Room: {{ roomId }}</p>
          </div>
          
          <!-- TypeSafe Badge (lightweight hint) -->
          <v-chip
            color="info"
            variant="outlined"
            size="small"
            prepend-icon="mdi-code-tags"
          >
            Types: src/generated/{{ landType }}
          </v-chip>
        </div>

        <!-- Content Slot -->
        <slot />
      </v-col>
    </v-row>
  </v-container>
</template>
