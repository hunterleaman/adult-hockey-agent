import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import {
  loadState,
  saveState,
  pruneOldSessions,
  updateRegistrationStatus,
  updateSessionState,
} from '../src/state'
import type { SessionState } from '../src/evaluator'
import type { Session } from '../src/parser'

describe('state', () => {
  const testDataDir = path.join(__dirname, '../data/test')
  const testStatePath = path.join(testDataDir, 'state.json')

  const createSession = (overrides: Partial<Session> = {}): Session => ({
    date: '2026-02-20',
    dayOfWeek: 'Friday',
    time: '06:00',
    timeLabel: '6:00am - 7:10am',
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
    ...overrides,
  })

  beforeEach(() => {
    // Ensure test data directory exists
    if (!fs.existsSync(testDataDir)) {
      fs.mkdirSync(testDataDir, { recursive: true })
    }
  })

  afterEach(() => {
    // Clean up test state file
    if (fs.existsSync(testStatePath)) {
      fs.unlinkSync(testStatePath)
    }
  })

  describe('loadState', () => {
    it('returns empty array when state file does not exist', () => {
      const state = loadState(testStatePath)

      expect(state).toEqual([])
    })

    it('loads state from existing file', () => {
      const session = createSession()
      const expectedState = [createState(session)]

      fs.writeFileSync(testStatePath, JSON.stringify(expectedState, null, 2))

      const state = loadState(testStatePath)

      expect(state).toEqual(expectedState)
    })

    it('returns empty array when state file is empty', () => {
      fs.writeFileSync(testStatePath, '')

      const state = loadState(testStatePath)

      expect(state).toEqual([])
    })

    it('returns empty array when state file contains invalid JSON', () => {
      fs.writeFileSync(testStatePath, '{invalid json}')

      const state = loadState(testStatePath)

      expect(state).toEqual([])
    })

    it('handles corrupted state file gracefully', () => {
      fs.writeFileSync(testStatePath, '{"data": [partially written')

      const state = loadState(testStatePath)

      expect(state).toEqual([])
    })
  })

  describe('saveState', () => {
    it('creates new state file with data', () => {
      const session = createSession()
      const state = [createState(session)]

      saveState(testStatePath, state)

      expect(fs.existsSync(testStatePath)).toBe(true)
      const saved = JSON.parse(fs.readFileSync(testStatePath, 'utf-8'))
      expect(saved).toEqual(state)
    })

    it('overwrites existing state file', () => {
      const session1 = createSession({ time: '06:00' })
      const session2 = createSession({ time: '18:30' })
      const initialState = [createState(session1)]
      const newState = [createState(session2)]

      saveState(testStatePath, initialState)
      saveState(testStatePath, newState)

      const saved = JSON.parse(fs.readFileSync(testStatePath, 'utf-8'))
      expect(saved).toEqual(newState)
      expect(saved).toHaveLength(1)
      expect(saved[0].session.time).toBe('18:30')
    })

    it('saves empty array', () => {
      saveState(testStatePath, [])

      const saved = JSON.parse(fs.readFileSync(testStatePath, 'utf-8'))
      expect(saved).toEqual([])
    })

    it('creates parent directory if it does not exist', () => {
      const nestedPath = path.join(testDataDir, 'nested', 'deep', 'state.json')

      saveState(nestedPath, [])

      expect(fs.existsSync(nestedPath)).toBe(true)

      // Cleanup
      fs.rmSync(path.join(testDataDir, 'nested'), { recursive: true })
    })

    it('uses atomic write (temp file + rename)', () => {
      const session = createSession()
      const state = [createState(session)]

      saveState(testStatePath, state)

      // Verify no temp files left behind
      const tempFiles = fs
        .readdirSync(testDataDir)
        .filter((f) => f.startsWith('.state') && f.endsWith('.tmp'))
      expect(tempFiles).toHaveLength(0)
    })
  })

  describe('pruneOldSessions', () => {
    it('removes sessions older than today', () => {
      const today = new Date('2026-02-20T12:00:00Z')
      const yesterday = createSession({ date: '2026-02-19' })
      const todaySession = createSession({ date: '2026-02-20' })
      const tomorrow = createSession({ date: '2026-02-21' })

      const state = [
        createState(yesterday),
        createState(todaySession),
        createState(tomorrow),
      ]

      const pruned = pruneOldSessions(state, today)

      expect(pruned).toHaveLength(2)
      expect(pruned.find((s) => s.session.date === '2026-02-19')).toBeUndefined()
      expect(pruned.find((s) => s.session.date === '2026-02-20')).toBeDefined()
      expect(pruned.find((s) => s.session.date === '2026-02-21')).toBeDefined()
    })

    it('keeps sessions equal to today', () => {
      const today = new Date('2026-02-20T12:00:00Z')
      const todayMorning = createSession({ date: '2026-02-20', time: '06:00' })
      const todayEvening = createSession({ date: '2026-02-20', time: '18:30' })

      const state = [createState(todayMorning), createState(todayEvening)]

      const pruned = pruneOldSessions(state, today)

      expect(pruned).toHaveLength(2)
    })

    it('returns empty array when all sessions are old', () => {
      const today = new Date('2026-02-20T12:00:00Z')
      const old1 = createSession({ date: '2026-02-18' })
      const old2 = createSession({ date: '2026-02-19' })

      const state = [createState(old1), createState(old2)]

      const pruned = pruneOldSessions(state, today)

      expect(pruned).toEqual([])
    })

    it('returns same array when no sessions are old', () => {
      const today = new Date('2026-02-20T12:00:00Z')
      const future1 = createSession({ date: '2026-02-21' })
      const future2 = createSession({ date: '2026-02-22' })

      const state = [createState(future1), createState(future2)]

      const pruned = pruneOldSessions(state, today)

      expect(pruned).toEqual(state)
    })

    it('uses current date when no date parameter provided', () => {
      // Create session for yesterday (relative to actual current date)
      const yesterday = new Date()
      yesterday.setDate(yesterday.getDate() - 1)
      const yesterdayStr = yesterday.toISOString().split('T')[0]

      const oldSession = createSession({ date: yesterdayStr })
      const state = [createState(oldSession)]

      const pruned = pruneOldSessions(state)

      expect(pruned).toEqual([])
    })
  })

  describe('updateRegistrationStatus', () => {
    it('marks session as registered', () => {
      const session = createSession()
      const state = [createState(session)]

      const updated = updateRegistrationStatus(
        state,
        '2026-02-20',
        '06:00',
        true
      )

      expect(updated).toHaveLength(1)
      expect(updated[0].isRegistered).toBe(true)
    })

    it('marks session as unregistered', () => {
      const session = createSession()
      const state = [createState(session, { isRegistered: true })]

      const updated = updateRegistrationStatus(
        state,
        '2026-02-20',
        '06:00',
        false
      )

      expect(updated).toHaveLength(1)
      expect(updated[0].isRegistered).toBe(false)
    })

    it('returns unchanged state when session not found', () => {
      const session = createSession({ date: '2026-02-20', time: '06:00' })
      const state = [createState(session)]

      const updated = updateRegistrationStatus(
        state,
        '2026-02-21', // different date
        '06:00',
        true
      )

      expect(updated).toEqual(state)
      expect(updated[0].isRegistered).toBe(false)
    })

    it('only updates matching session when multiple exist', () => {
      const session1 = createSession({ date: '2026-02-20', time: '06:00' })
      const session2 = createSession({ date: '2026-02-20', time: '18:30' })
      const state = [createState(session1), createState(session2)]

      const updated = updateRegistrationStatus(
        state,
        '2026-02-20',
        '18:30',
        true
      )

      expect(updated[0].isRegistered).toBe(false)
      expect(updated[1].isRegistered).toBe(true)
    })
  })

  describe('updateSessionState', () => {
    it('updates existing session state after alert', () => {
      const session = createSession({ playersRegistered: 14 })
      const state = [createState(session)]

      const updated = updateSessionState(
        state,
        session,
        'OPPORTUNITY',
        '2026-02-19T10:00:00Z'
      )

      expect(updated).toHaveLength(1)
      expect(updated[0].lastAlertType).toBe('OPPORTUNITY')
      expect(updated[0].lastAlertAt).toBe('2026-02-19T10:00:00Z')
      expect(updated[0].lastPlayerCount).toBe(14)
    })

    it('creates new state entry for new session', () => {
      const session = createSession()
      const state: SessionState[] = []

      const updated = updateSessionState(
        state,
        session,
        'FILLING_FAST',
        '2026-02-19T10:00:00Z'
      )

      expect(updated).toHaveLength(1)
      expect(updated[0].session).toEqual(session)
      expect(updated[0].lastAlertType).toBe('FILLING_FAST')
      expect(updated[0].lastPlayerCount).toBe(14)
    })

    it('updates session data even when no alert fired', () => {
      const oldSession = createSession({ playersRegistered: 10 })
      const newSession = createSession({ playersRegistered: 14 })
      const state = [createState(oldSession)]

      const updated = updateSessionState(state, newSession, null, null)

      expect(updated).toHaveLength(1)
      expect(updated[0].session.playersRegistered).toBe(14)
      expect(updated[0].lastAlertType).toBe(null)
      expect(updated[0].lastPlayerCount).toBe(null)
    })

    it('preserves registration status when updating', () => {
      const oldSession = createSession({ playersRegistered: 10 })
      const newSession = createSession({ playersRegistered: 14 })
      const state = [createState(oldSession, { isRegistered: true })]

      const updated = updateSessionState(
        state,
        newSession,
        'OPPORTUNITY',
        '2026-02-19T10:00:00Z'
      )

      expect(updated[0].isRegistered).toBe(true)
    })

    it('handles multiple sessions independently', () => {
      const session1 = createSession({ time: '06:00', playersRegistered: 10 })
      const session2 = createSession({ time: '18:30', playersRegistered: 20 })
      const state = [createState(session1), createState(session2)]

      const updatedSession1 = createSession({
        time: '06:00',
        playersRegistered: 14,
      })
      const updated = updateSessionState(
        state,
        updatedSession1,
        'OPPORTUNITY',
        '2026-02-19T10:00:00Z'
      )

      expect(updated).toHaveLength(2)
      expect(updated[0].lastAlertType).toBe('OPPORTUNITY')
      expect(updated[0].lastPlayerCount).toBe(14)
      expect(updated[1].lastAlertType).toBe(null) // unchanged
      expect(updated[1].lastPlayerCount).toBe(null)
    })
  })

  describe('integration: full workflow', () => {
    it('supports complete poll cycle: load -> update -> prune -> save', () => {
      // Initial state with old session
      const oldSession = createSession({ date: '2026-02-18', time: '06:00' })
      const currentSession = createSession({ date: '2026-02-20', time: '06:00' })
      const initialState = [
        createState(oldSession, {
          lastAlertType: 'OPPORTUNITY',
          lastAlertAt: '2026-02-17T10:00:00Z',
          lastPlayerCount: 10,
        }),
        createState(currentSession),
      ]

      saveState(testStatePath, initialState)

      // Load state
      let state = loadState(testStatePath)
      expect(state).toHaveLength(2)

      // Prune old sessions
      const today = new Date('2026-02-20T12:00:00Z')
      state = pruneOldSessions(state, today)
      expect(state).toHaveLength(1)

      // Update session after alert
      const updatedSession = createSession({
        date: '2026-02-20',
        time: '06:00',
        playersRegistered: 16,
      })
      state = updateSessionState(
        state,
        updatedSession,
        'OPPORTUNITY',
        '2026-02-20T12:00:00Z'
      )

      // Save state
      saveState(testStatePath, state)

      // Verify final state
      const finalState = loadState(testStatePath)
      expect(finalState).toHaveLength(1)
      expect(finalState[0].session.date).toBe('2026-02-20')
      expect(finalState[0].lastAlertType).toBe('OPPORTUNITY')
      expect(finalState[0].lastPlayerCount).toBe(16)
    })
  })
})
