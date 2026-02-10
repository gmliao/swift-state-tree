# WebClient UI Shell Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract reusable UI shell components to make demo pages focus on core features (state sync, server authority, type safety) while maintaining visual consistency and reducing code duplication.

**Architecture:** Create shared layout/presentation components (`DemoLayout`, `ConnectionStatusCard`, `AuthorityHint`) and demo-specific state inspectors (`CounterStateInspector`, `CookieStateInspector`). Each demo page becomes a thin wrapper that only shows: actions → state changes → server authority proof.

**Tech Stack:** Vue 3 Composition API, Vuetify 3, TypeScript, SwiftStateTree SDK

---

## Design Principles

1. **Fast Understanding** - Users should see state sync + server authority + type safety within 30 seconds
2. **Minimal Abstraction** - Only extract UI shell; keep core demo logic explicit
3. **Visual Consistency** - All demos share same layout/connection status/authority hints
4. **Advanced Collapse** - Full snapshot JSON / event log hidden by default (expandable)

---

## Task 1: Create Shared UI Components

**Files:**
- Create: `Examples/Demo/WebClient/src/components/demo/DemoLayout.vue`
- Create: `Examples/Demo/WebClient/src/components/demo/ConnectionStatusCard.vue`
- Create: `Examples/Demo/WebClient/src/components/demo/AuthorityHint.vue`
- Create: `Examples/Demo/WebClient/src/components/demo/MetricGrid.vue`

### Step 1: Create DemoLayout component

**Purpose:** Provides consistent page structure for all demos (title, roomId, type-safe badge, navigation)

```vue
<!-- Examples/Demo/WebClient/src/components/demo/DemoLayout.vue -->
<script setup lang="ts">
interface Props {
  title: string
  roomId: string
  landType: string // e.g., "counter", "cookie"
}

defineProps<Props>()
</script>

<template>
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
```

**Verification:**
- [ ] Component created
- [ ] Props interface matches requirements
- [ ] TypeSafe badge displays land type correctly

### Step 2: Create ConnectionStatusCard component

**Purpose:** Shows connection state, room status, last state update time, and errors

```vue
<!-- Examples/Demo/WebClient/src/components/demo/ConnectionStatusCard.vue -->
<script setup lang="ts">
interface Props {
  connected: boolean
  joined: boolean
  roomId: string
  lastStateAt?: Date
  error?: string
}

defineProps<Props>()

const formatLastUpdate = (date?: Date) => {
  if (!date) return 'Never'
  const now = new Date()
  const diff = now.getTime() - date.getTime()
  if (diff < 1000) return 'Just now'
  if (diff < 60000) return `${Math.floor(diff / 1000)}s ago`
  if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`
  return date.toLocaleTimeString()
}
</script>

<template>
  <v-card variant="outlined" class="mb-4">
    <v-card-title class="bg-surface-variant py-2 d-flex align-center">
      <v-icon icon="mdi-lan-connect" size="small" class="mr-2" />
      <span class="text-subtitle-1">Connection Status</span>
    </v-card-title>
    
    <v-card-text class="pa-4">
      <v-row dense>
        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Connection</div>
          <div class="d-flex align-center">
            <v-icon
              :icon="connected ? 'mdi-check-circle' : 'mdi-close-circle'"
              :color="connected ? 'success' : 'error'"
              size="small"
              class="mr-1"
            />
            <span class="text-body-2 font-weight-medium">
              {{ connected ? 'Connected' : 'Disconnected' }}
            </span>
          </div>
        </v-col>

        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Room Status</div>
          <div class="d-flex align-center">
            <v-icon
              :icon="joined ? 'mdi-check-circle' : 'mdi-clock-outline'"
              :color="joined ? 'success' : 'warning'"
              size="small"
              class="mr-1"
            />
            <span class="text-body-2 font-weight-medium">
              {{ joined ? 'Joined' : 'Not Joined' }}
            </span>
          </div>
        </v-col>

        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Room ID</div>
          <div class="text-body-2 font-weight-medium">{{ roomId }}</div>
        </v-col>

        <v-col cols="12" sm="6" md="3">
          <div class="text-caption text-medium-emphasis">Last State Update</div>
          <div class="text-body-2 font-weight-medium">{{ formatLastUpdate(lastStateAt) }}</div>
        </v-col>
      </v-row>

      <!-- Error Alert -->
      <v-alert
        v-if="error"
        type="error"
        variant="tonal"
        density="compact"
        class="mt-3"
      >
        {{ error }}
      </v-alert>
    </v-card-text>
  </v-card>
