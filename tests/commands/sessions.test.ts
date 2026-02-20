import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import crypto from 'crypto'
import fs from 'fs'
import path from 'path'
import type { Server } from 'http'
import type { Session } from '../../src/parser'
import type { SessionState } from '../../src/state'
import type { AlertType, UserResponse } from '../../src/evaluator'
import { buildSessionsResponse } from '../../src/commands/sessions'
import { createServer } from '../../src/server'

// --- Factory helpers ---

function createSession(overrides: Partial<Session> = {}): Session {
  return {
    date: '2026-02-20',
    dayOfWeek: 'Friday',
    time: '05:50',
    timeLabel: '5:50am - 7:10am',
    eventName: '(PLAYERS) ADULT Pick Up MORNINGS',
    playersRegistered: 12,
    playersMax: 24,
    goaliesRegistered: 2,
    goaliesMax: 2,
    isFull: false,
    price: 25,
    ...overrides,
  }
}

function createState(
  session: Session,
  overrides: Partial<Omit<SessionState, 'session'>> = {}
): SessionState {
  return {
    session,
    lastAlertType: null,
    lastAlertAt: null,
    lastPlayerCount: null,
    isRegistered: false,
    userResponse: null,
    userRespondedAt: null,
    remindAfter: null,
    ...overrides,
  }
}

// --- Unit tests: buildSessionsResponse ---

describe('buildSessionsResponse', () => {
  it('returns no-sessions message when state is empty', () => {
    const result = buildSessionsResponse([], null)

    expect(result.response_type).toBe('ephemeral')
    expect(result.blocks).toBeDefined()
    expect(result.blocks.length).toBeGreaterThanOrEqual(1)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('No sessions currently tracked')
  })

  it('returns formatted sessions when state has entries', () => {
    const session = createSession()
    const state = [createState(session)]

    const result = buildSessionsResponse(state, '2026-02-20T10:00:00.000Z')

    expect(result.response_type).toBe('ephemeral')
    expect(result.blocks.length).toBeGreaterThan(1)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('12/24')
    expect(text).toContain('5:50am')
    expect(text).toContain('Feb 20')
  })

  it('sorts sessions by date then time ascending', () => {
    const laterSession = createSession({
      date: '2026-02-21',
      dayOfWeek: 'Saturday',
      time: '11:45',
    })
    const earlierSession = createSession({
      date: '2026-02-20',
      dayOfWeek: 'Friday',
      time: '05:50',
    })
    const sameDayLaterTime = createSession({
      date: '2026-02-20',
      dayOfWeek: 'Friday',
      time: '11:45',
    })

    // Provide in non-sorted order
    const state = [
      createState(laterSession),
      createState(sameDayLaterTime),
      createState(earlierSession),
    ]

    const result = buildSessionsResponse(state, null)

    // Extract all section block texts to check ordering
    const sectionTexts = result.blocks
      .filter((b) => b.type === 'section' && b.text?.text)
      .map((b) => b.text!.text)

    // First section should be Feb 20 5:50am, then Feb 20 11:45am, then Feb 21
    expect(sectionTexts.length).toBe(3)
    expect(sectionTexts[0]).toContain('Feb 20')
    expect(sectionTexts[0]).toContain('5:50am')
    expect(sectionTexts[1]).toContain('Feb 20')
    expect(sectionTexts[1]).toContain('11:45am')
    expect(sectionTexts[2]).toContain('Feb 21')
  })

  it('shows full status clearly for full sessions', () => {
    const fullSession = createSession({
      playersRegistered: 24,
      playersMax: 24,
      isFull: true,
    })
    const state = [createState(fullSession)]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('FULL')
  })

  it('shows open status for non-full sessions', () => {
    const openSession = createSession({
      playersRegistered: 12,
      playersMax: 24,
      isFull: false,
    })
    const state = [createState(openSession)]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('Open')
  })

  it('displays alert status when an alert was fired', () => {
    const session = createSession()
    const state = [
      createState(session, {
        lastAlertType: 'FILLING_FAST' as AlertType,
        lastAlertAt: '2026-02-20T08:00:00.000Z',
      }),
    ]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('FILLING FAST')
  })

  it('displays user response when user has responded', () => {
    const session = createSession()
    const state = [
      createState(session, {
        userResponse: 'registered' as UserResponse,
        userRespondedAt: '2026-02-20T09:00:00.000Z',
      }),
    ]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('Registered')
  })

  it('displays Not Interested user response', () => {
    const session = createSession()
    const state = [
      createState(session, {
        userResponse: 'not_interested' as UserResponse,
        userRespondedAt: '2026-02-20T09:00:00.000Z',
      }),
    ]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('Not Interested')
  })

  it('displays Remind Later user response', () => {
    const session = createSession()
    const state = [
      createState(session, {
        userResponse: 'remind_later' as UserResponse,
        userRespondedAt: '2026-02-20T09:00:00.000Z',
        remindAfter: '2026-02-20T11:00:00.000Z',
      }),
    ]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('Remind Later')
  })

  it('includes last poll time in footer', () => {
    const session = createSession()
    const state = [createState(session)]

    const result = buildSessionsResponse(state, '2026-02-20T10:00:00.000Z')

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('Last polled')
  })

  it('includes registration link for each session', () => {
    const session = createSession({ date: '2026-02-20' })
    const state = [createState(session)]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('apps.daysmartrecreation.com')
    expect(text).toContain('2026-02-20')
  })

  it('includes header block', () => {
    const session = createSession()
    const state = [createState(session)]

    const result = buildSessionsResponse(state, null)

    const header = result.blocks.find((b) => b.type === 'header')
    expect(header).toBeDefined()
    expect(header!.text!.text).toContain('Hockey Sessions')
  })

  it('shows goalie count', () => {
    const session = createSession({ goaliesRegistered: 1, goaliesMax: 2 })
    const state = [createState(session)]

    const result = buildSessionsResponse(state, null)

    const text = JSON.stringify(result.blocks)
    expect(text).toContain('1/2')
  })
})

