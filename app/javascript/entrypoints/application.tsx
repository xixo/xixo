import '@mantine/core/styles.css'
import '../styles/xixo.css'

import { MantineProvider } from '@mantine/core'
import { XixoProvider } from '@xixo/client/react'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { App } from '../components/App'
import { Fallen } from '../components/Fallen'
import { theme } from '../theme'
import { client } from '../xixo'

const root = document.getElementById('root')

if (root) {
  createRoot(root).render(
    <StrictMode>
      <MantineProvider theme={theme} forceColorScheme="dark">
        <XixoProvider client={client}>
          <BrowserRouter>
            <Fallen what="xixo could not start">
              <App />
            </Fallen>
          </BrowserRouter>
        </XixoProvider>
      </MantineProvider>
    </StrictMode>,
  )
}
