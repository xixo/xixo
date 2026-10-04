import { createTheme, type MantineColorsTuple } from '@mantine/core'

const night: MantineColorsTuple = [
  '#e8e9f7',
  '#c3c5e0',
  '#9497b8',
  '#6b6e94',
  '#4a4d72',
  '#3b3f66',
  '#1d1f38',
  '#15172b',
  '#0e0f1e',
  '#090a17',
]

const brand: MantineColorsTuple = [
  '#eeeeff',
  '#d9d9ff',
  '#bdbeff',
  '#a5a6ff',
  '#8384f5',
  '#6566ec',
  '#4a4be2',
  '#3a3bc4',
  '#2e2f9f',
  '#22237a',
]

export const theme = createTheme({
  colors: { dark: night, brand },
  primaryColor: 'brand',
  primaryShade: { light: 6, dark: 6 },
  autoContrast: true,
  defaultRadius: 'md',
  fontFamily: 'var(--sans)',
  fontFamilyMonospace: 'var(--mono)',
  headings: {
    fontFamily: 'var(--sans)',
    fontWeight: '700',
  },
  components: {
    Alert: {
      defaultProps: { radius: 'md', variant: 'light' },
    },
    Card: {
      defaultProps: { radius: 'md', withBorder: true, bg: 'var(--raised)' },
    },
    Code: {
      defaultProps: { color: 'var(--void)' },
    },
    Menu: {
      defaultProps: {
        radius: 'md',
        shadow: 'xl',
        transitionProps: { transition: 'pop-top-right', duration: 140 },
      },
    },
    Modal: {
      defaultProps: {
        radius: 'lg',
        overlayProps: { backgroundOpacity: 0.6, blur: 6 },
        transitionProps: { transition: 'pop', duration: 180 },
      },
    },
    Tooltip: {
      defaultProps: { radius: 'sm', openDelay: 250 },
    },
  },
})
