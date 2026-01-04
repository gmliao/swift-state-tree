<template>
  <v-app>
    <v-app-bar color="blue-darken-2" prominent>
      <v-app-bar-title style="font-size: 1.5rem;">
        <span class="mr-2">🔧</span>
        SwiftStateTree Admin
      </v-app-bar-title>
      <v-spacer></v-spacer>
      <v-chip
        :color="configStatus.color"
        variant="flat"
        class="mr-2"
      >
        <v-icon :icon="configStatus.icon" class="mr-1"></v-icon>
        {{ configStatus.text }}
      </v-chip>
      <v-btn
        v-if="isConfigured"
        color="secondary"
        variant="flat"
        size="small"
        class="mr-2"
        @click="clearConfig"
      >
        <v-icon icon="mdi-logout" class="mr-1"></v-icon>
        登出
      </v-btn>
      <v-btn
        color="primary"
        variant="flat"
        size="small"
        class="mr-4"
        @click="showConfigDialog = true"
      >
        <v-icon icon="mdi-cog" class="mr-1"></v-icon>
        設定
      </v-btn>
    </v-app-bar>

    <v-main style="height: calc(100vh - 64px); overflow: hidden;">
      <v-container fluid class="app-shell">
        <!-- Configuration State -->
        <div v-if="!isConfigured" class="config-prompt">
          <v-row justify="center">
            <v-col cols="12" md="8" lg="6">
              <v-card>
                <v-card-title>
                  <v-icon icon="mdi-cog" class="mr-2"></v-icon>
                  初始設定
                </v-card-title>
                <v-card-text>
                  <v-alert type="info" density="compact" class="mb-4">
                    請先設定伺服器 URL 和認證資訊
                  </v-alert>
                  <v-btn
                    color="primary"
                    block
                    @click="showConfigDialog = true"
                  >
                    <v-icon icon="mdi-cog" class="mr-2"></v-icon>
                    開啟設定
                  </v-btn>
                </v-card-text>
              </v-card>
            </v-col>
          </v-row>
        </div>

        <!-- Main Dashboard -->
        <div v-else class="dashboard-layout">
          <v-row class="dashboard-row">
            <!-- Left: System Stats -->
            <v-col cols="12" md="4">
              <SystemStats
                :stats="systemStats"
                :loading="systemStatsLoading"
                :error="systemStatsError"
                @refresh="loadSystemStats"
                @clear-error="systemStatsError = null"
              />
            </v-col>

            <!-- Right: Lands List -->
            <v-col cols="12" md="8">
              <LandList
                :lands="lands"
                :loading="landsLoading"
                :error="landsError"
                :selected-land-i-d="selectedLandID"
                @select-land="selectedLandID = $event"
                @view-land="viewLandDetails"
                @delete-land="confirmDeleteLand"
                @refresh="loadLands"
                @clear-error="landsError = null"
              />
            </v-col>
          </v-row>
        </div>
      </v-container>
    </v-main>

    <!-- Configuration Dialog -->
    <v-dialog v-model="showConfigDialog" max-width="600">
      <v-card>
        <v-card-title>
          <v-icon icon="mdi-cog" class="mr-2"></v-icon>
          管理設定
        </v-card-title>
        <v-card-text>
          <v-text-field
            v-model="configForm.baseUrl"
            label="伺服器 URL"
            prepend-icon="mdi-link"
            variant="outlined"
            hint="例如: http://localhost:8080"
            persistent-hint
            class="mb-2"
          ></v-text-field>

          <v-tabs v-model="authTab" class="mb-4">
            <v-tab value="apikey">API Key</v-tab>
            <v-tab value="token">JWT Token</v-tab>
          </v-tabs>

          <v-window v-model="authTab">
            <v-window-item value="apikey">
              <v-text-field
                v-model="configForm.apiKey"
                label="API Key"
                prepend-icon="mdi-key"
                variant="outlined"
                type="password"
                density="compact"
                hint="用於管理員認證的 API Key"
                persistent-hint
              ></v-text-field>
            </v-window-item>

            <v-window-item value="token">
              <v-text-field
                v-model="jwtSecretKey"
                label="JWT Secret Key"
                prepend-icon="mdi-key"
                variant="outlined"
                type="password"
                density="compact"
                hint="必須與伺服器配置的 JWT_SECRET_KEY 一致（預設: demo-secret-key-change-in-production）"
                persistent-hint
                class="mb-2"
              ></v-text-field>
              
              <v-text-field
                v-model="jwtPlayerID"
                label="Player ID *"
                prepend-icon="mdi-account"
                variant="outlined"
                density="compact"
                hint="JWT payload 中的 playerID（必填）"
                persistent-hint
                class="mb-2"
              ></v-text-field>
              
              <v-select
                v-model="jwtAdminRole"
                label="Admin Role *"
                prepend-icon="mdi-shield-account"
                variant="outlined"
                density="compact"
                :items="['admin', 'operator', 'viewer']"
                hint="管理員角色（必填）"
                persistent-hint
                class="mb-2"
              ></v-select>
              
              <v-btn
                color="secondary"
                block
                class="mb-2"
                @click="autoFillJWTFields"
              >
                <v-icon icon="mdi-auto-fix" class="mr-2"></v-icon>
                自動填入測試資料
              </v-btn>
              
              <v-btn
                color="primary"
                block
                class="mb-2"
                @click="generateJWTToken"
                :disabled="!jwtSecretKey || !jwtPlayerID || !jwtAdminRole"
              >
                <v-icon icon="mdi-key-variant" class="mr-2"></v-icon>
                生成 JWT Token
              </v-btn>
              
              <v-textarea
                v-model="configForm.token"
                label="JWT Token"
                prepend-icon="mdi-key-variant"
                variant="outlined"
                rows="3"
                hint="生成的 JWT Token 將顯示在這裡"
                persistent-hint
                class="mb-2"
              ></v-textarea>
              
              <v-alert
                v-if="jwtError"
                type="error"
                density="compact"
                class="mb-2"
              >
                {{ jwtError }}
              </v-alert>
              
              <v-alert
                v-if="configForm.token"
                type="success"
                density="compact"
              >
                <div class="text-caption">Token 已生成</div>
                <div class="text-caption font-mono" style="word-break: break-all; font-size: 0.7rem;">
                  {{ configForm.token.substring(0, 50) }}...
                </div>
              </v-alert>
            </v-window-item>
          </v-window>

          <v-alert
            v-if="configError"
            type="error"
            density="compact"
            class="mt-4"
          >
            {{ configError }}
          </v-alert>
        </v-card-text>
        <v-card-actions>
          <v-spacer></v-spacer>
          <v-btn
            color="secondary"
            @click="showConfigDialog = false"
          >
            取消
          </v-btn>
          <v-btn
            color="primary"
            @click="saveConfig"
          >
            儲存
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>

    <!-- Land Details Dialog -->
    <v-dialog v-model="showLandDetailsDialog" max-width="600">
      <LandDetails
        v-if="selectedLandID"
        :land-info="selectedLandInfo"
        :loading="landDetailsLoading"
        :error="landDetailsError"
        :land-i-d="selectedLandID"
        @close="showLandDetailsDialog = false"
        @delete-land="confirmDeleteLand"
        @clear-error="landDetailsError = null"
      />
    </v-dialog>

    <!-- Delete Confirmation Dialog -->
    <v-dialog v-model="showDeleteDialog" max-width="400">
      <v-card>
        <v-card-title>
          <v-icon icon="mdi-alert" color="error" class="mr-2"></v-icon>
          確認刪除
        </v-card-title>
        <v-card-text>
          <p>您確定要刪除 Land <strong>{{ landToDelete }}</strong> 嗎？</p>
          <v-alert type="warning" density="compact" class="mt-4">
            此操作無法復原
          </v-alert>
        </v-card-text>
        <v-card-actions>
          <v-spacer></v-spacer>
          <v-btn
            color="secondary"
            @click="showDeleteDialog = false"
          >
            取消
          </v-btn>
          <v-btn
            color="error"
            @click="executeDeleteLand"
            :loading="deleteLoading"
          >
            刪除
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-dialog>
  </v-app>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import LandList from './components/LandList.vue'
