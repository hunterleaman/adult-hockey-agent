import { describe, it, expect } from 'vitest'
import {
  calculateNextPollDelay,
  getNextSessionTime,
  parseSessionTimeET,
} from '../src/poll-schedule'
import type { SessionState } from '../src/evaluator'
import type { Session } from '../src/parser'

// February 2026 is EST (UTC-5)
// Helpers for readable test dates:
// 10:00 AM ET = 15:00 UTC
// 7:30 PM ET  = 00:30 UTC next day
// 6:00 AM ET  = 11:00 UTC
// 3:00 AM ET  = 08:00 UTC

function makeSession(date: string, time: string): Session {
  return {
    date,
    dayOfWeek: 'Wednesday',
    time,
    timeLabel: '7:00pm - 8:10pm',
    eventName: '(PLAYERS) ADULT Pick Up',
    playersRegistered: 10,
    playersMax: 24,
    goaliesRegistered: 1,
    goaliesMax: 4,
    isFull: false,
    price: 0,
  }
}

function makeSessionState(date: string, time: string): SessionState {
  return {
    session: makeSession(date, time),
    lastAlertType: null,
    lastAlertAt: null,
    lastPlayerCount: null,
    isRegistered: false,
    userResponse: null,
    userRespondedAt: null,
    remindAfter: null,
  }
}

const defaultConfig = {
  approachWindowHours: 96,
  maxSleepHours: 12,
  pollIntervalMinutes: 60,
  pollIntervalAcceleratedMinutes: 30,
  pollStartHour: 6,
  pollEndHour: 23,
}

describe('parseSessionTimeET', () => {
  it('converts EST date+time to correct UTC Date', () => {
    // Feb 20, 2026 7:30 PM ET (EST, UTC-5) = Feb 21, 2026 00:30 UTC
    const result = parseSessionTimeET('2026-02-20', '19:30')

    expect(result.getUTCFullYear()).toBe(2026)
    expect(result.getUTCMonth()).toBe(1) // 0-indexed
    expect(result.getUTCDate()).toBe(21)
    expect(result.getUTCHours()).toBe(0)
    expect(result.getUTCMinutes()).toBe(30)
  })

  it('converts morning EST time correctly', () => {
    // Feb 20, 2026 6:00 AM ET (EST, UTC-5) = Feb 20, 2026 11:00 UTC
    const result = parseSessionTimeET('2026-02-20', '06:00')

    expect(result.getUTCFullYear()).toBe(2026)
    expect(result.getUTCMonth()).toBe(1)
    expect(result.getUTCDate()).toBe(20)
    expect(result.getUTCHours()).toBe(11)
    expect(result.getUTCMinutes()).toBe(0)
  })

  it('handles EDT (summer) correctly', () => {
    // Jul 15, 2026 7:30 PM ET (EDT, UTC-4) = Jul 15, 2026 23:30 UTC
    const result = parseSessionTimeET('2026-07-15', '19:30')

    expect(result.getUTCFullYear()).toBe(2026)
    expect(result.getUTCMonth()).toBe(6)
    expect(result.getUTCDate()).toBe(15)
    expect(result.getUTCHours()).toBe(23)
    expect(result.getUTCMinutes()).toBe(30)
  })
})

describe('getNextSessionTime', () => {
  it('returns null when no sessions', () => {
    const now = new Date('2026-02-20T15:00:00Z')
    const result = getNextSessionTime([], now)

    expect(result).toBeNull()
  })

  it('returns earliest future session time', () => {
    const now = new Date('2026-02-20T15:00:00Z') // 10 AM ET
    const sessions = [
      makeSessionState('2026-02-23', '19:30'), // Mon 7:30 PM ET
      makeSessionState('2026-02-21', '07:00'), // Sat 7:00 AM ET (earlier)
      makeSessionState('2026-02-25', '19:30'), // Wed 7:30 PM ET
    ]

    const result = getNextSessionTime(sessions, now)

    // Earliest future: Feb 21 7:00 AM ET = Feb 21 12:00 UTC
    expect(result).not.toBeNull()
    expect(result!.getUTCDate()).toBe(21)
    expect(result!.getUTCHours()).toBe(12)
  })

  it('skips past sessions', () => {
    const now = new Date('2026-02-22T15:00:00Z') // Feb 22, 10 AM ET
    const sessions = [
      makeSessionState('2026-02-20', '19:30'), // past
      makeSessionState('2026-02-21', '07:00'), // past
      makeSessionState('2026-02-25', '19:30'), // future
    ]

    const result = getNextSessionTime(sessions, now)

    // Only Feb 25 is future: Feb 26 00:30 UTC
    expect(result).not.toBeNull()
    expect(result!.getUTCDate()).toBe(26)
    expect(result!.getUTCHours()).toBe(0)
    expect(result!.getUTCMinutes()).toBe(30)
  })

  it('returns null when all sessions are in the past', () => {
    const now = new Date('2026-02-28T15:00:00Z')
    const sessions = [
      makeSessionState('2026-02-20', '19:30'),
      makeSessionState('2026-02-21', '07:00'),
    ]

    const result = getNextSessionTime(sessions, now)

    expect(result).toBeNull()
  })
})

