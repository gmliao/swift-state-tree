<script setup lang="ts">
import { computed } from 'vue'
import type { CookieGameState } from '../generated/defs'

const props = defineProps<{
  state: CookieGameState
  currentPlayerID: string | null
}>()

const emit = defineEmits<{
  (e: 'click-cookie', amount?: number): void
  (e: 'buy-upgrade', id: string): void
}>()

// Directly query state for current player's data
const selfPublic = computed(() => {
  if (!props.state || !props.currentPlayerID) return null
  return props.state.players?.[props.currentPlayerID] ?? null
})

const selfPrivate = computed(() => {
  if (!props.state || !props.currentPlayerID) return null
  return props.state.privateStates?.[props.currentPlayerID] ?? null
})

const otherPlayers = computed(() => {
  if (!props.state || !props.currentPlayerID) return []
  const players = props.state.players ?? {}
  return Object.entries(players)
    .filter(([playerID]) => playerID !== props.currentPlayerID)
    .map(([playerID, s]) => ({
      playerID,
      name: s.name,
      cookies: s.cookies,
      cps: s.cookiesPerSecond
    }))
})

const roomSummary = computed(() => {
  if (!props.state) return null
  const players = props.state.players ?? {}
  return {
    totalCookies: props.state.totalCookies ?? 0,
    ticks: props.state.ticks ?? 0,
    playerCount: Object.keys(players).length
  }
})

const cursorLevel = computed(() => selfPrivate.value?.upgrades['cursor'] ?? 0)
const grandmaLevel = computed(() => selfPrivate.value?.upgrades['grandma'] ?? 0)

function computeCost(base: number, level: number): number {
  return base * (level + 1)
}

const cursorCost = computed(() => computeCost(10, cursorLevel.value))
const grandmaCost = computed(() => computeCost(50, grandmaLevel.value))

function onClickCookie() {
  emit('click-cookie', 1)
}

function onBuyCursor() {
  emit('buy-upgrade', 'cursor')
}

function onBuyGrandma() {
  emit('buy-upgrade', 'grandma')
}
</script>

<template>
  <div class="cookie-layout">
    <v-row dense>
      <v-col cols="12" md="7">
        <v-card class="mb-4">
          <v-card-title>
            <v-icon icon="mdi-account-circle" class="mr-2" />
            我的狀態
          </v-card-title>
          <v-card-text>
            <div v-if="selfPublic">
              <div class="text-h6 mb-2">
                {{ selfPublic.name || '玩家' }}
              </div>
              <div class="mb-1">
                <strong>餅乾：</strong> {{ selfPublic.cookies }}
              </div>
              <div class="mb-1">
                <strong>每秒產量：</strong> {{ selfPublic.cookiesPerSecond }}
              </div>
              <div v-if="selfPrivate" class="mb-1">
                <strong>總點擊數：</strong> {{ selfPrivate.totalClicks }}
              </div>
              <div v-if="selfPrivate">
                <strong>升級：</strong>
                <span v-if="Object.keys(selfPrivate.upgrades).length === 0">尚未購買</span>
                <span v-else>
                  <span
                    v-for="(level, key) in selfPrivate.upgrades"
                    :key="key"
                    class="mr-2"
                  >
                    {{ key }} Lv.{{ level }}
                  </span>
                </span>
              </div>
            </div>
            <div v-else>
              尚未從伺服器取得個人狀態。
            </div>
          </v-card-text>
        </v-card>

        <v-card>
          <v-card-title>
            <v-icon icon="mdi-cookie" class="mr-2" />
            行動
          </v-card-title>
          <v-card-text>
            <div class="mb-4 text-center">
              <v-btn
                color="amber-darken-2"
                size="x-large"
                class="cookie-button"
                @click="onClickCookie"
              >
                <v-icon icon="mdi-cookie" class="mr-2" />
                點餅乾！
              </v-btn>
            </div>

            <div class="mb-2">
              <strong>升級</strong>
            </div>

            <v-row dense>
              <v-col cols="12" md="6">
                <v-card variant="outlined" class="mb-2">
                  <v-card-title class="text-subtitle-1">
                    <v-icon icon="mdi-cursor-default-click" class="mr-2" />
                    Cursor
                  </v-card-title>
                  <v-card-text>
                    <div class="mb-1">等級：{{ cursorLevel }}</div>
                    <div class="mb-2">下一級價格：約 {{ cursorCost }} 個餅乾</div>
                    <v-btn
                      color="primary"
                      block
                      @click="onBuyCursor"
                    >
                      購買 Cursor
                    </v-btn>
                  </v-card-text>
                </v-card>
              </v-col>

              <v-col cols="12" md="6">
                <v-card variant="outlined" class="mb-2">
                  <v-card-title class="text-subtitle-1">
                    <v-icon icon="mdi-account-heart" class="mr-2" />
                    Grandma
                  </v-card-title>
                  <v-card-text>
                    <div class="mb-1">等級：{{ grandmaLevel }}</div>
                    <div class="mb-2">下一級價格：約 {{ grandmaCost }} 個餅乾</div>
                    <v-btn
                      color="deep-purple"
                      block
                      @click="onBuyGrandma"
                    >
                      購買 Grandma
                    </v-btn>
                  </v-card-text>
                </v-card>
              </v-col>
            </v-row>
          </v-card-text>
        </v-card>
      </v-col>

      <v-col cols="12" md="5">
        <v-card class="mb-4">
          <v-card-title>
            <v-icon icon="mdi-chart-bar" class="mr-2" />
            房間狀態
          </v-card-title>
          <v-card-text>
            <div v-if="roomSummary">
              <div class="mb-1">
                <strong>總餅乾數：</strong> {{ roomSummary.totalCookies }}
              </div>
              <div class="mb-1">
                <strong>在線玩家：</strong> {{ roomSummary.playerCount }}
              </div>
              <div class="mb-1">
                <strong>伺服器 tick：</strong> {{ roomSummary.ticks }}
              </div>
            </div>
            <div v-else>
              尚未取得房間狀態。
            </div>
          </v-card-text>
        </v-card>

        <v-card>
          <v-card-title>
            <v-icon icon="mdi-account-group" class="mr-2" />
            其他玩家
          </v-card-title>
          <v-card-text>
            <div v-if="otherPlayers.length === 0">
              目前沒有其他玩家，邀請朋友一起點餅乾吧！
            </div>
            <v-list v-else density="compact">
              <v-list-item
                v-for="p in otherPlayers"
                :key="p.playerID"
              >
                <v-list-item-title>
                  {{ p.name || p.playerID }}
                </v-list-item-title>
                <v-list-item-subtitle>
                  餅乾：{{ p.cookies }} ・ 每秒：{{ p.cps }}
                </v-list-item-subtitle>
              </v-list-item>
            </v-list>
          </v-card-text>
        </v-card>
      </v-col>
    </v-row>
  </div>
</template>

<style scoped>
.cookie-layout {
  min-height: 100%;
}

.cookie-button {
  min-width: 220px;
  min-height: 80px;
  font-size: 1.2rem;
}
</style>