import LandDetails from './components/LandDetails.vue'
import SystemStats from './components/SystemStats.vue'
import { useAdminAPI } from './composables/useAdminAPI'
import { generateJWT } from './utils/jwt'
import type { AdminConfig, LandInfo, SystemStats as SystemStatsType } from './types/admin'

// Configuration
const showConfigDialog = ref(false)
const authTab = ref('apikey')
const configForm = ref<AdminConfig>({
  baseUrl: 'http://localhost:8080',
  apiKey: 'demo-admin-key',
  token: '',
})
const configError = ref<string | null>(null)

// JWT Configuration
const jwtSecretKey = ref('demo-secret-key-change-in-production')
const jwtPlayerID = ref('admin-user')
const jwtAdminRole = ref('admin')
const jwtError = ref<string | null>(null)

// Load config from localStorage
const loadConfig = () => {
  const saved = localStorage.getItem('admin-config')
  if (saved) {
    try {
      const savedConfig = JSON.parse(saved)
      // Only use saved config if it has non-empty values, otherwise use defaults
      configForm.value = {
        baseUrl: (savedConfig.baseUrl && savedConfig.baseUrl.trim()) || configForm.value.baseUrl,
        apiKey: (savedConfig.apiKey && savedConfig.apiKey.trim()) || configForm.value.apiKey,
        token: (savedConfig.token && savedConfig.token.trim()) || configForm.value.token,
      }
    } catch {
      // Ignore parse errors, use defaults
    }
  }
  
  // Debug: log config in development
  if (import.meta.env.DEV) {
    console.log('[Admin] Config loaded:', { 
      baseUrl: configForm.value.baseUrl, 
      hasApiKey: !!configForm.value.apiKey,
      apiKeyPreview: configForm.value.apiKey ? `${configForm.value.apiKey.substring(0, 5)}...` : 'none'
    })
  }
}