// --- Integration tests: POST /slack/commands ---

const SIGNING_SECRET = 'test-commands-secret'
const TEST_PORT = 3997
const TEST_STATE_PATH = './data/test-commands-state.json'

function signRequest(secret: string, body: string): { signature: string; timestamp: string } {
  const timestamp = Math.floor(Date.now() / 1000).toString()
  const sigBasestring = `v0:${timestamp}:${body}`
  const signature = 'v0=' + crypto.createHmac('sha256', secret).update(sigBasestring).digest('hex')
  return { signature, timestamp }
}

describe('POST /slack/commands', () => {
  let server: Server

  beforeEach(() => {
    const stateDir = path.dirname(TEST_STATE_PATH)
    if (!fs.existsSync(stateDir)) {
      fs.mkdirSync(stateDir, { recursive: true })
    }
  })

  afterEach(
    () =>
      new Promise<void>((resolve) => {
        if (fs.existsSync(TEST_STATE_PATH)) {
          fs.unlinkSync(TEST_STATE_PATH)
        }
        if (server) {
          server.close(() => resolve())
        } else {
          resolve()
        }
      })
  )

  async function startTestServer(): Promise<void> {
    const app = createServer({
      statePath: TEST_STATE_PATH,
      slackSigningSecret: SIGNING_SECRET,
    })
    return new Promise((resolve) => {
      server = app.listen(TEST_PORT, () => resolve())
    })
  }

  it('returns 200 with Block Kit response for valid signed request with sessions', async () => {
    const testState: SessionState[] = [createState(createSession())]
    fs.writeFileSync(TEST_STATE_PATH, JSON.stringify(testState, null, 2))

    await startTestServer()

    const body = 'command=%2Fsessions&text=&user_id=U123&channel_id=C123'
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/commands`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(200)

    const data = await response.json()
    expect(data.response_type).toBe('ephemeral')
    expect(data.blocks).toBeDefined()
    expect(data.blocks.length).toBeGreaterThan(1)
  })

  it('returns 200 with no-sessions message for empty state', async () => {
    fs.writeFileSync(TEST_STATE_PATH, '[]')

    await startTestServer()

    const body = 'command=%2Fsessions&text=&user_id=U123&channel_id=C123'
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/commands`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(200)

    const data = await response.json()
    expect(data.response_type).toBe('ephemeral')
    const text = JSON.stringify(data.blocks)
    expect(text).toContain('No sessions currently tracked')
  })

  it('returns 401 for invalid signature', async () => {
    await startTestServer()

    const body = 'command=%2Fsessions&text=&user_id=U123&channel_id=C123'
    const timestamp = Math.floor(Date.now() / 1000).toString()

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/commands`, {
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

  it('returns 401 for expired timestamp', async () => {
    await startTestServer()

    const body = 'command=%2Fsessions&text=&user_id=U123&channel_id=C123'
    // 6 minutes ago (beyond 5-minute window)
    const timestamp = (Math.floor(Date.now() / 1000) - 360).toString()
    const sigBasestring = `v0:${timestamp}:${body}`
    const signature =
      'v0=' + crypto.createHmac('sha256', SIGNING_SECRET).update(sigBasestring).digest('hex')

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/commands`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'x-slack-signature': signature,
        'x-slack-request-timestamp': timestamp,
      },
      body,
    })

    expect(response.status).toBe(401)
  })

  it('returns 400 for unknown command', async () => {
    await startTestServer()

    const body = 'command=%2Funknown&text=&user_id=U123&channel_id=C123'
    const { signature, timestamp } = signRequest(SIGNING_SECRET, body)

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/commands`, {
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

  it('returns 400 when signature headers are missing', async () => {
    await startTestServer()

    const body = 'command=%2Fsessions&text=&user_id=U123&channel_id=C123'

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/commands`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body,
    })

    expect(response.status).toBe(400)
  })

  it('returns 404 when commands route is not configured (no signing secret)', async () => {
    const app = createServer({ statePath: TEST_STATE_PATH })
    await new Promise<void>((resolve) => {
      server = app.listen(TEST_PORT, () => resolve())
    })

    const body = 'command=%2Fsessions&text=&user_id=U123&channel_id=C123'

    const response = await fetch(`http://localhost:${TEST_PORT}/slack/commands`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    })

    expect(response.status).toBe(404)
  })
})