</template>
```

**Verification:**
- [ ] Component created
- [ ] Connection/joined status display correctly
- [ ] Last update time formatting works
- [ ] Error alert shows when error exists

### Step 3: Create AuthorityHint component

**Purpose:** Persistent reminder that state is server-authoritative

```vue
<!-- Examples/Demo/WebClient/src/components/demo/AuthorityHint.vue -->
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
```

**Verification:**
- [ ] Component created
- [ ] Badge displays correctly
- [ ] Icon and text clearly communicate server authority

### Step 4: Create MetricGrid component

**Purpose:** Reusable grid for displaying key-value pairs (used by state inspectors)

```vue
<!-- Examples/Demo/WebClient/src/components/demo/MetricGrid.vue -->
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
```

**Verification:**
- [ ] Component created
- [ ] Grid layout works with different column counts
- [ ] Metrics display correctly with optional icons

### Step 5: Commit shared components

```bash
git add Examples/Demo/WebClient/src/components/demo/
git commit -m "feat(webclient): add shared demo UI shell components

- Add DemoLayout for consistent page structure
- Add ConnectionStatusCard for connection/room status
- Add AuthorityHint for server authority reminder
- Add MetricGrid for reusable key-value display

These components extract common UI patterns while keeping
core demo logic (actions/state/events) explicit in each page."
```

---

## Task 2: Create Counter-Specific Components

**Files:**
- Create: `Examples/Demo/WebClient/src/components/demo/counter/CounterStateInspector.vue`

### Step 1: Create CounterStateInspector component

**Purpose:** Shows Counter-specific state (count) with server authority proof

```vue
<!-- Examples/Demo/WebClient/src/components/demo/counter/CounterStateInspector.vue -->
<script setup lang="ts">
import { computed } from 'vue'
import MetricGrid from '../MetricGrid.vue'
import type { CounterSnapshot } from '../../../generated/counter'

interface Props {
  snapshot: CounterSnapshot | null
  lastUpdatedAt?: Date
}

const props = defineProps<Props>()

const metrics = computed(() => {
  if (!props.snapshot) return []
  
  return [
    {
      label: 'Count',
      value: props.snapshot.count,
      icon: 'mdi-counter',
      color: 'primary'
    },
    {
      label: 'Updated',
      value: props.lastUpdatedAt 
        ? `${new Date().getTime() - props.lastUpdatedAt.getTime()}ms ago`
        : 'Never',
      icon: 'mdi-clock-outline',
      color: 'info'
    }
  ]
})
</script>

<template>
  <v-card variant="outlined">
    <v-card-title class="bg-surface-variant py-2 d-flex align-center">
      <v-icon icon="mdi-state-machine" size="small" class="mr-2" />
      <span class="text-subtitle-1">State Inspector</span>
      <v-spacer />
      <v-chip size="x-small" color="success" variant="flat">
        Synced from Server
      </v-chip>
    </v-card-title>

    <v-card-text class="pa-4">
      <v-alert
        v-if="!snapshot"
        type="info"
        variant="tonal"
        density="compact"
      >
        No state received yet. Join a room to start.
      </v-alert>

      <MetricGrid v-else :metrics="metrics" :columns="2" />
    </v-card-text>

    <!-- Advanced: Full Snapshot JSON (collapsed by default) -->
    <v-expansion-panels v-if="snapshot" variant="accordion" class="ma-4 mt-0">
      <v-expansion-panel>
        <v-expansion-panel-title>
          <span class="text-caption">Advanced: Full Snapshot JSON</span>
        </v-expansion-panel-title>
        <v-expansion-panel-text>
          <pre class="text-caption pa-2 bg-surface-variant rounded">{{ JSON.stringify(snapshot, null, 2) }}</pre>
        </v-expansion-panel-text>
      </v-expansion-panel>
    </v-expansion-panels>
  </v-card>
</template>
```

**Verification:**
- [ ] Component created
- [ ] Displays count and last updated time
- [ ] Shows "Synced from Server" badge
- [ ] Advanced JSON view works and is collapsed by default

### Step 2: Commit Counter inspector

```bash
git add Examples/Demo/WebClient/src/components/demo/counter/
git commit -m "feat(webclient): add CounterStateInspector component

Shows Counter-specific state (count, last updated) with
clear indication that state is synced from server.
Includes expandable full snapshot JSON for advanced users."
```

---

## Task 3: Create Cookie-Specific Components

**Files:**
- Create: `Examples/Demo/WebClient/src/components/demo/cookie/CookieStateInspector.vue`

### Step 1: Create CookieStateInspector component

**Purpose:** Shows Cookie-specific state (cookies, cps, upgrades) with server authority proof

```vue
<!-- Examples/Demo/WebClient/src/components/demo/cookie/CookieStateInspector.vue -->
<script setup lang="ts">
import { computed } from 'vue'
import MetricGrid from '../MetricGrid.vue'
import type { CookieSnapshot } from '../../../generated/cookie'

