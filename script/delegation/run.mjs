import { createHash, randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import { chromium } from 'playwright'

const xixo = process.env.DELEGATION_XIXO
const masks = process.env.DELEGATION_ISSUER
const server = process.env.DELEGATION_SERVER
const password = process.env.DELEGATION_PASSWORD
const callbackPort = 8199
const callback = `http://127.0.0.1:${callbackPort}/cb`
const scope = 'openid xixo:mcp:call xixo:catalog:read'

const [step, who = 'ada', wait = '0'] = process.argv.slice(2)

async function browse(work) {
  const browser = await chromium.launch()
  const page = await (
    await browser.newContext({ viewport: { width: 1200, height: 1000 } })
  ).newPage()
  page.setDefaultTimeout(15000)

  try {
    return await work(page)
  } finally {
    await browser.close()
  }
}

async function signIn(page) {
  await page.locator('input[name=identifier]').fill(`${who}@example.test`)
  await page.getByRole('button', { name: 'Continue' }).click()
  await page.locator('input[type=password]').fill(password)
  await page.locator('input[type=password]').press('Enter')
}

async function allow(page, until) {
  for (let tries = 0; tries < 30 && !until(); tries++) {
    const button = page.getByRole('button', { name: 'Allow' })
    if (await button.count()) await button.click().catch(() => {})
    await page.waitForTimeout(500)
  }
}

async function row(page) {
  await page.goto(`${xixo}/settings/resources`)
  const name = page.getByText('stand-in', { exact: true })
  await name.waitFor()

  return (
    await name
      .locator('xpath=ancestor::*[contains(., "Put away")][1]')
      .innerText()
  ).replace(/\s*\n\s*/g, ' | ')
}

async function connect() {
  return browse(async (page) => {
    await page.goto(xixo)
    await page.getByText('Sign in').click()
    await signIn(page)
    await allow(page, () => page.url().startsWith(xixo))
    await page.waitForURL(`${xixo}/**`)

    await page.goto(`${xixo}/settings/resources`)
    await page.getByRole('button', { name: 'Attach one' }).click()
    await page.getByText('An MCP server', { exact: true }).click()

    const form = page.getByRole('dialog')
    await form.getByLabel(/prefix its tools/).fill('stand-in')
    await form.getByLabel(/^Called/).fill('Stand-in MCP')
    await form.getByText('Only me', { exact: true }).click()
    await form.getByLabel(/^Address/).fill(`${server}/mcp`)
    await form.getByLabel(/^Authentication/).click()
    await page.getByRole('option', { name: /through masks/ }).click()
    await form.getByLabel(/Provider in masks/).fill('stand-in')
    await form.getByRole('button', { name: 'Attach and connect' }).click()

    await page.waitForURL(`${masks}/**`)
    await allow(page, () => page.url().startsWith(xixo))
    await page.waitForURL(`${xixo}/settings/resources/**`)

    return { row: await row(page) }
  })
}

async function revoke() {
  return browse(async (page) => {
    await page.goto(masks)
    await signIn(page)

    const line = page.getByText('Xixo can use it while you are away')
    const entry = page.locator('details.entry', { has: line })
    await entry.locator('summary').click()
    page.once('dialog', (dialog) => dialog.accept())
    await entry.getByRole('button', { name: 'Stop' }).click()
    await line.waitFor({ state: 'detached' })

    return { revoked: true }
  })
}

async function listed() {
  return browse(async (page) => {
    await page.goto(xixo)
    await page.getByText('Sign in').click()
    await signIn(page)
    await allow(page, () => page.url().startsWith(xixo))
    await page.waitForURL(`${xixo}/**`)

    return { row: await row(page) }
  })
}

async function token() {
  const registered = await (
    await fetch(`${masks}/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        client_name: `delegation run as ${who}`,
        redirect_uris: [callback],
        token_endpoint_auth_method: 'none',
        grant_types: ['authorization_code'],
        response_types: ['code'],
        scope,
      }),
    })
  ).json()

  const verifier = randomBytes(32).toString('base64url')
  const challenge = createHash('sha256').update(verifier).digest('base64url')
  const resource = `${xixo}/mcp`

  let code = null
  let refused = null
  const listener = createServer((request, response) => {
    const given = new URL(request.url, callback).searchParams
    code = given.get('code')
    refused = given.get('error_description')
    response.end('ok')
  }).listen(callbackPort, '127.0.0.1')

  try {
    await browse(async (page) => {
      await page.goto(
        `${masks}/authorize?${new URLSearchParams({
          response_type: 'code',
          client_id: registered.client_id,
          redirect_uri: callback,
          scope,
          state: 'run',
          code_challenge: challenge,
          code_challenge_method: 'S256',
          resource,
        })}`,
      )
      await signIn(page)
      await allow(page, () => code || refused)
    })
  } finally {
    listener.close()
  }

  if (!code) throw new Error(`masks sent no code: ${refused}`)

  const issued = await (
    await fetch(`${masks}/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: callback,
        client_id: registered.client_id,
        code_verifier: verifier,
        resource,
      }),
    })
  ).json()

  if (!issued.access_token) throw new Error(JSON.stringify(issued))
  return issued.access_token
}

function session(bearer) {
  let id = null
  let next = 1

  return async (method, params, notify = false) => {
    const headers = {
      authorization: `Bearer ${bearer}`,
      'content-type': 'application/json',
      accept: 'application/json, text/event-stream',
    }
    if (id) headers['mcp-session-id'] = id

    const body = { jsonrpc: '2.0', method, params }
    if (!notify) body.id = next++

    const response = await fetch(`${xixo}/mcp`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    })
    id = response.headers.get('mcp-session-id') || id

    const text = await response.text()
    if (notify || !text) return null

    const data = text.split('\n').find((line) => line.startsWith('data:'))
    return JSON.parse(data ? data.slice(5) : text)
  }
}

async function mcp() {
  const call = session(await token())

  await call('initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'delegation run', version: '1' },
  })
  await call('notifications/initialized', {}, true)

  const listed = await call('tools/list', {})
  const whoami = async () => {
    const answered = await call('tools/call', {
      name: 'stand-in__whoami',
      arguments: {},
    })
    return answered.result
      ? answered.result.content.map((part) => part.text).join('')
      : `refused: ${answered.error.message}: ${answered.error.data ?? ''}`
  }

  const found = {
    offered: listed.result.tools
      .map((tool) => tool.name)
      .filter((name) => name.startsWith('stand-in')),
    said: await whoami(),
  }

  if (Number(wait) > 0) {
    await new Promise((done) => setTimeout(done, Number(wait) * 1000))
    found.later = await whoami()
  }

  return found
}

const steps = { connect, revoke, listed, mcp }

if (!steps[step]) {
  console.error(`no step named ${step}: ${Object.keys(steps).join(', ')}`)
  process.exit(64)
}

try {
  console.log(JSON.stringify(await steps[step]()))
} catch (error) {
  console.error(error.message.split('\n')[0])
  process.exit(1)
}
