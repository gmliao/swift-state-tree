<script setup lang="ts">
import { useRouter } from 'vue-router'
import CookieGameView from '../components/CookieGameView.vue'
import { useDemoGame } from '../generated/demo-game/useDemoGame'

const router = useRouter()

const {
  state,
  currentPlayerID,
  isJoined,
  disconnect,
  clickCookie: baseClickCookie,
  buyUpgrade: baseBuyUpgrade
} = useDemoGame()

async function clickCookie(amount = 1) {
  await baseClickCookie({ amount })
}

async function buyUpgrade(id: string) {
  await baseBuyUpgrade({ upgradeID: id })
}

async function leaveGame() {
  await disconnect()
  await router.push({ name: 'home' })
}
</script>

<template>
  <v-app>
    <v-main>
      <v-container class="py-4" max-width="1200">
        <v-row class="mb-4" align="center">
          <v-col cols="12" md="8">
            <h2 class="mb-1">
              CookieGame 遊戲中
            </h2>
            <p class="text-body-2 mb-0">
              點擊大餅乾、購買升級，觀察自己與其他玩家的餅乾變化。
            </p>
          </v-col>
          <v-col cols="12" md="4" class="text-md-right text-left">
            <v-btn color="secondary" variant="outlined" @click="leaveGame">
              <v-icon icon="mdi-arrow-left" class="mr-2" />
              返回首頁
            </v-btn>
          </v-col>
        </v-row>

        <CookieGameView
          v-if="isJoined && state"
          :state="state"
          :current-player-i-d="currentPlayerID"
          @click-cookie="clickCookie"
          @buy-upgrade="buyUpgrade"
        />
        <v-alert v-else type="info" variant="tonal">
          尚未加入遊戲，請先回到首頁進行連線。
        </v-alert>
      </v-container>
    </v-main>
  </v-app>
</template>

