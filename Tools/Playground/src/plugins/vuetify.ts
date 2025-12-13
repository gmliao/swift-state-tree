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
          primary: '#1976d2', // blue-darken-2
          secondary: '#424242',
          background: '#f5f5f5',
          surface: '#ffffff',
        }
      },
      dark: {
        colors: {
          primary: '#667eea',
          secondary: '#764ba2',
        }
      }
    }
  }
})