// Save config to localStorage
const saveConfig = () => {
  if (!configForm.value.baseUrl) {
    configError.value = '請輸入伺服器 URL'
    return
  }

  if (!configForm.value.apiKey && !configForm.value.token) {
    configError.value = '請輸入 API Key 或 JWT Token'
    return
  }

  try {
    localStorage.setItem('admin-config', JSON.stringify(configForm.value))
    configError.value = null
    showConfigDialog.value = false
    // Reload data
    loadLands()
    loadSystemStats()
  } catch (err: any) {
    configError.value = `儲存失敗: ${err.message}`
  }
}

// JWT Token Generation
const autoFillJWTFields = () => {
  // Auto-fill with test data
  const randomID = () => Math.random().toString(36).substring(2, 10)
  jwtPlayerID.value = `admin-${randomID()}`
  jwtAdminRole.value = 'admin'
}

const generateJWTToken = async () => {
  jwtError.value = null
  
  if (!jwtSecretKey.value) {
    jwtError.value = '請輸入 JWT Secret Key'
    return
  }
  
  if (!jwtPlayerID.value) {
    jwtError.value = '請輸入 Player ID'
    return
  }
  
  if (!jwtAdminRole.value) {
    jwtError.value = '請選擇 Admin Role'
    return
  }
  
  try {
    const payload: any = {
      playerID: jwtPlayerID.value,
      metadata: {
        adminRole: jwtAdminRole.value
      }
    }
    
    configForm.value.token = await generateJWT(jwtSecretKey.value, payload)
    jwtError.value = null
  } catch (err: any) {
    jwtError.value = `生成 Token 失敗: ${err.message || err}`
    configForm.value.token = ''
  }
}

// Clear config (logout)
const clearConfig = () => {
  try {
    localStorage.removeItem('admin-config')
    // Reset to defaults
    configForm.value = {
      baseUrl: 'http://localhost:8080',
      apiKey: 'demo-admin-key',
      token: '',
    }
    // Reset JWT fields
    jwtSecretKey.value = 'demo-secret-key-change-in-production'
    jwtPlayerID.value = 'admin-user'
    jwtAdminRole.value = 'admin'
    jwtError.value = null
    // Clear data
    lands.value = []
    systemStats.value = null
    selectedLandID.value = ''
    selectedLandInfo.value = null
    landsError.value = null
    systemStatsError.value = null
  } catch (err: any) {
    console.error('Failed to clear config:', err)
  }
}