interface Props {
  snapshot: CookieSnapshot | null
  lastUpdatedAt?: Date
}

const props = defineProps<Props>()

const metrics = computed(() => {
  if (!props.snapshot) return []
  
  const playerState = props.snapshot.players[0] // Assume first player for now
  
  return [
    {
      label: 'Total Cookies',
      value: playerState?.cookies.toFixed(1) ?? 0,
      icon: 'mdi-cookie',
      color: 'warning'
    },
    {
      label: 'Cookies/sec',
      value: playerState?.cookiesPerSecond.toFixed(1) ?? 0,
      icon: 'mdi-speedometer',
      color: 'success'
    },
    {
      label: 'Upgrades Owned',
      value: playerState?.upgrades.length ?? 0,
      icon: 'mdi-star',
      color: 'info'
    },
    {
      label: 'Last Update',
      value: props.lastUpdatedAt 
        ? `${new Date().getTime() - props.lastUpdatedAt.getTime()}ms ago`
        : 'Never',
      icon: 'mdi-clock-outline',
      color: 'primary'
    }
  ]
})
</script>

<template>
  <v-card variant="outlined">
    <v-card-title class="bg-surface-variant py-2 d-flex align-center">
      <v-icon icon="mdi-state-machine" size="small" class="mr-2" />
      <span class="text-subtitle-1">State Inspector</span>
      <v-spacer />
      <v-chip size="x-small" color="success" variant="flat">
        Synced from Server
      </v-chip>
    </v-card-title>

    <v-card-text class="pa-4">
      <v-alert
        v-if="!snapshot"
        type="info"
        variant="tonal"
        density="compact"
      >
        No state received yet. Join a room to start.
      </v-alert>

      <MetricGrid v-else :metrics="metrics" :columns="2" />
    </v-card-text>

    <!-- Advanced: Full Snapshot JSON (collapsed by default) -->
    <v-expansion-panels v-if="snapshot" variant="accordion" class="ma-4 mt-0">
      <v-expansion-panel>
        <v-expansion-panel-title>
          <span class="text-caption">Advanced: Full Snapshot JSON</span>
        </v-expansion-panel-title>
        <v-expansion-panel-text>
          <pre class="text-caption pa-2 bg-surface-variant rounded">{{ JSON.stringify(snapshot, null, 2) }}</pre>
        </v-expansion-panel-text>
      </v-expansion-panel>
    </v-expansion-panels>
  </v-card>
</template>
```

**Verification:**
- [ ] Component created
- [ ] Displays cookies, cps, upgrades, last updated
- [ ] Shows "Synced from Server" badge
- [ ] Advanced JSON view works and is collapsed by default

### Step 2: Commit Cookie inspector

```bash
git add Examples/Demo/WebClient/src/components/demo/cookie/
git commit -m "feat(webclient): add CookieStateInspector component

Shows Cookie-specific state (cookies, cps, upgrades) with
clear indication that state is synced from server.
Includes expandable full snapshot JSON for advanced users."
```

---

## Task 4: Refactor CounterPage to Use New Components

**Files:**
- Modify: `Examples/Demo/WebClient/src/views/CounterPage.vue`

### Step 1: Read current CounterPage implementation

Read `Examples/Demo/WebClient/src/views/CounterPage.vue` to understand current structure.

### Step 2: Refactor CounterPage to use new components

**Goal:** Replace custom connection status / state display with shared components. Keep action buttons and core logic explicit.

**Key changes:**
- Use `DemoLayout` wrapper
- Replace connection status section with `ConnectionStatusCard`
- Add `AuthorityHint` below connection status
- Replace state display with `CounterStateInspector`
- Keep increment button and action logic unchanged (this is the core demo)

```vue
<!-- Simplified structure after refactor -->
<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import DemoLayout from '../components/demo/DemoLayout.vue'
import ConnectionStatusCard from '../components/demo/ConnectionStatusCard.vue'
import AuthorityHint from '../components/demo/AuthorityHint.vue'
import CounterStateInspector from '../components/demo/counter/CounterStateInspector.vue'
import { createCounterLandClient } from '../generated/counter'

// ... existing connection logic ...

