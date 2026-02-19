import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import {
  parseInteractionPayload,
  parseActionValue,
  processInteraction,
} from '../../src/interactions/actions'
import { loadState, saveState } from '../../src/state'
import type { SessionState } from '../../src/evaluator'
import type { Session } from '../../src/parser'
import registeredFixture from '../fixtures/slack-interaction-registered.json'
import dismissedFixture from '../fixtures/slack-interaction-dismissed.json'
import remindFixture from '../fixtures/slack-interaction-remind.json'

const testDataDir = path.join(__dirname, '../../data/test-actions')
const testStatePath = path.join(testDataDir, 'state.json')

const createSession = (overrides: Partial<Session> = {}): Session => ({
  date: '2026-02-20',
  dayOfWeek: 'Friday',
  time: '05:50',
  timeLabel: '5:50am - 7:00am',
  eventName: '(PLAYERS) ADULT Pick Up MORNINGS',
  playersRegistered: 14,
  playersMax: 24,
  goaliesRegistered: 2,
  goaliesMax: 3,
  isFull: false,
  price: 15,
  ...overrides,
})

const createState = (
  session: Session,
  overrides: Partial<Omit<SessionState, 'session'>> = {}
): SessionState => ({
  session,
  lastAlertType: null,
  lastAlertAt: null,
  lastPlayerCount: null,
  isRegistered: false,
  userResponse: null,
  userRespondedAt: null,
  remindAfter: null,
  ...overrides,
})

describe('parseInteractionPayload', () => {
  it('parses a valid block_actions payload', () => {
    const result = parseInteractionPayload(registeredFixture)

    expect(result).not.toBeNull()
    expect(result!.actionId).toBe('session_registered')
    expect(result!.value).toBe('2026-02-20|05:50|(PLAYERS) ADULT Pick Up MORNINGS')
    expect(result!.responseUrl).toBe('https://hooks.slack.com/actions/T00/B00/test')
  })

  it('parses dismissed action payload', () => {
    const result = parseInteractionPayload(dismissedFixture)

    expect(result).not.toBeNull()
    expect(result!.actionId).toBe('session_not_interested')
  })

  it('parses remind action payload', () => {
    const result = parseInteractionPayload(remindFixture)

    expect(result).not.toBeNull()
    expect(result!.actionId).toBe('session_remind_later')
  })

  it('returns null for non-block_actions type', () => {
    const result = parseInteractionPayload({ type: 'view_submission', actions: [] })

    expect(result).toBeNull()
  })

  it('returns null for empty actions array', () => {
    const result = parseInteractionPayload({
      type: 'block_actions',
      actions: [],
      response_url: 'https://hooks.slack.com/test',
    })

    expect(result).toBeNull()
  })

  it('returns null for null payload', () => {
    expect(parseInteractionPayload(null)).toBeNull()
  })

  it('returns null for non-object payload', () => {
    expect(parseInteractionPayload('string')).toBeNull()
  })

  it('returns null when response_url is missing', () => {
    const result = parseInteractionPayload({
      type: 'block_actions',
      actions: [{ action_id: 'test', value: 'test' }],
    })

    expect(result).toBeNull()
  })
})

describe('parseActionValue', () => {
  it('parses a valid pipe-delimited value', () => {
    const result = parseActionValue('2026-02-20|05:50|(PLAYERS) ADULT Pick Up MORNINGS')

    expect(result).not.toBeNull()
    expect(result!.date).toBe('2026-02-20')
    expect(result!.time).toBe('05:50')
    expect(result!.eventName).toBe('(PLAYERS) ADULT Pick Up MORNINGS')
  })

  it('handles event names containing pipes', () => {
    const result = parseActionValue('2026-02-20|05:50|Name|With|Pipes')

    expect(result).not.toBeNull()
    expect(result!.eventName).toBe('Name|With|Pipes')
  })

  it('returns null for fewer than 3 parts', () => {
    expect(parseActionValue('2026-02-20|05:50')).toBeNull()
  })

  it('returns null for empty string', () => {
    expect(parseActionValue('')).toBeNull()
  })
})

