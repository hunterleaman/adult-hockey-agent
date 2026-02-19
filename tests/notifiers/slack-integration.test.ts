import { describe, it, expect } from 'vitest'
import { SlackNotifier } from '../../src/notifiers/slack'
import type { Alert, AlertType } from '../../src/evaluator'
import type { Session } from '../../src/parser'

/**
 * Slack Block Kit Integration Tests
 *
 * These tests validate that our Slack payloads conform to Slack's Block Kit specification.
 * They test the structure and constraints that Slack's API enforces, catching issues like:
 * - Invalid button styles (e.g., 'default' is not a valid style)
 * - Required fields
 * - Field value constraints
 *
 * Reference: https://api.slack.com/block-kit
 */
describe('SlackNotifier - Block Kit Integration', () => {
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

  const createAlert = (type: AlertType, sessionOverrides: Partial<Session> = {}): Alert => {
    const session = createSession(sessionOverrides)
    return {
      type,
      session,
      message: `Test ${type} message`,
      registrationUrl: `https://apps.daysmartrecreation.com/dash/x/#/online/extremeice/event-registration?date=${session.date}&facility_ids=1`,
    }
  }

  // Helper to extract payload from notifier
  const getPayload = (notifier: SlackNotifier, alert: Alert): any => {
    // Access private method via type assertion
    return (notifier as any).buildPayload(alert)
  }

  describe('Block Kit Structure Validation', () => {
    it('produces valid header block for all alert types', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alertTypes: AlertType[] = ['OPPORTUNITY', 'FILLING_FAST', 'SOLD_OUT', 'NEWLY_AVAILABLE']

      for (const type of alertTypes) {
        const alert = createAlert(type)
        const payload = getPayload(notifier, alert)

        // Header must be first block
        expect(payload.blocks[0].type).toBe('header')
        expect(payload.blocks[0].text.type).toBe('plain_text')
        expect(payload.blocks[0].text.emoji).toBe(true)

        // Header text should not contain underscores (SOLD_OUT → SOLD OUT)
        expect(payload.blocks[0].text.text).not.toContain('_')
        expect(payload.blocks[0].text.text).toMatch(/^[🏒⚡🚫✅]/)
      }
    })

    it('produces valid section block for all alert types', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alertTypes: AlertType[] = ['OPPORTUNITY', 'FILLING_FAST', 'SOLD_OUT', 'NEWLY_AVAILABLE']

      for (const type of alertTypes) {
        const alert = createAlert(type)
        const payload = getPayload(notifier, alert)

        // Section must be second block
        expect(payload.blocks[1].type).toBe('section')
        expect(payload.blocks[1].text.type).toBe('mrkdwn')
        expect(payload.blocks[1].text.text).toBeTruthy()
      }
    })

    it('omits action block for SOLD_OUT alerts', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('SOLD_OUT', { isFull: true })
      const payload = getPayload(notifier, alert)

      // Should only have 2 blocks (header + section, no actions)
      expect(payload.blocks).toHaveLength(2)

      // Verify no actions block exists
      const actionBlocks = payload.blocks.filter((b: any) => b.type === 'actions')
      expect(actionBlocks).toHaveLength(0)
    })

    it('includes action block for non-SOLD_OUT alerts', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alertTypes: AlertType[] = ['OPPORTUNITY', 'FILLING_FAST', 'NEWLY_AVAILABLE']

      for (const type of alertTypes) {
        const alert = createAlert(type)
        const payload = getPayload(notifier, alert)

        // Should have 3 blocks (header + section + actions)
        expect(payload.blocks).toHaveLength(3)

        // Verify actions block exists and is correctly structured
        const actionsBlock = payload.blocks[2]
        expect(actionsBlock.type).toBe('actions')
        expect(actionsBlock.block_id).toBe('actions_block')
        // 4 buttons: Register Now + Registered + Not Interested + Remind Later
        expect(actionsBlock.elements).toHaveLength(4)
      }
    })
  })

  describe('Interactive Button Validation', () => {
    it('includes three interactive buttons with correct action_ids', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')
      const payload = getPayload(notifier, alert)

      const elements = payload.blocks[2].elements

      // First button is the link button (Register Now)
      expect(elements[0].url).toBeTruthy()
      expect(elements[0].action_id).toBeUndefined()

      // Interactive buttons
      expect(elements[1].action_id).toBe('session_registered')
      expect(elements[1].text.text).toBe('✅ Registered')

      expect(elements[2].action_id).toBe('session_not_interested')
      expect(elements[2].text.text).toBe('❌ Not Interested')

      expect(elements[3].action_id).toBe('session_remind_later')
      expect(elements[3].text.text).toBe('⏰ Remind Later')
    })

    it('encodes session identity in button values as pipe-delimited string', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')
      const payload = getPayload(notifier, alert)

      const expectedValue = '2026-02-20|06:00|(PLAYERS) ADULT Pick Up MORNINGS'
      const elements = payload.blocks[2].elements

      // All interactive buttons share the same session value
      expect(elements[1].value).toBe(expectedValue)
      expect(elements[2].value).toBe(expectedValue)
      expect(elements[3].value).toBe(expectedValue)

      // Link button has no value
      expect(elements[0].value).toBeUndefined()
    })

    it('interactive buttons have no url (they are not link buttons)', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('FILLING_FAST')
      const payload = getPayload(notifier, alert)

      const elements = payload.blocks[2].elements

      expect(elements[1].url).toBeUndefined()
      expect(elements[2].url).toBeUndefined()
      expect(elements[3].url).toBeUndefined()
    })

    it('interactive buttons have no style (use default appearance)', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')
      const payload = getPayload(notifier, alert)

      const elements = payload.blocks[2].elements

      // Interactive buttons should not have style set
      expect(elements[1].style).toBeUndefined()
      expect(elements[2].style).toBeUndefined()
      expect(elements[3].style).toBeUndefined()
    })
  })

  describe('Button Style Validation (Critical for Slack API)', () => {
    it('uses only valid button styles accepted by Slack API', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const validStyles = ['primary', 'danger', undefined]

      // Test each alert type that has a button
      const alertTypes: AlertType[] = ['OPPORTUNITY', 'FILLING_FAST', 'NEWLY_AVAILABLE']

      for (const type of alertTypes) {
        const alert = createAlert(type)
        const payload = getPayload(notifier, alert)

        const button = payload.blocks[2].elements[0]
        const style = button.style

        // CRITICAL: Slack only accepts 'primary', 'danger', or undefined
        // Using 'default' will cause 400 Bad Request
        expect(validStyles).toContain(style)
        expect(style).not.toBe('default')
      }
    })

    it('uses danger style for FILLING_FAST (urgency)', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('FILLING_FAST')
      const payload = getPayload(notifier, alert)

      const button = payload.blocks[2].elements[0]
      expect(button.style).toBe('danger')
    })

    it('uses primary style for OPPORTUNITY and NEWLY_AVAILABLE', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')

      for (const type of ['OPPORTUNITY', 'NEWLY_AVAILABLE'] as AlertType[]) {
        const alert = createAlert(type)
        const payload = getPayload(notifier, alert)

        const button = payload.blocks[2].elements[0]
        expect(button.style).toBe('primary')
      }
    })
  })

  describe('Button Structure Validation', () => {
    it('has required button fields with correct types', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY')
      const payload = getPayload(notifier, alert)

      const button = payload.blocks[2].elements[0]

      // Required fields for button element
      expect(button.type).toBe('button')
      expect(button.text).toBeDefined()
      expect(button.text.type).toBe('plain_text')
      expect(button.text.text).toBeTruthy()
      expect(button.url).toBeTruthy()

      // URL must be valid HTTPS
      expect(button.url).toMatch(/^https:\/\//)
    })

    it('includes valid registration URL in button', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('FILLING_FAST')
      const payload = getPayload(notifier, alert)

      const button = payload.blocks[2].elements[0]

      // Verify URL contains date parameter
      expect(button.url).toContain('date=2026-02-20')
      expect(button.url).toContain('extremeice')
    })
  })

  describe('Message Content Validation', () => {
    it('formats SOLD_OUT message correctly (no player counts)', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('SOLD_OUT', {
        playersRegistered: 24,
        playersMax: 24,
        isFull: true,
      })
      const payload = getPayload(notifier, alert)

      const messageText = payload.blocks[1].text.text

      // SOLD_OUT should not include player counts (session is full)
      expect(messageText).toContain('Friday, Feb 20')
      expect(messageText).toContain('6:00am')
      expect(messageText).toContain('full')
      expect(messageText).not.toContain('Players:')
    })

    it('formats OPPORTUNITY message with player counts', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY', {
        playersRegistered: 14,
        playersMax: 24,
        goaliesRegistered: 2,
        goaliesMax: 3,
      })
      const payload = getPayload(notifier, alert)

      const messageText = payload.blocks[1].text.text

      expect(messageText).toContain('Friday, Feb 20')
      expect(messageText).toContain('6:00am')
      expect(messageText).toContain('14/24')
      expect(messageText).toContain('2/3')
      expect(messageText).toContain('10 spots left')
    })

    it('formats FILLING_FAST message with urgency indicator', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('FILLING_FAST', {
        playersRegistered: 20,
        playersMax: 24,
      })
      const payload = getPayload(notifier, alert)

      const messageText = payload.blocks[1].text.text

      expect(messageText).toContain('20/24')
      expect(messageText).toContain('4 spots left')
      expect(messageText).toContain('Act now')
    })

    it('formats NEWLY_AVAILABLE message with spots count', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('NEWLY_AVAILABLE', {
        playersRegistered: 20,
        playersMax: 24,
        isFull: false,
      })
      const payload = getPayload(notifier, alert)

      const messageText = payload.blocks[1].text.text

      expect(messageText).toContain('Spots opened up')
      expect(messageText).toContain('spots available')
      expect(messageText).toMatch(/\*4\*|4/)
    })
  })

  describe('Edge Cases', () => {
    it('handles singular spot remaining correctly', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('OPPORTUNITY', {
        playersRegistered: 23,
        playersMax: 24,
      })
      const payload = getPayload(notifier, alert)

      const messageText = payload.blocks[1].text.text

      // Should say "1 spot left" not "1 spots left"
      expect(messageText).toContain('1 spot left')
      expect(messageText).not.toContain('1 spots')
    })

    it('handles zero spots remaining', () => {
      const notifier = new SlackNotifier('https://hooks.slack.com/test')
      const alert = createAlert('SOLD_OUT', {
        playersRegistered: 24,
        playersMax: 24,
        isFull: true,
      })
      const payload = getPayload(notifier, alert)

      const messageText = payload.blocks[1].text.text

      // Should indicate session is full, not "0 spots"
      expect(messageText).toContain('full')
    })
  })
})
