import { onUnmounted, ref } from 'vue'

export function useNow(intervalMs: number = 1000) {
  const nowMs = ref(Date.now())

  const interval = setInterval(() => {
    nowMs.value = Date.now()
  }, intervalMs)

  onUnmounted(() => {
    clearInterval(interval)
  })

  return {
    nowMs
  }
}
