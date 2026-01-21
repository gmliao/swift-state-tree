import { createRouter, createWebHistory } from "vue-router";
import ConnectView from "../views/ConnectView.vue";
import GameView from "../views/GameView.vue";
import ReevaluationMonitorView from "../views/ReevaluationMonitorView.vue";

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: "/",
      name: "connect",
      component: ConnectView,
    },
    {
      path: "/game",
      name: "game",
      component: GameView,
    },
    {
      path: "/reevaluation-monitor",
      name: "reevaluation-monitor",
      component: ReevaluationMonitorView,
    },
  ],
});
