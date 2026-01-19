import 'vuetify/styles'
import { createVuetify } from 'vuetify'
import * as components from 'vuetify/components'
import * as directives from 'vuetify/directives'
import '@mdi/font/css/materialdesignicons.css'

export default createVuetify({
  components,
  directives,
  theme: {
    defaultTheme: 'light',
    themes: {
      light: {
        colors: {
          primary: '#2563EB', // Modern Blue
          secondary: '#475569', // Slate 600
          background: '#F1F5F9', // Slate 100
          surface: '#FFFFFF',
          error: '#EF4444',
          success: '#10B981',
          warning: '#F59E0B',
          info: '#3B82F6',
        }
      },
      dark: {
        colors: {
          primary: '#60A5FA',
          secondary: '#94A3B8',
          background: '#0F172A',
          surface: '#1E293B',
        }
      }
    }
  }
})

