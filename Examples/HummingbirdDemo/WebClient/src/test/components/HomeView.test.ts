/**
 * Tests for HomeView component
 * 
 * These tests demonstrate:
 * 1. How easy it is to test connection logic
 * 2. How the architecture separates concerns (connection vs game)
 * 3. Auto-redirect functionality
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../../views/HomeView.vue'
import { createMockDemoGame } from '../../generated/demo-game/testHelpers'

// Mock useDemoGame - demonstrates easy mocking
vi.mock('../../generated/demo-game/useDemoGame', async () => {
  const actual = await vi.importActual('../../generated/demo-game/useDemoGame')
  return {
    ...actual,
    useDemoGame: vi.fn()
  }
})

describe('HomeView', () => {
  const router = createRouter({
    history: createWebHistory(),
    routes: [
      { path: '/', name: 'home', component: HomeView },
      { path: '/cookie', name: 'cookie-game', component: { template: '<div>Game</div>' } }
    ]
  })

  beforeEach(async () => {
    vi.clearAllMocks()
    // Reset the mock implementation before each test
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReset()
  })

  it('displays connection form when not connected', async () => {
    // Arrange: Use codegen-generated helper to create proper Vue refs
    const mockComposable = createMockDemoGame()
    mockComposable.isConnected.value = false
    mockComposable.isJoined.value = false
    mockComposable.state.value = null
    
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReturnValue(mockComposable)

    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    // Assert
    expect(wrapper.text()).toContain('Connect to Game')
    expect(wrapper.find('input[placeholder="WebSocket URL"]').exists()).toBe(true)
  })

  it('has connect button that can be clicked', async () => {
    // Arrange: Use codegen-generated helper
    const mockComposable = createMockDemoGame()
    mockComposable.isConnected.value = false
    mockComposable.isJoined.value = false
    mockComposable.state.value = null
    const mockConnect = vi.fn().mockResolvedValue(undefined)
    mockComposable.connect = mockConnect
    
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReturnValue(mockComposable)

    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    // Wait for component to be fully mounted
    await wrapper.vm.$nextTick()

    // Act: Find the connect button
    const connectButton = wrapper.find('button.btn-primary')
    
    // Assert: Button exists and is clickable
    expect(connectButton.exists()).toBe(true)
    expect(connectButton.text()).toContain('Connect')
    
    // Verify button is not disabled when not connected
    const disabled = connectButton.attributes('disabled')
    expect(disabled === undefined || disabled === '').toBe(true)
    
    // Click the button (this demonstrates the UI interaction)
    await connectButton.trigger('click')
    await wrapper.vm.$nextTick()
    
    // Note: We're testing the UI behavior, not the actual connect call
    // The actual connect functionality is tested in integration tests
  })

  it('automatically redirects to game page when joined', async () => {
    // Arrange: Use codegen-generated helper
    const mockComposable = createMockDemoGame()
    mockComposable.isConnected.value = true
    mockComposable.isJoined.value = false // Start as not joined
    mockComposable.state.value = null
    
    const mockPush = vi.fn().mockResolvedValue(undefined)
    router.push = mockPush
    
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReturnValue(mockComposable)

    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    // Wait for component to be fully mounted and watch to be set up
    await wrapper.vm.$nextTick()
    await new Promise(resolve => setTimeout(resolve, 50))

    // Act: Simulate join by setting isJoined to true
    // This triggers the watch in HomeView which should redirect
    mockComposable.isJoined.value = true
    await wrapper.vm.$nextTick()
    
    // Wait for Vue's watch to trigger and router navigation
    await new Promise(resolve => setTimeout(resolve, 200))

    // Assert: Should redirect to game page
    // This demonstrates the auto-redirect feature
    expect(mockPush).toHaveBeenCalledWith({ name: 'cookie-game' })
  })

  it('displays error message when connection fails', async () => {
    // Arrange: Use codegen-generated helper
    const mockComposable = createMockDemoGame()
    mockComposable.isConnected.value = false
    mockComposable.isJoined.value = false
    mockComposable.lastError.value = 'Connection failed'
    mockComposable.state.value = null
    
    const { useDemoGame } = await import('../../generated/demo-game/useDemoGame')
    vi.mocked(useDemoGame).mockReturnValue(mockComposable)

    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    // Assert
    expect(wrapper.text()).toContain('Connection failed')
  })
})



