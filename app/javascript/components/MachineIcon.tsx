import {
  IconBrandApple,
  IconBrandDebian,
  IconBrandRedhat,
  IconBrandUbuntu,
  IconBrandWindows,
  IconDeviceDesktop,
  IconDeviceImac,
  IconDeviceLaptop,
  IconServer,
} from '@tabler/icons-react'

const KINDS = {
  laptop: IconDeviceLaptop,
  desktop: IconDeviceDesktop,
  'all-in-one': IconDeviceImac,
  server: IconServer,
}

function brandOf(os?: string | null, system?: string | null) {
  const named = (system ?? '').toLowerCase()

  if (os === 'darwin') return IconBrandApple
  if (os === 'windows') return IconBrandWindows
  if (named.includes('ubuntu')) return IconBrandUbuntu
  if (named.includes('debian') || named.includes('raspbian'))
    return IconBrandDebian
  if (/red hat|fedora|centos|rocky|alma/.test(named)) return IconBrandRedhat

  return null
}

export function MachineIcon({
  os,
  system,
  kind,
  size = 20,
}: {
  os?: string | null
  system?: string | null
  kind?: string | null
  size?: number
}) {
  const Kind =
    KINDS[kind as keyof typeof KINDS] ??
    (os === 'darwin' ? IconDeviceDesktop : IconServer)
  const Brand = brandOf(os, system)

  return (
    <span className="machine-glyph">
      <Kind size={size} stroke={1.5} />
      {Brand && (
        <span className="machine-glyph-os">
          <Brand size={Math.round(size * 0.45)} stroke={1.8} />
        </span>
      )}
    </span>
  )
}
