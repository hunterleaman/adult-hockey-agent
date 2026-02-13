import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { ConsoleNotifier } from '../../src/notifiers/console'
import type { Alert } from '../../src/evaluator'
import type { Session } from '../../src/parser'

describe('ConsoleNotifier', () => {
  let consoleNotifier: ConsoleNotifier
  let consoleLogSpy: any

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

  const createAlert = (
    type: Alert['type'],
    sessionOverrides: Partial<Session> = {}
  ): Alert => {
    const session = createSession(sessionOverrides)
    return {
      type,
      session,
      message: `Test ${type} message`,
      registrationUrl: `https://example.com/register?date=${session.date}`,
    }
  }

  beforeEach(() => {
    consoleNotifier = new ConsoleNotifier()
    consoleLogSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
  })

  afterEach(() => {
    consoleLogSpy.mockRestore()
  })

  describe('interface implementation', () => {
    it('has correct name', () => {
      expect(consoleNotifier.name).toBe('Console')
    })

    it('is always configured', () => {
      expect(consoleNotifier.isConfigured()).toBe(true)
    })
  })

  describe('send', () => {
    it('logs OPPORTUNITY alert to console', async () => {
      const alert = createAlert('OPPORTUNITY')

      await consoleNotifier.send(alert)

      expect(consoleLogSpy).toHaveBeenCalled()
      const output = consoleLogSpy.mock.calls.join('\n')
      expect(output).toContain('OPPORTUNITY')
      expect(output).toContain('2026-02-20')
    })

    it('logs FILLING_FAST alert to console', async () => {
      const alert = createAlert('FILLING_FAST')

      await consoleNotifier.send(alert)

      expect(consoleLogSpy).toHaveBeenCalled()
      const output = consoleLogSpy.mock.calls.join('\n')
      expect(output).toContain('FILLING_FAST')
    })

    it('logs SOLD_OUT alert to console', async () => {
      const alert = createAlert('SOLD_OUT')

      await consoleNotifier.send(alert)

      expect(consoleLogSpy).toHaveBeenCalled()
      const output = consoleLogSpy.mock.calls.join('\n')
      expect(output).toContain('SOLD_OUT')
    })

    it('logs NEWLY_AVAILABLE alert to console', async () => {
      const alert = createAlert('NEWLY_AVAILABLE')

      await consoleNotifier.send(alert)

      expect(consoleLogSpy).toHaveBeenCalled()
      const output = consoleLogSpy.mock.calls.join('\n')
      expect(output).toContain('NEWLY_AVAILABLE')
    })

    it('includes alert message in output', async () => {
      const alert = createAlert('OPPORTUNITY')
      alert.message = 'Custom test message'

      await consoleNotifier.send(alert)

      const output = consoleLogSpy.mock.calls.join('\n')
      expect(output).toContain('Custom test message')
    })

    it('includes registration URL in output', async () => {
      const alert = createAlert('OPPORTUNITY')

      await consoleNotifier.send(alert)

      const output = consoleLogSpy.mock.calls.join('\n')
      expect(output).toContain(alert.registrationUrl)
    })

    it('formats output with visual separators', async () => {
      const alert = createAlert('OPPORTUNITY')

      await consoleNotifier.send(alert)

      const output = consoleLogSpy.mock.calls.join('\n')
      // Should have some kind of separator or formatting
      expect(output.length).toBeGreaterThan(alert.message.length)
    })

    it('handles multiple alerts sequentially', async () => {
      const alert1 = createAlert('OPPORTUNITY', { time: '06:00' })
      const alert2 = createAlert('FILLING_FAST', { time: '18:30' })

      await consoleNotifier.send(alert1)
      await consoleNotifier.send(alert2)

      expect(consoleLogSpy).toHaveBeenCalledTimes(8) // 4 calls per alert (separator + message + url + separator)
    })

    it('does not throw on console.log errors', async () => {
      consoleLogSpy.mockImplementation(() => {
        throw new Error('Console error')
      })

      const alert = createAlert('OPPORTUNITY')

      await expect(consoleNotifier.send(alert)).resolves.not.toThrow()
    })
  })
})
