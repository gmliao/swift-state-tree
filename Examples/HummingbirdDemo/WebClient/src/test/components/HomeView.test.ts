/**
 * Tests for HomeView component
 * 
 * These tests verify:
 * 1. The demo selection UI is displayed correctly
 * 2. Room ID input functionality
 * 3. Navigation to demo pages when clicking demo cards
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { createRouter, createWebHistory } from 'vue-router'
import HomeView from '../../views/HomeView.vue'

describe('HomeView', () => {
  const mockPush = vi.fn().mockResolvedValue(undefined)
  const router = createRouter({
    history: createWebHistory(),
    routes: [
      { path: '/', name: 'home', component: HomeView },
      { path: '/counter', name: 'counter', component: { template: '<div>Counter</div>' } },
      { path: '/cookie', name: 'cookie-game', component: { template: '<div>Cookie</div>' } }
    ]
  })
  
  // Mock router.push
  router.push = mockPush

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('displays the demo selection page', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    // Assert
    expect(wrapper.text()).toContain('SwiftStateTree Demos')
    expect(wrapper.text()).toContain('Counter Demo')
    expect(wrapper.text()).toContain('Cookie Clicker')
    expect(wrapper.find('input#roomId').exists()).toBe(true)
  })

  it('displays room ID input with default value', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    await wrapper.vm.$nextTick()

    // Assert
    const roomInput = wrapper.find('input#roomId')
    expect(roomInput.exists()).toBe(true)
    expect((roomInput.element as HTMLInputElement).value).toBe('default')
  })

  it('navigates to counter demo when counter card is clicked', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    await wrapper.vm.$nextTick()

    const counterCard = wrapper.find('.demo-card')
    await counterCard.trigger('click')
    await wrapper.vm.$nextTick()

    // Assert
    expect(mockPush).toHaveBeenCalledWith({
      name: 'counter',
      query: { roomId: 'default' }
    })
  })

  it('navigates to cookie demo when cookie card is clicked', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    await wrapper.vm.$nextTick()

    const demoCards = wrapper.findAll('.demo-card')
    expect(demoCards.length).toBeGreaterThanOrEqual(2)
    const cookieCard = demoCards[1]
    if (!cookieCard || !cookieCard.exists()) {
      throw new Error('Cookie card not found')
    }
    await cookieCard.trigger('click')
    await wrapper.vm.$nextTick()

    // Assert
    expect(mockPush).toHaveBeenCalledWith({
      name: 'cookie-game',
      query: { roomId: 'default' }
    })
  })

  it('uses empty query when room ID is empty', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    await wrapper.vm.$nextTick()

    // Set room ID to empty
    const roomInput = wrapper.find('input#roomId')
    await roomInput.setValue('')
    await wrapper.vm.$nextTick()

    const counterCard = wrapper.find('.demo-card')
    await counterCard.trigger('click')
    await wrapper.vm.$nextTick()

    // Assert
    expect(mockPush).toHaveBeenCalledWith({
      name: 'counter',
      query: {}
    })
  })

  it('displays demo cards with correct content', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router]
      }
    })

    // Assert
    const demoCards = wrapper.findAll('.demo-card')
    expect(demoCards.length).toBe(2)

    // Check Counter Demo card
    const counterCard = demoCards[0]
    if (!counterCard || !counterCard.exists()) {
      throw new Error('Counter card not found')
    }
    expect(counterCard.text()).toContain('Counter Demo')
    expect(counterCard.text()).toContain('Try Counter Demo')
    expect(counterCard.text()).toContain('Perfect for understanding the basics!')

    // Check Cookie Clicker card
    const cookieCard = demoCards[1]
    if (!cookieCard || !cookieCard.exists()) {
      throw new Error('Cookie card not found')
    }
    expect(cookieCard.text()).toContain('Cookie Clicker')
    expect(cookieCard.text()).toContain('Try Cookie Clicker')
    expect(cookieCard.text()).toContain('Advanced example with multiple features')
  })
})



