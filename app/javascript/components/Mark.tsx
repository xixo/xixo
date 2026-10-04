const STROKES = 'M109 160 L230 303 L351 160 M109 300 L230 157 L351 300'

export function Mark({
  size = 26,
  bare = false,
}: {
  size?: number
  bare?: boolean
}) {
  return (
    <svg
      width={size}
      height={bare ? (size * 192) / 288 : size}
      viewBox={bare ? '86 134 288 192' : '0 0 460 460'}
      role="img"
      aria-label="xixo"
    >
      {!bare && <rect width="460" height="460" rx="96" fill="var(--brand)" />}
      <path
        d={STROKES}
        fill="none"
        stroke={bare ? 'currentColor' : '#fff'}
        strokeWidth="46"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}
