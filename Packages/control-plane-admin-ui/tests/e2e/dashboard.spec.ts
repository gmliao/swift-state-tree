import { test, expect } from '@playwright/test'

test.describe('Dashboard', () => {
  test('shows dashboard title', async ({ page }) => {
    await page.goto('/')
    await expect(page.getByRole('heading', { name: /dashboard/i })).toBeVisible()
  })

  test('shows queue summary section', async ({ page }) => {
    await page.goto('/')
    await expect(page.getByText('Queue Summary')).toBeVisible()
  })

  test('navigates to servers', async ({ page }) => {
    await page.goto('/')
    await page.getByRole('link', { name: 'Servers' }).click()
    await expect(page).toHaveURL(/\/servers/)
    await expect(page.getByRole('heading', { name: /servers/i })).toBeVisible()
  })
})
