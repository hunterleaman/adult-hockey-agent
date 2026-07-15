import { describe, it, expect } from 'vitest'
import { sessionKey, sessionMatches } from '../src/session-identity'

describe('sessionKey', () => {
  it('includes date, time, and facilityId', () => {
    expect(sessionKey({ date: '2026-07-15', time: '06:10', facilityId: 1 })).toBe(
      '2026-07-15:06:10:1'
    )
  })

  it('uses 0 when facilityId is missing (legacy entries)', () => {
    expect(sessionKey({ date: '2026-07-15', time: '06:10' })).toBe('2026-07-15:06:10:0')
  })
})

describe('sessionMatches', () => {
  it('matches when date, time, and facilityId are equal', () => {
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '11:30', facilityId: 2 },
        { date: '2026-07-15', time: '11:30', facilityId: 2 }
      )
    ).toBe(true)
  })

  it('does NOT match same date+time at a different facility', () => {
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '11:30', facilityId: 1 },
        { date: '2026-07-15', time: '11:30', facilityId: 2 }
      )
    ).toBe(false)
  })

  it('falls back to date+time when either side lacks facilityId (legacy)', () => {
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '06:10' },
        { date: '2026-07-15', time: '06:10', facilityId: 1 }
      )
    ).toBe(true)
    expect(
      sessionMatches(
        { date: '2026-07-15', time: '06:10', facilityId: 1 },
        { date: '2026-07-15', time: '06:10' }
      )
    ).toBe(true)
  })

  it('never matches differing date or time', () => {
    expect(
      sessionMatches({ date: '2026-07-15', time: '06:10' }, { date: '2026-07-15', time: '06:00' })
    ).toBe(false)
    expect(
      sessionMatches({ date: '2026-07-16', time: '06:10' }, { date: '2026-07-15', time: '06:10' })
    ).toBe(false)
  })
})
