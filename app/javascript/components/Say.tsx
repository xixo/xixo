import { CloseButton } from '@mantine/core'
import { IconAlertTriangle, IconCheck } from '@tabler/icons-react'
import { useMutation } from 'xixo/react'
import {
  type CSSProperties,
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react'

type Document<TData, TVariables extends Record<string, unknown>> = Parameters<
  typeof useMutation<TData, TVariables>
>[0]

interface Word {
  text: string
  wrong?: boolean
}

type Spoken = Word & { id: number }

const HELD = { right: 4000, wrong: 9000 }

const SayContext = createContext<((word: Word) => void) | null>(null)

export function SayProvider({ children }: { children: ReactNode }) {
  const [spoken, setSpoken] = useState<Spoken[]>([])
  const counted = useRef(0)
  const timers = useRef<number[]>([])

  useEffect(
    () => () => {
      for (const timer of timers.current) window.clearTimeout(timer)
    },
    [],
  )

  const hush = useCallback((id: number) => {
    setSpoken((held) => held.filter((word) => word.id !== id))
  }, [])

  const say = useCallback(
    (word: Word) => {
      counted.current += 1

      const id = counted.current

      setSpoken((held) => [...held.slice(-3), { ...word, id }])
      timers.current.push(
        window.setTimeout(() => hush(id), word.wrong ? HELD.wrong : HELD.right),
      )
    },
    [hush],
  )

  return (
    <SayContext.Provider value={say}>
      {children}

      <div className="says" role="status" aria-live="polite">
        {spoken.map((word) => (
          <div
            key={word.id}
            className="say"
            style={
              {
                '--tone': word.wrong ? 'var(--bad)' : 'var(--ok)',
              } as CSSProperties
            }
          >
            {word.wrong ? (
              <IconAlertTriangle size={16} stroke={1.8} color="var(--bad)" />
            ) : (
              <IconCheck size={16} stroke={2} color="var(--ok)" />
            )}

            <span className="say-text">{word.text}</span>

            <CloseButton size="sm" onClick={() => hush(word.id)} />
          </div>
        ))}
      </div>
    </SayContext.Provider>
  )
}

export function useSay() {
  const say = useContext(SayContext)

  if (!say) throw new Error('useSay must be used inside a SayProvider')

  return say
}

export function useAloud<TData, TVariables extends Record<string, unknown>>(
  mutation: Document<TData, TVariables>,
  refused: string,
) {
  const say = useSay()
  const { execute, loading, error } = useMutation(mutation)

  useEffect(() => {
    if (error) say({ text: error.message || refused, wrong: true })
  }, [error, refused, say])

  return { execute, loading, error }
}
