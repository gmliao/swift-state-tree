import { test, expect } from '@playwright/test'

test.describe('Servers', () => {
  test('shows servers page', async ({ page }) => {
    await page.goto('/servers')
    await expect(page.getByRole('heading', { name: /servers/i })).toBeVisible()
  })

  test('shows registered servers table when control plane has data', async ({ page }) => {
    await page.goto('/servers')
    await expect(page.getByText('Registered Servers')).toBeVisible()
  })
})
