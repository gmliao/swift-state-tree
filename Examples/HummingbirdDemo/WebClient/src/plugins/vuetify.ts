import 'vuetify/styles'
import { createVuetify } from 'vuetify'
import * as components from 'vuetify/components'
import * as directives from 'vuetify/directives'
import '@mdi/font/css/materialdesignicons.css'

export const vuetify = createVuetify({
  components,
  directives,
  theme: {
    defaultTheme: 'light',
    themes: {
      light: {
        colors: {
          // Analytics Dashboard Palette (Modern & Professional)
          primary: '#3B82F6',        // Blue 500 (trust, clarity)
          secondary: '#60A5FA',      // Blue 400 (lighter accent)
          success: '#10B981',        // Emerald 500 (positive actions)
          warning: '#F59E0B',        // Amber 500 (cookie/highlights)
          error: '#EF4444',          // Red 500 (errors)
          info: '#3B82F6',           // Blue 500 (information)
          background: '#F8FAFC',     // Slate 50 (clean background)
          surface: '#FFFFFF',        // White (cards)
          'surface-variant': '#F1F5F9', // Slate 100 (card headers)
          'on-surface': '#1E293B',   // Slate 800 (text)
          'on-surface-variant': '#1E293B', // Ensure header text contrast
          'on-background': '#1E293B',
          'on-primary': '#FFFFFF',
          'on-secondary': '#FFFFFF',
          'on-success': '#FFFFFF',
          'on-warning': '#FFFFFF',
          'on-error': '#FFFFFF',
          'on-info': '#FFFFFF'
        }
      },
      dark: {
        colors: {
          primary: '#667eea',
          secondary: '#764ba2',
          background: '#0F172A',     // Slate 900
          surface: '#1E293B',        // Slate 800
          'surface-variant': '#334155' // Slate 700
        }
      }
    }
  }
})
