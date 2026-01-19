import { ref, Ref } from 'vue'
import type { Schema } from '@/types/schema'

export function useSchema(schemaJson: Ref<string>) {
  const parsedSchema = ref<Schema | null>(null)
  const error = ref<string | null>(null)

  const parseSchema = (): Schema => {
    try {
      if (!schemaJson.value) {
        throw new Error('Schema JSON 為空')
      }

      const schema = JSON.parse(schemaJson.value) as Schema
      
      // Validate schema structure
      if (!schema.lands || !schema.defs) {
        throw new Error('無效的 Schema 格式：缺少 lands 或 defs')
      }

      parsedSchema.value = schema
      error.value = null
      
      // console.log('Schema 解析成功:', schema)
      return schema
    } catch (err) {
      const message = err instanceof Error ? err.message : '未知錯誤'
      error.value = message
      parsedSchema.value = null
      console.error('Schema 解析失敗:', err)
      throw err
    }
  }

  const loadSchema = async (file: File | null): Promise<void> => {
    if (!file) return

    try {
      const text = await file.text()
      schemaJson.value = text
      parseSchema()
    } catch (err) {
      const message = err instanceof Error ? err.message : '未知錯誤'
      error.value = `讀取檔案失敗: ${message}`
      console.error('讀取檔案失敗:', err)
    }
  }

  return {
    parsedSchema,
    error,
    parseSchema,
    loadSchema
  }
}