const roomId = ref(route.query.roomId as string || 'default')
const connected = ref(false)
const joined = ref(false)
const snapshot = ref(null)
const lastStateAt = ref<Date>()
const error = ref<string>()

// ... existing client setup ...

async function increment() {
  if (!client.value) return
  await client.value.sendAction({ type: 'increment' })
}
</script>

<template>
  <DemoLayout
    title="Counter Demo"
    :room-id="roomId"
    land-type="counter"
  >
    <!-- Connection Status -->
    <ConnectionStatusCard
      :connected="connected"
      :joined="joined"
      :room-id="roomId"
      :last-state-at="lastStateAt"
      :error="error"
    />

    <!-- Authority Hint -->
    <AuthorityHint />

    <v-row>
      <!-- Left: Actions -->
      <v-col cols="12" md="6">
        <v-card variant="outlined">
          <v-card-title class="bg-surface-variant py-2">
            <v-icon icon="mdi-gesture-tap" size="small" class="mr-2" />
            <span class="text-subtitle-1">Actions</span>
          </v-card-title>
          <v-card-text class="pa-4">
            <v-btn
              color="primary"
              size="large"
              block
              :disabled="!joined"
              @click="increment"
            >
              Increment Counter
            </v-btn>
          </v-card-text>
        </v-card>
      </v-col>

      <!-- Right: State Inspector -->
      <v-col cols="12" md="6">
        <CounterStateInspector
          :snapshot="snapshot"
          :last-updated-at="lastStateAt"
        />
      </v-col>
    </v-row>
  </DemoLayout>
</template>
```

**Verification:**
- [ ] Page uses DemoLayout wrapper
- [ ] ConnectionStatusCard displays correctly
- [ ] AuthorityHint appears below connection status
- [ ] CounterStateInspector shows state correctly
- [ ] Increment button still works
- [ ] No functionality lost from original implementation

### Step 3: Commit CounterPage refactor

```bash
git add Examples/Demo/WebClient/src/views/CounterPage.vue
git commit -m "refactor(webclient): use shared components in CounterPage

Replace custom connection status and state display with:
- DemoLayout for consistent page structure
- ConnectionStatusCard for connection/room status
- AuthorityHint for server authority reminder
- CounterStateInspector for state display

Core demo logic (increment action) remains explicit and unchanged."
```

---

## Task 5: Refactor CookieGamePage to Use New Components

**Files:**
- Modify: `Examples/Demo/WebClient/src/views/CookieGamePage.vue`

### Step 1: Read current CookieGamePage implementation

Read `Examples/Demo/WebClient/src/views/CookieGamePage.vue` to understand current structure.

### Step 2: Refactor CookieGamePage to use new components

**Goal:** Replace custom connection status / state display with shared components. Keep action buttons (click cookie, buy upgrades) and core logic explicit.

**Key changes:**
- Use `DemoLayout` wrapper
- Replace connection status section with `ConnectionStatusCard`
- Add `AuthorityHint` below connection status
- Replace state display with `CookieStateInspector`
- Keep cookie click button, upgrade list, and action logic unchanged (this is the core demo)

**Verification:**
- [ ] Page uses DemoLayout wrapper
- [ ] ConnectionStatusCard displays correctly
- [ ] AuthorityHint appears below connection status
- [ ] CookieStateInspector shows state correctly
- [ ] Cookie click button still works
- [ ] Upgrade purchases still work
- [ ] No functionality lost from original implementation

### Step 3: Commit CookieGamePage refactor

```bash
git add Examples/Demo/WebClient/src/views/CookieGamePage.vue
git commit -m "refactor(webclient): use shared components in CookieGamePage

Replace custom connection status and state display with:
- DemoLayout for consistent page structure
- ConnectionStatusCard for connection/room status
- AuthorityHint for server authority reminder
- CookieStateInspector for state display

Core demo logic (click cookie, buy upgrades) remains explicit and unchanged."
```

---

## Task 6: Update Tests

**Files:**
- Modify: `Examples/Demo/WebClient/src/test/components/CounterPage.test.ts` (if exists)
- Modify: `Examples/Demo/WebClient/src/test/components/CookieGamePage.test.ts`
- Modify: `Examples/Demo/WebClient/src/test/components/HomeView.test.ts`

### Step 1: Update test stubs to include new components

Add stubs for new components:
- `DemoLayout`
- `ConnectionStatusCard`
- `AuthorityHint`
- `CounterStateInspector`
- `CookieStateInspector`
- `MetricGrid`

### Step 2: Run tests to verify nothing broke

```bash
cd Examples/Demo/WebClient
npm test
```

**Expected:** All tests pass (30 tests)

### Step 3: Commit test updates

```bash
git add Examples/Demo/WebClient/src/test/
git commit -m "test(webclient): update test stubs for new demo components

