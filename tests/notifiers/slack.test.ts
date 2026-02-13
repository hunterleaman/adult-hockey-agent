import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { SlackNotifier } from '../../src/notifiers/slack'
import type { Alert } from '../../src/evaluator'
import type { Session } from '../../src/parser'

// Mock fetch globally
global.fetch = vi.fn()

describe('SlackNotifier', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    delete process.env.SLACK_WEBHOOK_URL
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

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

  const createAlert = (type: Alert['type'], sessionOverrides: Partial<Session> = {}): Alert => {
    const session = createSession(sessionOverrides)
    return {
      type,
      session,
      message: `Test ${type} message`,
      registrationUrl: `https://example.com/register?date=${session.date}`,
    }
  }

  describe('interface implementation', () => {
    it('has correct name', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      expect(notifier.name).toBe('Slack')
    })

    it('is configured when webhook URL provided', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      expect(notifier.isConfigured()).toBe(true)
    })

    it('is not configured when webhook URL is empty', () => {
      const notifier = new SlackNotifier('')
      expect(notifier.isConfigured()).toBe(false)
    })

    it('is not configured when webhook URL is undefined', () => {
      const notifier = new SlackNotifier(undefined as any)
      expect(notifier.isConfigured()).toBe(false)
    })

    it('loads webhook URL from environment variable', () => {
      process.env.SLACK_WEBHOOK_URL = 'https://hooks.slack.com/from-env'
      const notifier = SlackNotifier.fromEnv()
      expect(notifier.isConfigured()).toBe(true)
    })

    it('is not configured when env var is missing', () => {
      const notifier = SlackNotifier.fromEnv()
      expect(notifier.isConfigured()).toBe(false)
    })
  })

  describe('send', () => {
    it('posts JSON payload to webhook URL', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await notifier.send(alert)

      expect(global.fetch).toHaveBeenCalledTimes(1)
      expect(global.fetch).toHaveBeenCalledWith(
        'https://hooks.slack.com/test',
        expect.objectContaining({
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: expect.any(String),
        })
      )
    })

    it('includes alert type in payload', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await notifier.send(alert)

      const call = (global.fetch as any).mock.calls[0]
      const body = JSON.parse(call[1].body)
      const text = JSON.stringify(body).toLowerCase()
      expect(text).toContain('opportunity')
    })

    it('includes session details in payload', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await notifier.send(alert)

      const call = (global.fetch as any).mock.calls[0]
      const body = JSON.parse(call[1].body)
      const text = JSON.stringify(body)
      expect(text).toContain('2026-02-20')
      expect(text).toContain('Friday')
    })

    it('includes registration URL as action button', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await notifier.send(alert)

      const call = (global.fetch as any).mock.calls[0]
      const body = JSON.parse(call[1].body)
      const text = JSON.stringify(body)
      expect(text).toContain(alert.registrationUrl)
    })

    it('uses different colors for different alert types', async () => {
      ;(global.fetch as any).mockResolvedValue({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')

      await notifier.send(createAlert('OPPORTUNITY'))
      await notifier.send(createAlert('FILLING_FAST'))
      await notifier.send(createAlert('SOLD_OUT'))
      await notifier.send(createAlert('NEWLY_AVAILABLE'))

      const calls = (global.fetch as any).mock.calls
      const payloads = calls.map((c: any) => JSON.parse(c[1].body))

      // Should have color indicators (attachments or blocks with colors)
      expect(payloads.length).toBe(4)
      // At least check that payloads are different
      expect(payloads[0]).not.toEqual(payloads[1])
    })

    it('throws error when webhook returns non-200', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: false,
        status: 400,
        statusText: 'Bad Request',
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await expect(notifier.send(alert)).rejects.toThrow('Slack webhook failed: 400 Bad Request')
    })

    it('throws error when fetch fails', async () => {
      ;(global.fetch as any).mockRejectedValueOnce(new Error('Network error'))

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await expect(notifier.send(alert)).rejects.toThrow('Network error')
    })

    it('throws error when not configured', async () => {
      const notifier = new SlackNotifier('')
      const alert = createAlert('OPPORTUNITY')

      await expect(notifier.send(alert)).rejects.toThrow('Slack notifier not configured')
    })

    it('formats OPPORTUNITY alerts with appropriate emoji', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await notifier.send(alert)

      const call = (global.fetch as any).mock.calls[0]
      const body = JSON.parse(call[1].body)
      const text = JSON.stringify(body)
      expect(text).toContain('🏒')
    })

    it('formats FILLING_FAST alerts with urgency emoji', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('FILLING_FAST')

      await notifier.send(alert)

      const call = (global.fetch as any).mock.calls[0]
      const body = JSON.parse(call[1].body)
      const text = JSON.stringify(body)
      expect(text).toContain('⚡')
    })

    it('uses Block Kit format for rich formatting', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
      })

      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')

      await notifier.send(alert)

      const call = (global.fetch as any).mock.calls[0]
      const body = JSON.parse(call[1].body)

      // Should use Slack Block Kit (blocks array)
      expect(body).toHaveProperty('blocks')
      expect(Array.isArray(body.blocks)).toBe(true)
      expect(body.blocks.length).toBeGreaterThan(0)
    })
  })
})
