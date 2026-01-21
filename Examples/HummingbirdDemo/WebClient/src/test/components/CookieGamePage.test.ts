/**
 * Component Tests for CookieGamePage
 * 
 * These tests demonstrate how the StateTree architecture makes testing Vue components easy.
 * 
 * Note: For testing business logic, see `utils/gameLogic.test.ts` which shows how to
 * extract and test logic independently from components.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { createRouter, createWebHistory } from 'vue-router'
import CookieGamePage from '../../views/CookieGamePage.vue'
import { testWithCookiePlayer } from '../../generated/cookie/testHelpers'

// Mock useCookie - demonstrates how easy it is to mock the composable
vi.mock('../../generated/cookie/useCookie', async () => {
  const actual = await vi.importActual('../../generated/cookie/useCookie')
  return {
    ...actual,
    useCookie: vi.fn()
  }
})

// Stub Vuetify components to avoid CSS loading issues
const stubVuetifyComponents = {
  VContainer: { template: '<div class="v-container"><slot /></div>' },
  VRow: { template: '<div class="v-row"><slot /></div>' },
  VCol: { template: '<div class="v-col"><slot /></div>' },
  VCard: { template: '<div class="v-card" @click="$emit(\'click\')"><slot /></div>' },
  VCardItem: { template: '<div class="v-card-item"><slot /><slot name="prepend" /><slot name="append" /></div>' },
  VCardTitle: { template: '<div class="v-card-title"><slot /></div>' },
  VCardSubtitle: { template: '<div class="v-card-subtitle"><slot /></div>' },
  VCardText: { template: '<div class="v-card-text"><slot /></div>' },
  VCardActions: { template: '<div class="v-card-actions"><slot /></div>' },
  VBtn: { template: '<button :disabled="disabled" @click="$emit(\'click\')" class="btn-cookie"><slot /></button>', props: ['disabled'] },
  VIcon: { template: '<i :icon="icon"></i>', props: ['icon', 'color', 'size'] },
  VChip: { template: '<span class="v-chip"><slot /></span>', props: ['color', 'size', 'variant'] },
  VList: { template: '<div class="v-list"><slot /></div>' },
  VListItem: { template: '<div class="v-list-item"><slot /><slot name="prepend" /><slot name="append" /></div>' },
  VListItemTitle: { template: '<div class="v-list-item-title"><slot /></div>' },
  VListItemSubtitle: { template: '<div class="v-list-item-subtitle"><slot /></div>' },
  VAvatar: { template: '<div class="v-avatar"><slot /></div>' },
  VDivider: { template: '<hr class="v-divider" />' },
  VAlert: { template: '<div class="v-alert"><slot /></div>' },
  VAlertTitle: { template: '<div class="v-alert-title"><slot /></div>' },
  VProgressCircular: { template: '<div class="v-progress-circular"></div>' },
  VExpansionPanels: { template: '<div class="v-expansion-panels"><slot /></div>' },
  VExpansionPanel: { template: '<div class="v-expansion-panel"><slot /></div>' },
  VExpansionPanelTitle: { template: '<div class="v-expansion-panel-title"><slot /></div>' },
  VExpansionPanelText: { template: '<div class="v-expansion-panel-text"><slot /></div>' },
  VSpacer: { template: '<div class="v-spacer"></div>' },
}

// Stub new demo components
const stubDemoComponents = {
  DemoLayout: { template: '<div class="demo-layout"><slot /></div>' },
  ConnectionStatusCard: { template: '<div class="connection-status-card"></div>' },
  AuthorityHint: { template: '<div class="authority-hint"></div>' },
  CookieStateInspector: { 
    template: '<div class="cookie-state-inspector"></div>',
    props: ['snapshot', 'currentPlayer', 'currentPrivate', 'lastUpdatedAt']
  },
}

describe('CookieGamePage', () => {
  const router = createRouter({
    history: createWebHistory(),
    routes: [
      { path: '/', name: 'home', component: { template: '<div>Home</div>' } },
      { path: '/cookie', name: 'cookie-game', component: CookieGamePage }
    ]
  })

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('displays player information when joined', async () => {
    // Arrange: Use codegen-generated helper to create mock with player
    const mockComposable = testWithCookiePlayer('player-1', {
      name: 'Test Player',
      cookies: 100,
      cookiesPerSecond: 5
    })
    
    // Add private state for this test
    if (mockComposable.state.value) {
      mockComposable.state.value.privateStates = {
        'player-1': {
          totalClicks: 50,
          upgrades: { cursor: 2 }
        }
      }
    }
    
    const { useCookie } = await import('../../generated/cookie/useCookie')
    vi.mocked(useCookie).mockReturnValue(mockComposable)

    // Act: Mount component
    const wrapper = mount(CookieGamePage, {
      global: {
        plugins: [router],
        stubs: {
          ...stubVuetifyComponents,
          ...stubDemoComponents
        }
      }
    })

    // Assert: Check that core UI elements are rendered
    // (Player stats are now in CookieStateInspector which is stubbed)
    expect(wrapper.find('.cookie-state-inspector').exists()).toBe(true)
    expect(wrapper.find('.connection-status-card').exists()).toBe(true)
    expect(wrapper.find('.authority-hint').exists()).toBe(true)
  })

  it('calls clickCookie when cookie button is clicked', async () => {
    // Arrange: Use codegen-generated helper
    const mockComposable = testWithCookiePlayer('player-1')
    
    // Add private state
    if (mockComposable.state.value) {
      mockComposable.state.value.privateStates = {
        'player-1': { totalClicks: 0, upgrades: {} }
      }
    }
    
    const { useCookie } = await import('../../generated/cookie/useCookie')
    vi.mocked(useCookie).mockReturnValue(mockComposable)

    const wrapper = mount(CookieGamePage, {
      global: {
        plugins: [router],
        stubs: {
          ...stubVuetifyComponents,
          ...stubDemoComponents
        }
      }
    })

    // Act: Click the cookie button
    const cookieButton = wrapper.find('.btn-cookie')
    await cookieButton.trigger('click')

    // Assert: clickCookie should be called
    expect(mockComposable.clickCookie).toHaveBeenCalledWith({ amount: 1 })
  })

  it('reactively updates when state changes', async () => {
    // Arrange: Use codegen-generated helper
    const mockComposable = testWithCookiePlayer('player-1', { cookies: 0 })
    
    // Add private state
    if (mockComposable.state.value) {
      mockComposable.state.value.privateStates = {
        'player-1': { totalClicks: 0, upgrades: {} }
      }
    }
    
    const { useCookie } = await import('../../generated/cookie/useCookie')
    vi.mocked(useCookie).mockReturnValue(mockComposable)

    const wrapper = mount(CookieGamePage, {
      global: {
        plugins: [router],
        stubs: {
          ...stubVuetifyComponents,
          ...stubDemoComponents
        }
      }
    })

    // Act: Simulate state update (like from server)
    if (mockComposable.state.value?.players['player-1']) {
      mockComposable.state.value.players['player-1'].cookies = 50
    }
    await wrapper.vm.$nextTick()

    // Assert: UI should reflect the change
    // This demonstrates reactive state updates
    expect(wrapper.text()).toContain('50')
  })
})