Add stubs for DemoLayout, ConnectionStatusCard, AuthorityHint,
CounterStateInspector, CookieStateInspector, MetricGrid.

All 30 tests passing."
```

---

## Task 7: Manual Verification

### Step 1: Start DemoServer

```bash
cd Examples/Demo
swift run DemoServer
```

### Step 2: Start WebClient dev server

```bash
cd Examples/Demo/WebClient
npm run dev
```

### Step 3: Test Counter Demo

1. Open http://localhost:5173
2. Click "Counter Demo"
3. Verify:
   - [ ] DemoLayout shows title, roomId, TypeSafe badge
   - [ ] ConnectionStatusCard shows connected/joined status
   - [ ] AuthorityHint appears below connection status
   - [ ] CounterStateInspector shows count = 0 initially
   - [ ] Click "Increment Counter" → count increases
   - [ ] "Last Update" time changes after increment
   - [ ] "Advanced: Full Snapshot JSON" is collapsed by default
   - [ ] Expanding shows full snapshot JSON

### Step 4: Test Cookie Demo

1. Go back to home, click "Cookie Clicker"
2. Verify:
   - [ ] DemoLayout shows title, roomId, TypeSafe badge
   - [ ] ConnectionStatusCard shows connected/joined status
   - [ ] AuthorityHint appears below connection status
   - [ ] CookieStateInspector shows cookies, cps, upgrades
   - [ ] Click "Click Cookie" → cookies increase
   - [ ] Buy upgrade → upgrades count increases, cps increases
   - [ ] "Last Update" time changes after actions
   - [ ] "Advanced: Full Snapshot JSON" is collapsed by default
   - [ ] Expanding shows full snapshot JSON

### Step 5: Test responsive behavior

1. Resize browser to mobile size (375px)
2. Verify:
   - [ ] Hamburger menu works
   - [ ] DemoLayout is responsive
   - [ ] ConnectionStatusCard stacks metrics vertically
   - [ ] State inspectors are readable on mobile

### Step 6: Document verification results

Create a verification report:

```bash
# Create verification report
cat > docs/plans/2025-01-20-webclient-ui-shell-refactor-verification.md << 'EOF'
# WebClient UI Shell Refactor - Verification Report

**Date:** 2025-01-20
**Verifier:** [Your name/AI]

## Counter Demo
- [x] DemoLayout structure correct
- [x] ConnectionStatusCard displays connection status
- [x] AuthorityHint visible
- [x] CounterStateInspector shows count
- [x] Increment action works
- [x] State updates reflected immediately
- [x] Advanced JSON view works

## Cookie Demo
- [x] DemoLayout structure correct
- [x] ConnectionStatusCard displays connection status
- [x] AuthorityHint visible
- [x] CookieStateInspector shows cookies/cps/upgrades
- [x] Click cookie action works
- [x] Buy upgrade action works
- [x] State updates reflected immediately
- [x] Advanced JSON view works

## Responsive Behavior
- [x] Mobile hamburger menu works
- [x] DemoLayout responsive
- [x] ConnectionStatusCard stacks correctly
- [x] State inspectors readable on mobile

## Conclusion
All features working as expected. UI shell refactor successfully
extracts common patterns while keeping core demo logic explicit.
EOF

git add docs/plans/2025-01-20-webclient-ui-shell-refactor-verification.md
git commit -m "docs: add UI shell refactor verification report"
```

---

## Success Criteria

- [ ] Shared UI components created (DemoLayout, ConnectionStatusCard, AuthorityHint, MetricGrid)
- [ ] Demo-specific inspectors created (CounterStateInspector, CookieStateInspector)
- [ ] CounterPage refactored to use shared components
- [ ] CookieGamePage refactored to use shared components
- [ ] All tests passing (30 tests)
- [ ] Manual verification complete (both demos work correctly)
- [ ] Code is more maintainable (less duplication, clearer separation of concerns)
- [ ] **Core demo logic remains explicit** (actions, state sync, server authority clearly visible)

---

## Notes

- **TypeSafe badge is lightweight** (just shows "Types: src/generated/counter", no code preview)
- **State inspectors are demo-specific** (each shows exactly what matters for that demo)
- **Advanced JSON view is collapsed by default** (users can expand if they want full details)
- **Server authority is constantly reinforced** (AuthorityHint + "Synced from Server" badges)
- **Core demo logic is NOT abstracted** (increment button, click cookie, buy upgrade all remain explicit in page components)
