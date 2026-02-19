import { describe, it, expect, afterEach } from 'vitest'
import crypto from 'crypto'
import type { Server } from 'http'
import { createServer } from '../../src/server'
import registeredFixture from '../fixtures/slack-interaction-registered.json'
import dismissedFixture from '../fixtures/slack-interaction-dismissed.json'
import remindFixture from '../fixtures/slack-interaction-remind.json'

const SIGNING_SECRET = 'test-handler-secret'
const TEST_PORT = 3998

function signRequest(secret: string, body: string): { signature: string; timestamp: string } {
  const timestamp = Math.floor(Date.now() / 1000).toString()
  const sigBasestring = `v0:${timestamp}:${body}`
  const signature = 'v0=' + crypto.createHmac('sha256', secret).update(sigBasestring).digest('hex')
  return { signature, timestamp }
}

describe('POST /slack/interactions', () => {
  let server: Server

  afterEach(
    () =>
      new Promise<void>((resolve) => {
        if (server) {
          server.close(() => resolve())
        } else {
          resolve()
        }
      })
  )

  async function startTestServer(): Promise<void> {
    const app = createServer({
      statePath: './data/test-state.json',
      slackSigningSecret: SIGNING_SECRET,
    })
    return new Promise((resolve) => {
      server = app.listen(TEST_PORT, () => resolve())
    })
  }

  it('returns 200 for valid signed request with registered action', async () => {
    await startTestServer()

    const body = `payload=${encodeURIComponent(JSON.stringify(registeredFixture))}`
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(200)
  })

  it('returns 200 for valid signed request with dismissed action', async () => {
    await startTestServer()

    const body = `payload=${encodeURIComponent(JSON.stringify(dismissedFixture))}`
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(200)
  })

  it('returns 200 for valid signed request with remind action', async () => {
    await startTestServer()

    const body = `payload=${encodeURIComponent(JSON.stringify(remindFixture))}`
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(200)
  })

  it('returns 401 for invalid signature', async () => {
    await startTestServer()

    const body = `payload=${encodeURIComponent(JSON.stringify(registeredFixture))}`
    const timestamp = Math.floor(Date.now() / 1000).toString()

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': 'v0=invalid',
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(401)
  })

  it('returns 400 when signature headers are missing', async () => {
    await startTestServer()

    const body = `payload=${encodeURIComponent(JSON.stringify(registeredFixture))}`

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body,
    })

    expect(response.status).toBe(400)
  })

  it('returns 400 when payload field is missing', async () => {
    await startTestServer()

    const body = 'not_payload=test'
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(400)
  })

  it('returns 400 when payload JSON is invalid', async () => {
    await startTestServer()

    const body = `payload=${encodeURIComponent('{invalid json}')}`
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(400)
  })

  it('returns 404 when interactions route is not configured (no signing secret)', async () => {
    const app = createServer({ statePath: './data/test-state.json' })
    await new Promise<void>((resolve) => {
      server = app.listen(TEST_PORT, () => resolve())
    })

    const body = `payload=${encodeURIComponent(JSON.stringify(registeredFixture))}`

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/interactions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    })

    expect(response.status).toBe(404)
  })
})
