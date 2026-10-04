import type { RowFragment } from '@xixo/client'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, test } from 'vitest'
import { AnswerText } from '../../app/javascript/components/Answer'

const invoice = {
  id: '12',
  type: 'xixo:file',
  key: 'invoice.pdf',
  title: 'invoice.pdf',
} as RowFragment

function render(said: string, cited: RowFragment[] = [invoice]) {
  return renderToStaticMarkup(
    <MemoryRouter>
      <AnswerText said={said} cited={cited} />
    </MemoryRouter>,
  )
}

describe('AnswerText', () => {
  test('markdown becomes markup', () => {
    const html = render('**£880**, billed by Bellwether\n\n- one\n- two')

    expect(html).toContain('<strong>£880</strong>')
    expect(html).toContain('<li>one</li>')
  })

  test('a citation is a link to the feed it names, and one it cannot name disappears', () => {
    const html = render('It was £880 [feed 12], or maybe [feed 99].')

    expect(html).toContain('href="/items/12"')
    expect(html).toContain('>invoice.pdf</a>')
    expect(html).not.toContain('feed 99')
  })

  test('raw html in an answer is shown as text, never run', () => {
    const html = render('<script>alert(1)</script><img src=x onerror=alert(1)>')

    expect(html).not.toContain('<script>')
    expect(html).not.toContain('<img')
  })

  test('a link to anything but the web or mail is dropped', () => {
    const html = render('[click](javascript:alert(1)) and [site](https://example.com)')

    expect(html).not.toContain('javascript:')
    expect(html).toContain('href="https://example.com"')
    expect(html).toContain('rel="noreferrer noopener"')
  })
})
