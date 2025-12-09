import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import path from "path";

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "src"),
      "@sdk-runtime": path.resolve(__dirname, "../..", "sdk/ts/src/runtime"),
    },
  },
});
