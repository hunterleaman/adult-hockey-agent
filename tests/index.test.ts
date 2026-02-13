import { describe, it, expect } from 'vitest'
import { createNotifiers } from '../src/index'
import type { Config } from '../src/config'

describe('index', () => {
  const createConfig = (overrides: Partial<Config> = {}): Config => ({
    pollIntervalMinutes: 60,
    pollIntervalAcceleratedMinutes: 30,
    pollStartHour: 6,
    pollEndHour: 23,
    forwardWindowDays: 5,
    minGoalies: 2,
    playerSpotsAlert: 10,
    playerSpotsUrgent: 4,
    slackWebhookUrl: undefined,
    ...overrides,
  })

  describe('createNotifiers', () => {
    it('creates console notifier only when slack not configured', () => {
      const config = createConfig()

      const notifiers = createNotifiers(config)

      expect(notifiers).toHaveLength(1)
      expect(notifiers[0].name).toBe('Console')
      expect(notifiers[0].isConfigured()).toBe(true)
    })

    it('creates console and slack notifiers when slack configured', () => {
      const config = createConfig({
        slackWebhookUrl: 'https://hooks.slack.com/test',
      })

      const notifiers = createNotifiers(config)

      expect(notifiers).toHaveLength(2)
      expect(notifiers[0].name).toBe('Console')
      expect(notifiers[1].name).toBe('Slack')
      expect(notifiers[0].isConfigured()).toBe(true)
      expect(notifiers[1].isConfigured()).toBe(true)
    })

    it('filters out unconfigured slack notifier', () => {
      const config = createConfig({
        slackWebhookUrl: '', // Empty = not configured
      })

      const notifiers = createNotifiers(config)

      expect(notifiers).toHaveLength(1)
      expect(notifiers[0].name).toBe('Console')
    })

    it('all notifiers implement the Notifier interface', () => {
      const config = createConfig({
        slackWebhookUrl: 'https://hooks.slack.com/test',
      })

      const notifiers = createNotifiers(config)

      for (const notifier of notifiers) {
        expect(notifier).toHaveProperty('name')
        expect(notifier).toHaveProperty('send')
        expect(notifier).toHaveProperty('isConfigured')
        expect(typeof notifier.send).toBe('function')
        expect(typeof notifier.isConfigured).toBe('function')
      }
    })
  })

  describe('poll function exists', () => {
    it('exports poll function', async () => {
      const { poll } = await import('../src/index')
      expect(typeof poll).toBe('function')
    })
  })
})
