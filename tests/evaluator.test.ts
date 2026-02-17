import { describe, it, expect } from 'vitest'
import { evaluate } from '../src/evaluator'
import type { Session } from '../src/parser'
import type { SessionState, Alert, AlertType } from '../src/evaluator'
import type { Config } from '../src/config'

describe('evaluator', () => {
  const defaultConfig: Config = {
    pollIntervalMinutes: 60,
    pollIntervalAcceleratedMinutes: 30,
    pollStartHour: 6,
    pollEndHour: 23,
    forwardWindowDays: 5,
    minGoalies: 1,
    minPlayersRegistered: 10,
    playerSpotsUrgent: 4,
    slackWebhookUrl: undefined,
  }

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

  describe('OPPORTUNITY alerts', () => {
    it('fires when goalies >= 1 AND players registered >= 10', () => {
      const session = createSession({
        playersRegistered: 10,
        playersMax: 24,
        goaliesRegistered: 1,
      })
      const state: SessionState[] = [createState(session)]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('OPPORTUNITY')
      expect(alerts[0].session).toEqual(session)
      expect(alerts[0].message).toContain('OPPORTUNITY')
    })

    it('does not fire when players registered < 10', () => {
      const session = createSession({
        playersRegistered: 9,
        playersMax: 24,
        goaliesRegistered: 1,
      })
      const state: SessionState[] = [createState(session)]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })

    it('does not fire when goalies < 1', () => {
      const session = createSession({
        playersRegistered: 10,
        playersMax: 24,
        goaliesRegistered: 0,
      })
      const state: SessionState[] = [createState(session)]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })

    it('suppresses repeat alert unless spots decreased by >= 2', () => {
      const session = createSession({
        playersRegistered: 15,
        playersMax: 24, // 9 spots remaining
        goaliesRegistered: 2,
      })
      const state: SessionState[] = [
        createState(session, {
          lastAlertType: 'OPPORTUNITY',
          lastAlertAt: '2026-02-19T10:00:00Z',
          lastPlayerCount: 14, // was 10 spots remaining, now 9 spots (decreased by 1)
        }),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0) // suppressed (only decreased by 1)
    })

    it('re-alerts when spots decreased by >= 2 since last alert', () => {
      const session = createSession({
        playersRegistered: 16,
        playersMax: 24, // 8 spots remaining
        goaliesRegistered: 2,
      })
      const state: SessionState[] = [
        createState(session, {
          lastAlertType: 'OPPORTUNITY',
          lastAlertAt: '2026-02-19T10:00:00Z',
          lastPlayerCount: 14, // was 10 spots remaining, now 8 spots (decreased by 2)
        }),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('OPPORTUNITY')
    })

    it('excludes registered sessions from OPPORTUNITY alerts', () => {
      const session = createSession({
        playersRegistered: 10,
        playersMax: 24,
        goaliesRegistered: 2,
      })
      const state: SessionState[] = [createState(session, { isRegistered: true })]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })
  })

  describe('FILLING_FAST alerts', () => {
    it('fires when player spots <= 4', () => {
      const session = createSession({
        playersRegistered: 20,
        playersMax: 24, // 4 spots
        goaliesRegistered: 0, // 0 goalies to avoid OPPORTUNITY
      })
      const state: SessionState[] = [createState(session)]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('FILLING_FAST')
    })

    it('does not fire when player spots > 4', () => {
      const session = createSession({
        playersRegistered: 19,
        playersMax: 24, // 5 spots
        goaliesRegistered: 0, // avoid OPPORTUNITY alert
      })
      const state: SessionState[] = [createState(session)]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })

    it('suppresses repeat alert unless spots decreased', () => {
      const session = createSession({
        playersRegistered: 20,
        playersMax: 24, // 4 spots
        goaliesRegistered: 0, // avoid OPPORTUNITY alert
      })
      const state: SessionState[] = [
        createState(session, {
          lastAlertType: 'FILLING_FAST',
          lastAlertAt: '2026-02-19T10:00:00Z',
          lastPlayerCount: 20, // same count
        }),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })

    it('re-alerts when spots decreased further', () => {
      const session = createSession({
        playersRegistered: 22,
        playersMax: 24, // 2 spots
        goaliesRegistered: 0, // avoid OPPORTUNITY alert
      })
      const state: SessionState[] = [
        createState(session, {
          lastAlertType: 'FILLING_FAST',
          lastAlertAt: '2026-02-19T10:00:00Z',
          lastPlayerCount: 20, // was 4 spots, now 2 spots
        }),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('FILLING_FAST')
    })

    it('excludes registered sessions from FILLING_FAST alerts', () => {
      const session = createSession({
        playersRegistered: 20,
        playersMax: 24, // 4 spots
      })
      const state: SessionState[] = [createState(session, { isRegistered: true })]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })
  })

  describe('SOLD_OUT alerts', () => {
    it('fires when session transitions from available to full', () => {
      const session = createSession({
        playersRegistered: 24,
        playersMax: 24,
        isFull: true,
      })
      const state: SessionState[] = [
        createState(
          createSession({
            playersRegistered: 23,
            playersMax: 24,
            isFull: false,
          })
        ),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('SOLD_OUT')
    })

    it('does not fire when session was already full', () => {
      const session = createSession({
        playersRegistered: 24,
        playersMax: 24,
        isFull: true,
      })
      const state: SessionState[] = [
        createState(
          createSession({
            playersRegistered: 24,
            playersMax: 24,
            isFull: true,
          })
        ),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })

    it('fires even for registered sessions (confirmation)', () => {
      const session = createSession({
        playersRegistered: 24,
        playersMax: 24,
        isFull: true,
      })
      const state: SessionState[] = [
        createState(
          createSession({
            playersRegistered: 23,
            playersMax: 24,
            isFull: false,
          }),
          { isRegistered: true }
        ),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('SOLD_OUT')
    })

    it('does not fire when session is new (no previous state)', () => {
      const session = createSession({
        playersRegistered: 24,
        playersMax: 24,
        isFull: true,
      })
      const state: SessionState[] = [] // no previous state

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0)
    })
  })

  describe('NEWLY_AVAILABLE alerts', () => {
    it('fires when session transitions from full to available', () => {
      const session = createSession({
        playersRegistered: 23,
        playersMax: 24, // 1 spot
        goaliesRegistered: 0, // avoid OPPORTUNITY alert (1 spot is < 4, so FILLING_FAST will fire)
        isFull: false,
      })
      const state: SessionState[] = [
        createState(
          createSession({
            playersRegistered: 24,
            playersMax: 24,
            isFull: true,
          })
        ),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      // Should get NEWLY_AVAILABLE + FILLING_FAST (1 spot <= 4)
      expect(alerts.length).toBeGreaterThanOrEqual(1)
      const newlyAvailableAlert = alerts.find((a) => a.type === 'NEWLY_AVAILABLE')
      expect(newlyAvailableAlert).toBeDefined()
    })

    it('does not fire when session was already available', () => {
      const session = createSession({
        playersRegistered: 23,
        playersMax: 24,
        isFull: false,
      })
      const state: SessionState[] = [
        createState(
          createSession({
            playersRegistered: 22,
            playersMax: 24,
            isFull: false,
          })
        ),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      // May fire other alerts (OPPORTUNITY, FILLING_FAST) but not NEWLY_AVAILABLE
      const newlyAvailableAlerts = alerts.filter((a) => a.type === 'NEWLY_AVAILABLE')
      expect(newlyAvailableAlerts).toHaveLength(0)
    })

    it('fires only NEWLY_AVAILABLE when session opens up (priority system)', () => {
      const session = createSession({
        playersRegistered: 20,
        playersMax: 24, // 4 spots remaining
        goaliesRegistered: 1,
        isFull: false,
      })
      const state: SessionState[] = [
        createState(
          createSession({
            playersRegistered: 24,
            playersMax: 24,
            isFull: true,
          })
        ),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      // Should get ONLY NEWLY_AVAILABLE (priority system: one alert per session)
      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('NEWLY_AVAILABLE')
      // OPPORTUNITY and FILLING_FAST are suppressed by priority system
    })
  })

  describe('alert message formatting', () => {
    it('includes all required fields in Alert', () => {
      const session = createSession({
        playersRegistered: 10,
        playersMax: 24,
        goaliesRegistered: 2,
      })
      const state: SessionState[] = [createState(session)]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0]).toHaveProperty('type')
      expect(alerts[0]).toHaveProperty('session')
      expect(alerts[0]).toHaveProperty('message')
      expect(alerts[0]).toHaveProperty('registrationUrl')
      expect(alerts[0].registrationUrl).toContain('2026-02-20')
    })

    it('fires only FILLING_FAST when both FILLING_FAST and OPPORTUNITY conditions are met', () => {
      // Scenario: 20/24 players (4 spots left), 2/3 goalies
      // - FILLING_FAST: 4 spots <= 4 (playerSpotsUrgent) ✓
      // - OPPORTUNITY: 20 players >= 10, 2 goalies >= 1 ✓
      // Expected: Only FILLING_FAST fires (higher priority)
      const session = createSession({
        playersRegistered: 20,
        playersMax: 24,
        goaliesRegistered: 2,
        goaliesMax: 3,
        isFull: false,
      })
      const state: SessionState[] = []

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('FILLING_FAST')
    })
  })

  describe('multiple sessions', () => {
    it('processes all sessions independently', () => {
      const session1 = createSession({
        time: '06:00',
        playersRegistered: 10,
        playersMax: 24,
        goaliesRegistered: 2,
      })
      const session2 = createSession({
        time: '18:30',
        playersRegistered: 20,
        playersMax: 24, // 4 spots remaining
        goaliesRegistered: 0, // 0 goalies to avoid OPPORTUNITY
      })
      const state: SessionState[] = [createState(session1), createState(session2)]

      const alerts = evaluate([session1, session2], state, defaultConfig)

      expect(alerts).toHaveLength(2)
      expect(alerts.find((a) => a.session.time === '06:00')?.type).toBe('OPPORTUNITY')
      expect(alerts.find((a) => a.session.time === '18:30')?.type).toBe('FILLING_FAST')
    })
  })

  describe('edge cases', () => {
    it('handles session with 0 spots remaining', () => {
      const session = createSession({
        playersRegistered: 24,
        playersMax: 24,
        isFull: true,
      })
      const state: SessionState[] = [createState(session)]

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(0) // no transition, just full
    })

    it('handles missing state for session (first poll)', () => {
      const session = createSession({
        playersRegistered: 10,
        playersMax: 24,
        goaliesRegistered: 2,
      })
      const state: SessionState[] = [] // no state yet

      const alerts = evaluate([session], state, defaultConfig)

      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('OPPORTUNITY')
    })

    it('handles state for different session (date/time mismatch)', () => {
      const session = createSession({
        date: '2026-02-20',
        time: '06:00',
        playersRegistered: 10,
        playersMax: 24,
        goaliesRegistered: 2,
      })
      const state: SessionState[] = [
        createState(
          createSession({
            date: '2026-02-18', // different date
            time: '06:00',
          })
        ),
      ]

      const alerts = evaluate([session], state, defaultConfig)

      // Treats as new session (no matching state)
      expect(alerts).toHaveLength(1)
      expect(alerts[0].type).toBe('OPPORTUNITY')
    })
  })
})
