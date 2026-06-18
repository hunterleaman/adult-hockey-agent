import { describe, it, expect } from 'vitest'
import { evaluateHealth, defaultHealthState, type HealthState } from '../src/health'

const NOW = '2026-06-18T12:00:00.000Z'

describe('evaluateHealth', () => {
  it('stays quiet and resets the counter on a healthy poll', () => {
    const prev: HealthState = {
      consecutiveSuspectPolls: 2,
      canaryActive: false,
      lastTransitionAt: null,
    }
    const { health, notification } = evaluateHealth(5, true, prev, 3, NOW)

    expect(notification).toBeNull()
    expect(health.consecutiveSuspectPolls).toBe(0)
    expect(health.canaryActive).toBe(false)
  })

  it('treats sessions with all-zero registrations as a suspect poll', () => {
    const { health, notification } = evaluateHealth(4, false, defaultHealthState(), 3, NOW)

    expect(notification).toBeNull() // only 1 of 3
    expect(health.consecutiveSuspectPolls).toBe(1)
  })

  it('treats zero sessions as a suspect poll', () => {
    const { health } = evaluateHealth(0, false, defaultHealthState(), 3, NOW)
    expect(health.consecutiveSuspectPolls).toBe(1)
  })

  it('fires exactly once when suspect polls reach the threshold', () => {
    let state = defaultHealthState()
    state = evaluateHealth(0, false, state, 3, NOW).health // 1
    state = evaluateHealth(0, false, state, 3, NOW).health // 2

    const third = evaluateHealth(0, false, state, 3, NOW) // 3 -> fire
    expect(third.notification).toContain('0 usable pickup sessions')
    expect(third.health.canaryActive).toBe(true)
    expect(third.health.consecutiveSuspectPolls).toBe(3)

    // 4th suspect poll: already active -> no repeat alert
    const fourth = evaluateHealth(0, false, third.health, 3, NOW)
    expect(fourth.notification).toBeNull()
    expect(fourth.health.consecutiveSuspectPolls).toBe(4)
    expect(fourth.health.canaryActive).toBe(true)
  })

  it('sends one recovery message when a healthy poll follows an active canary', () => {
    const active: HealthState = {
      consecutiveSuspectPolls: 5,
      canaryActive: true,
      lastTransitionAt: NOW,
    }
    const recovered = evaluateHealth(6, true, active, 3, NOW)

    expect(recovered.notification).toContain('recovered')
    expect(recovered.health.canaryActive).toBe(false)
    expect(recovered.health.consecutiveSuspectPolls).toBe(0)

    // subsequent healthy poll: no repeat recovery message
    const next = evaluateHealth(6, true, recovered.health, 3, NOW)
    expect(next.notification).toBeNull()
  })

  it('respects a custom threshold of 1 (fires on the first suspect poll)', () => {
    const first = evaluateHealth(0, false, defaultHealthState(), 1, NOW)
    expect(first.notification).not.toBeNull()
    expect(first.health.canaryActive).toBe(true)
  })
})
