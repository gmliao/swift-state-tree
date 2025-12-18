import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import CookieGamePage from '../views/CookieGamePage.vue'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    component: HomeView
  },
  {
    path: '/cookie',
    name: 'cookie-game',
    component: CookieGamePage
  }
]

export const router = createRouter({
  history: createWebHistory(),
  routes
})

