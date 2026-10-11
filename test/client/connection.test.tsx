import { act, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, test, vi } from 'vitest'
import { Connection } from '../../app/javascript/components/Connection'
import { cableChanged } from '../../app/javascript/connection'

const online = (value: boolean) => {
  vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(value)
  window.dispatchEvent(new Event(value ? 'online' : 'offline'))
}

afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
  act(() => cableChanged(true))
})

describe('Connection', () => {
  test('says nothing while live updates flow', () => {
    const { container } = render(<Connection />)

    expect(container.textContent).toBe('')
  })

  test('says so at once when the device goes offline', () => {
    render(<Connection />)

    act(() => online(false))

    expect(screen.getByRole('status').textContent).toMatch(
      /This device is offline/,
    )
  })

  test('waits out a brief drop before saying live updates stopped', () => {
    vi.useFakeTimers()
    render(<Connection />)

    act(() => cableChanged(false))
    expect(screen.queryByRole('status')).toBeNull()

    act(() => vi.advanceTimersByTime(4000))
    expect(screen.getByRole('status').textContent).toMatch(
      /Live updates stopped/,
    )

    act(() => cableChanged(true))
    expect(screen.queryByRole('status')).toBeNull()
  })
})