describe('processInteraction', () => {
  beforeEach(() => {
    if (!fs.existsSync(testDataDir)) {
      fs.mkdirSync(testDataDir, { recursive: true })
    }
  })

  afterEach(() => {
    if (fs.existsSync(testStatePath)) {
      fs.unlinkSync(testStatePath)
    }
  })

  it('processes session_registered and updates state', () => {
    const session = createSession()
    saveState(testStatePath, [createState(session)])

    const result = processInteraction(testStatePath, registeredFixture, 2)

    expect(result).not.toBeNull()
    expect(result!.userResponse).toBe('registered')
    expect(result!.found).toBe(true)
    expect(result!.date).toBe('2026-02-20')
    expect(result!.time).toBe('05:50')

    const state = loadState(testStatePath)
    expect(state[0].isRegistered).toBe(true)
    expect(state[0].userResponse).toBe('registered')
    expect(state[0].userRespondedAt).toBeDefined()
    expect(state[0].remindAfter).toBeNull()
  })

  it('processes session_not_interested and updates state', () => {
    const session = createSession()
    saveState(testStatePath, [createState(session)])

    const result = processInteraction(testStatePath, dismissedFixture, 2)

    expect(result).not.toBeNull()
    expect(result!.userResponse).toBe('not_interested')
    expect(result!.found).toBe(true)

    const state = loadState(testStatePath)
    expect(state[0].isRegistered).toBe(false)
    expect(state[0].userResponse).toBe('not_interested')
  })

  it('processes session_remind_later and sets remindAfter', () => {
    const session = createSession()
    saveState(testStatePath, [createState(session)])

    const before = Date.now()
    const result = processInteraction(testStatePath, remindFixture, 2)
    const after = Date.now()

    expect(result).not.toBeNull()
    expect(result!.userResponse).toBe('remind_later')
    expect(result!.found).toBe(true)

    const state = loadState(testStatePath)
    expect(state[0].userResponse).toBe('remind_later')
    expect(state[0].remindAfter).toBeDefined()

    const remindAfter = new Date(state[0].remindAfter!).getTime()
    expect(remindAfter).toBeGreaterThanOrEqual(before + 2 * 60 * 60 * 1000)
    expect(remindAfter).toBeLessThanOrEqual(after + 2 * 60 * 60 * 1000)
  })

  it('returns found=false when session not in state', () => {
    // State has a different session time than what the fixture references
    const session = createSession({ time: '18:30' })
    saveState(testStatePath, [createState(session)])

    const result = processInteraction(testStatePath, registeredFixture, 2)

    expect(result).not.toBeNull()
    expect(result!.found).toBe(false)

    // State should not be modified
    const state = loadState(testStatePath)
    expect(state[0].userResponse).toBeNull()
  })

  it('returns null for invalid payload', () => {
    const result = processInteraction(testStatePath, { type: 'invalid' }, 2)

    expect(result).toBeNull()
  })

  it('returns null for unrecognized action_id', () => {
    const payload = {
      type: 'block_actions',
      actions: [{ action_id: 'unknown_action', value: '2026-02-20|05:50|Test' }],
      response_url: 'https://hooks.slack.com/test',
    }

    const result = processInteraction(testStatePath, payload, 2)

    expect(result).toBeNull()
  })

  it('returns responseUrl from payload', () => {
    const session = createSession()
    saveState(testStatePath, [createState(session)])

    const result = processInteraction(testStatePath, registeredFixture, 2)

    expect(result!.responseUrl).toBe('https://hooks.slack.com/actions/T00/B00/test')
  })

  it('uses configurable remind interval', () => {
    const session = createSession()
    saveState(testStatePath, [createState(session)])

    const before = Date.now()
    processInteraction(testStatePath, remindFixture, 4) // 4 hours
    const after = Date.now()

    const state = loadState(testStatePath)
    const remindAfter = new Date(state[0].remindAfter!).getTime()
    expect(remindAfter).toBeGreaterThanOrEqual(before + 4 * 60 * 60 * 1000)
    expect(remindAfter).toBeLessThanOrEqual(after + 4 * 60 * 60 * 1000)
  })
})
