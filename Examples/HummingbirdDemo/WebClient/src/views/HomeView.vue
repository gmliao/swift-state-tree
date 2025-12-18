<script setup lang="ts">
import ConnectionCard from '../components/ConnectionCard.vue'
import { useRouter } from 'vue-router'
import { useDemoGame } from '../generated/demo-game/useDemoGame'

const router = useRouter()

const {
  isConnecting,
  isConnected,
  isJoined,
  lastError,
  connect,
  disconnect
} = useDemoGame()

async function handleConnect(payload: { wsUrl: string; playerName?: string }) {
  await connect(payload)
  if (isJoined.value) {
    await router.push({ name: 'cookie-game' })
  }
}

async function handleDisconnect() {
  await disconnect()
}
</script>

<template>
  <v-app>
    <v-main>
      <v-container class="py-6" max-width="900">
        <v-row>
          <v-col cols="12">
            <h2 class="mb-4">
              CookieGame Demo
            </h2>
            <p class="text-body-2 mb-6">
              這是一個用 SwiftStateTree + TypeScript codegen 建立的 Cookie Clicker 範例。
              先在下方設定連線資訊，成功加入後會進入遊戲畫面。
            </p>
          </v-col>
        </v-row>

        <v-row>
          <v-col cols="12" md="6">
            <ConnectionCard
              :is-connecting="isConnecting"
              :is-connected="isConnected"
              :is-joined="isJoined"
              :last-error="lastError"
              @connect="handleConnect"
              @disconnect="handleDisconnect"
            />
          </v-col>

          <v-col cols="12" md="6">
            <v-card>
              <v-card-title>
                <v-icon icon="mdi-help-circle" class="mr-2" />
                說明
              </v-card-title>
              <v-card-text>
                <ul class="text-body-2">
                  <li>預設會連到 <code>ws://localhost:8080/game</code>。</li>
                  <li>名稱可以先隨便輸入，或留空讓伺服器決定。</li>
                  <li>點「連線並加入遊戲」成功後會自動進入 CookieGame 畫面。</li>
                  <li>之後可以在這個首頁加上更多遊戲入口。</li>
                </ul>
              </v-card-text>
            </v-card>
          </v-col>
        </v-row>
      </v-container>
    </v-main>
  </v-app>
</template>

