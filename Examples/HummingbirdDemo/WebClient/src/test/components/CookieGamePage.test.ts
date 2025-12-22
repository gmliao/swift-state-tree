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
import { testWithDemoGamePlayer } from '../../generated/demo-game/testHelpers'

// Mock useDemoGame - demonstrates how easy it is to mock the composable
vi.mock('../../generated/demo-game/useDemoGame', async () => {
  const actual = await vi.importActual('../../generated/demo-game/useDemoGame')
  return {
    ...actual,
    useDemoGame: vi.fn()
  }
})

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
    const mockComposable = testWithDemoGamePlayer('player-1', {
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
    
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReturnValue(mockComposable)

    // Act: Mount component
    const wrapper = mount(CookieGamePage, {
      global: {
        plugins: [router]
      }
    })

    // Assert: Check that player info is displayed
    expect(wrapper.text()).toContain('Test Player')
    expect(wrapper.text()).toContain('100') // cookies
    expect(wrapper.text()).toContain('5') // cookies per second
    expect(wrapper.text()).toContain('50') // total clicks
  })

  it('calls clickCookie when cookie button is clicked', async () => {
    // Arrange: Use codegen-generated helper
    const mockComposable = testWithDemoGamePlayer('player-1')
    
    // Add private state
    if (mockComposable.state.value) {
      mockComposable.state.value.privateStates = {
        'player-1': { totalClicks: 0, upgrades: {} }
      }
    }
    
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReturnValue(mockComposable)

    const wrapper = mount(CookieGamePage, {
      global: {
        plugins: [router]
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
    const mockComposable = testWithDemoGamePlayer('player-1', { cookies: 0 })
    
    // Add private state
    if (mockComposable.state.value) {
      mockComposable.state.value.privateStates = {
        'player-1': { totalClicks: 0, upgrades: {} }
      }
    }
    
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReturnValue(mockComposable)

    const wrapper = mount(CookieGamePage, {
      global: {
        plugins: [router]
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