const isConfigured = computed(() => {
  return configForm.value.baseUrl && (configForm.value.apiKey || configForm.value.token)
})

const configStatus = computed(() => {
  if (isConfigured.value) {
    return { text: '已設定', color: 'success', icon: 'mdi-check-circle' }
  }
  return { text: '未設定', color: 'warning', icon: 'mdi-alert-circle' }
})

// API
const {
  loading: apiLoading,
  error: apiError,
  listLands: apiListLands,
  getLandStats: apiGetLandStats,
  getSystemStats: apiGetSystemStats,
  deleteLand: apiDeleteLand,
} = useAdminAPI()

// Data
const lands = ref<string[]>([])
const systemStats = ref<SystemStatsType | null>(null)
const selectedLandID = ref<string>('')
const selectedLandInfo = ref<LandInfo | null>(null)

// Loading states
const landsLoading = ref(false)
const systemStatsLoading = ref(false)
const landDetailsLoading = ref(false)
const deleteLoading = ref(false)

// Errors
const landsError = ref<string | null>(null)
const systemStatsError = ref<string | null>(null)
const landDetailsError = ref<string | null>(null)

// Dialogs
const showLandDetailsDialog = ref(false)
const showDeleteDialog = ref(false)
const landToDelete = ref<string>('')

const getConfig = (): AdminConfig => configForm.value

// Load functions
const loadLands = async () => {
  if (!isConfigured.value) return
  
  landsLoading.value = true
  landsError.value = null
  
  try {
    lands.value = await apiListLands(getConfig())
  } catch (err: any) {
    landsError.value = err.message
  } finally {
    landsLoading.value = false
  }
}

const loadSystemStats = async () => {
  if (!isConfigured.value) return
  
  systemStatsLoading.value = true
  systemStatsError.value = null
  
  try {
    systemStats.value = await apiGetSystemStats(getConfig())
  } catch (err: any) {
    systemStatsError.value = err.message
  } finally {
    systemStatsLoading.value = false
  }
}

const loadLandDetails = async (landID: string) => {
  if (!isConfigured.value) return
  
  landDetailsLoading.value = true
  landDetailsError.value = null
  
  try {
    selectedLandInfo.value = await apiGetLandStats(landID, getConfig())
  } catch (err: any) {
    landDetailsError.value = err.message
  } finally {
    landDetailsLoading.value = false
  }
}

const viewLandDetails = (landID: string) => {
  selectedLandID.value = landID
  selectedLandInfo.value = null
  showLandDetailsDialog.value = true
  loadLandDetails(landID)
}

const confirmDeleteLand = (landID: string) => {
  landToDelete.value = landID
  showDeleteDialog.value = true
}

const executeDeleteLand = async () => {
  if (!landToDelete.value || !isConfigured.value) return
  
  deleteLoading.value = true
  
  try {
    await apiDeleteLand(landToDelete.value, getConfig())
    showDeleteDialog.value = false
    landToDelete.value = ''
    
    // Reload data
    await loadLands()
    await loadSystemStats()
    
    // Close details dialog if open
    if (showLandDetailsDialog.value && selectedLandID.value === landToDelete.value) {
      showLandDetailsDialog.value = false
    }
  } catch (err: any) {
    // Error is handled by the API composable
    console.error('Delete failed:', err)
  } finally {
    deleteLoading.value = false
  }
}

// Watch for config changes
watch(() => isConfigured.value, (newValue) => {
  if (newValue) {
    loadLands()
    loadSystemStats()
  }
})

// Initialize
onMounted(() => {
  loadConfig()
  if (isConfigured.value) {
    loadLands()
    loadSystemStats()
  }
})
</script>

<style>
.v-application {
  background: #f5f5f5;
  min-height: 100vh;
}

.app-shell {
  height: 100%;
  max-height: calc(100vh - 64px);
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 16px;
  overflow: hidden;
}

.config-prompt {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
}

.dashboard-layout {
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.dashboard-row {
  flex: 1;
  min-height: 0;
  margin: 0;
}
</style>
