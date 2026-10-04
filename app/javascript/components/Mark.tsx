const LETTERS = [
  {
    d: 'M0.409 20.181 L4.045 5.636 L6.955 6.364 L3.319 20.909 A1.5 1.5 0 0 1 0.409 20.181 Z',
    tone: 'var(--k-pdf)',
  },
  {
    d: 'M6.045 21.636 L9.681 7.091 A1.5 1.5 0 0 1 11.5 6 L12.955 6.364 L8.955 22.364 Z',
    tone: 'var(--k-contact)',
  },
  {
    d: 'M12.045 21.636 L16.045 5.636 L18.955 6.364 L14.955 22.364 Z',
    tone: 'var(--k-text)',
  },
  {
    d: 'M18.045 21.636 L21.681 7.091 A1.5 1.5 0 0 1 23.5 6 L24.955 6.364 L21.319 20.909 A1.5 1.5 0 0 1 19.5 22 Z',
    tone: 'var(--k-image)',
  },
]

export function Mark({ size = 26 }: { size?: number }) {
  return (
    <svg
      width={(size * 25) / 28}
      height={size}
      viewBox="0 0 25 28"
      role="img"
      aria-label="xixo"
    >
      {LETTERS.map((letter) => (
        <path key={letter.d} d={letter.d} fill={letter.tone} />
      ))}
    </svg>
  )
}