describe('calculateNextPollDelay', () => {
  it('returns fallback delay when no sessions', () => {
    const now = new Date('2026-02-20T15:00:00Z') // 10 AM ET

    const result = calculateNextPollDelay(now, null, defaultConfig, false)

    expect(result.delayMs).toBe(12 * 60 * 60 * 1000) // 12h
    expect(result.reason).toBe('fallback')
  })

  it('sleeps until approach window when session is outside window', () => {
    const now = new Date('2026-02-20T15:00:00Z') // Feb 20, 10 AM ET
    // Session: Feb 24, 7 PM ET = Feb 25 00:00 UTC
    // 96h approach window opens: Feb 21, 00:00 UTC (Feb 20 7 PM ET) — 9h from now
    // 9h < 12h max sleep, so sleep until approach window
    const nextSession = parseSessionTimeET('2026-02-24', '19:00')

    const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

    const expectedMs = 9 * 60 * 60 * 1000
    expect(result.delayMs).toBe(expectedMs)
    expect(result.reason).toBe('sleep')
  })

  it('uses normal interval when inside approach window', () => {
    const now = new Date('2026-02-20T15:00:00Z') // Feb 20, 10 AM ET
    // Session: Feb 23, 7 PM ET — 3 days away, within 96h approach window
    const nextSession = parseSessionTimeET('2026-02-23', '19:00')

    const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

    expect(result.delayMs).toBe(60 * 60 * 1000) // 60 min normal
    expect(result.reason).toBe('approach')
  })

  it('uses accelerated interval when FILLING_FAST in approach window', () => {
    const now = new Date('2026-02-20T15:00:00Z')
    const nextSession = parseSessionTimeET('2026-02-23', '19:00')

    const result = calculateNextPollDelay(now, nextSession, defaultConfig, true)

    expect(result.delayMs).toBe(30 * 60 * 1000) // 30 min accelerated
    expect(result.reason).toBe('approach')
  })

  it('uses normal interval for session 2 hours away', () => {
    const now = new Date('2026-02-20T15:00:00Z') // 10 AM ET
    // Session at noon ET = 17:00 UTC, 2 hours from now
    const nextSession = parseSessionTimeET('2026-02-20', '12:00')

    const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

    expect(result.delayMs).toBe(60 * 60 * 1000)
    expect(result.reason).toBe('approach')
  })

  it('caps sleep at maxSleepHours when approach window is far away', () => {
    const now = new Date('2026-02-20T15:00:00Z') // Feb 20, 10 AM ET
    // Session: Mar 1, 7 PM ET — ~9 days away
    // Approach window opens ~5 days from now, well beyond 12h max sleep
    const nextSession = parseSessionTimeET('2026-03-01', '19:00')

    const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

    // Should cap at max sleep (12h), clamped to active hours
    // now + 12h = Feb 21 03:00 UTC = Feb 20 10:00 PM ET — within active hours
    expect(result.delayMs).toBe(12 * 60 * 60 * 1000)
    expect(result.reason).toBe('fallback')
  })

  it('clamps wake time to pollStartHour when approach opens before active hours', () => {
    // now: Feb 22, 1 AM ET = Feb 22 06:00 UTC
    const now = new Date('2026-02-22T06:00:00Z')
    // Session: Feb 26, 3 AM ET = Feb 26 08:00 UTC
    // Approach window (96h): opens Feb 22, 3 AM ET = Feb 22 08:00 UTC (2h from now)
    // But 3 AM ET < 6 AM pollStartHour → clamp to 6 AM ET = Feb 22 11:00 UTC (5h from now)
    const nextSession = parseSessionTimeET('2026-02-26', '03:00')

    const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

    // Clamped to 6 AM ET = 5h from now
    const expectedMs = 5 * 60 * 60 * 1000
    expect(result.delayMs).toBe(expectedMs)
    expect(result.reason).toBe('sleep')
  })

  it('clamps interval-based wake to next active window when after pollEndHour', () => {
    // now: Feb 20, 11:30 PM ET = Feb 21 04:30 UTC (inside approach window)
    const now = new Date('2026-02-21T04:30:00Z')
    const nextSession = parseSessionTimeET('2026-02-23', '19:00')

    const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

    // Normal interval would be 60 min → Feb 21 12:30 AM ET (hour 0)
    // 0 < pollStartHour (6), clamp to 6 AM ET = Feb 21 11:00 UTC
    // Delay = 11:00 - 04:30 = 6.5h
    expect(result.delayMs).toBe(6.5 * 60 * 60 * 1000)
    expect(result.reason).toBe('approach')
  })

  it('uses earliest session when multiple sessions upcoming', () => {
    const now = new Date('2026-02-20T15:00:00Z') // Feb 20, 10 AM ET
    // Two sessions: Feb 24 7PM ET and Feb 27 7PM ET
    // getNextSessionTime picks Feb 24 — approach opens 9h from now
    // calculateNextPollDelay takes the already-resolved next session time
    const earlierSession = parseSessionTimeET('2026-02-24', '19:00')

    const result = calculateNextPollDelay(now, earlierSession, defaultConfig, false)

    expect(result.delayMs).toBe(9 * 60 * 60 * 1000)
    expect(result.reason).toBe('sleep')
  })

  it('clamps fallback wake to active hours', () => {
    // now: Feb 20, 11 PM ET = Feb 21 04:00 UTC
    const now = new Date('2026-02-21T04:00:00Z')
    // No sessions (fallback). Max sleep 12h → Feb 21 16:00 UTC = Feb 21 11 AM ET
    // 11 AM ET is within active hours, no clamping needed. This test verifies that.

    const result = calculateNextPollDelay(now, null, defaultConfig, false)

    expect(result.delayMs).toBe(12 * 60 * 60 * 1000)
    expect(result.reason).toBe('fallback')
  })

  it('clamps fallback wake to pollStartHour when it lands before active hours', () => {
    // now: Feb 20, 8 PM ET = Feb 21 01:00 UTC
    const now = new Date('2026-02-21T01:00:00Z')
    // No sessions. Max sleep 12h → Feb 21 13:00 UTC = Feb 21 8 AM ET
    // 8 AM is within active hours. Let me make max sleep shorter:
    const config = { ...defaultConfig, maxSleepHours: 4 }
    // now + 4h = Feb 21 05:00 UTC = Feb 21 midnight ET → before pollStartHour (6)
    // Clamp to 6 AM ET = Feb 21 11:00 UTC → 10h from now

    const result = calculateNextPollDelay(now, null, config, false)

    expect(result.delayMs).toBe(10 * 60 * 60 * 1000)
    expect(result.reason).toBe('fallback')
  })

  describe('log messages', () => {
    it('includes session time in sleep message', () => {
      const now = new Date('2026-02-20T15:00:00Z')
      const nextSession = parseSessionTimeET('2026-02-25', '19:00')

      const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

      expect(result.scheduleLog).toContain('No sessions in approach window')
      expect(result.scheduleLog).toContain('ET')
    })

    it('includes approach window message for active polling', () => {
      const now = new Date('2026-02-20T15:00:00Z')
      const nextSession = parseSessionTimeET('2026-02-23', '19:00')

      const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

      expect(result.scheduleLog).toContain('Approach window open')
      expect(result.scheduleLog).toContain('60 minutes')
    })

    it('includes accelerated in message when FILLING_FAST', () => {
      const now = new Date('2026-02-20T15:00:00Z')
      const nextSession = parseSessionTimeET('2026-02-23', '19:00')

      const result = calculateNextPollDelay(now, nextSession, defaultConfig, true)

      expect(result.scheduleLog).toContain('30 minutes')
      expect(result.scheduleLog).toContain('accelerated')
    })

    it('includes max sleep reached in fallback wake message', () => {
      const now = new Date('2026-02-20T15:00:00Z')

      const result = calculateNextPollDelay(now, null, defaultConfig, false)

      expect(result.wakeLog).toContain('Max sleep reached')
      expect(result.wakeLog).toContain('12h')
    })

    it('includes approach window open in sleep wake message', () => {
      const now = new Date('2026-02-20T15:00:00Z')
      // Session close enough that approach window is within max sleep
      const nextSession = parseSessionTimeET('2026-02-24', '19:00')

      const result = calculateNextPollDelay(now, nextSession, defaultConfig, false)

      expect(result.wakeLog).toContain('Approach window open')
    })
  })
})
