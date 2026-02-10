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

// Stub Vuetify components to avoid CSS loading issues in tests
const stubVuetifyComponents = {
  VApp: { template: '<div><slot /></div>' },
  VAppBar: { template: '<div><slot /></div>' },
  VAppBarTitle: { template: '<div><slot /></div>' },
  VMain: { template: '<div><slot /></div>' },
  VContainer: { template: '<div><slot /></div>' },
  VRow: { template: '<div><slot /></div>' },
  VCol: { template: '<div><slot /></div>' },
  VCard: { template: '<div @click="$emit(\'click\')"><slot /></div>', emits: ['click'] },
  VCardItem: { template: '<div><slot /><slot name="prepend" /></div>' },
  VCardTitle: { template: '<div><slot /></div>' },
  VCardSubtitle: { template: '<div><slot /></div>' },
  VCardText: { template: '<div><slot /></div>' },
  VCardActions: { template: '<div><slot /></div>' },
  VTextField: { 
    template: '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" data-testid="room-id" />',
    props: ['modelValue'],
    emits: ['update:modelValue']
  },
  VBtn: { template: '<button @click="$emit(\'click\')"><slot /></button>', emits: ['click'] },
  VIcon: { template: '<i></i>' },
  VAvatar: { template: '<div><slot /></div>' },
  VChip: { template: '<span><slot /></span>' },
  VSpacer: { template: '<div></div>' }
}

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
        plugins: [router],
        stubs: stubVuetifyComponents
      }
    })

    // Assert
    expect(wrapper.text()).toContain('SwiftStateTree')
    expect(wrapper.text()).toContain('Counter Demo')
    expect(wrapper.text()).toContain('Cookie Clicker')
    expect(wrapper.find('[data-testid="room-id"]').exists()).toBe(true)
  })

  it('displays room ID input with default value', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router],
        stubs: stubVuetifyComponents
      }
    })

    await wrapper.vm.$nextTick()

    // Assert
    const roomInput = wrapper.find('[data-testid="room-id"]')
    expect(roomInput.exists()).toBe(true)
    expect((roomInput.element as HTMLInputElement).value).toBe('default')
  })

  it('navigates to counter demo when counter card is clicked', async () => {
    // Act
    const wrapper = mount(HomeView, {
      global: {
        plugins: [router],
        stubs: stubVuetifyComponents
      }
    })

    await wrapper.vm.$nextTick()

    const counterCard = wrapper.find('[data-testid="demo-counter"]')
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
        plugins: [router],
        stubs: stubVuetifyComponents
      }
    })

    await wrapper.vm.$nextTick()

    const cookieCard = wrapper.find('[data-testid="demo-cookie"]')
    expect(cookieCard.exists()).toBe(true)
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
        plugins: [router],
        stubs: stubVuetifyComponents
      }
    })

    await wrapper.vm.$nextTick()

    // Set room ID to empty
    const roomInput = wrapper.find('[data-testid="room-id"]')
    await roomInput.setValue('')
    await wrapper.vm.$nextTick()

    const counterCard = wrapper.find('[data-testid="demo-counter"]')
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
        plugins: [router],
        stubs: stubVuetifyComponents
      }
    })

    // Assert
    const counterCard = wrapper.find('[data-testid="demo-counter"]')
    expect(counterCard.exists()).toBe(true)
    expect(counterCard.text()).toContain('Counter Demo')
    expect(counterCard.text()).toContain('Launch Counter Demo')

    const cookieCard = wrapper.find('[data-testid="demo-cookie"]')
    expect(cookieCard.exists()).toBe(true)
    expect(cookieCard.text()).toContain('Cookie Clicker')
    expect(cookieCard.text()).toContain('Launch Cookie Clicker')
  })
})
