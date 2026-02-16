import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { loadConfig, validateConfig } from '../src/config'
import type { Config } from '../src/config'

describe('config', () => {
  const originalEnv = process.env

  beforeEach(() => {
    // Reset process.env before each test
    process.env = { ...originalEnv }
  })

  afterEach(() => {
    // Restore original environment
    process.env = originalEnv
  })

  describe('loadConfig', () => {
    it('loads config with all defaults when no env vars set', () => {
      const config = loadConfig()

      expect(config.pollIntervalMinutes).toBe(60)
      expect(config.pollIntervalAcceleratedMinutes).toBe(30)
      expect(config.pollStartHour).toBe(6)
      expect(config.pollEndHour).toBe(23)
      expect(config.forwardWindowDays).toBe(5)
      expect(config.minGoalies).toBe(1)
      expect(config.minPlayersRegistered).toBe(10)
      expect(config.playerSpotsUrgent).toBe(4)
      expect(config.slackWebhookUrl).toBeUndefined()
    })

    it('loads SLACK_WEBHOOK_URL from env', () => {
      process.env.SLACK_WEBHOOK_URL = 'https://hooks.slack.com/test'

      const config = loadConfig()

      expect(config.slackWebhookUrl).toBe('https://hooks.slack.com/test')
    })

    it('loads custom polling intervals from env', () => {
      process.env.POLL_INTERVAL_MINUTES = '90'
      process.env.POLL_INTERVAL_ACCELERATED_MINUTES = '45'

      const config = loadConfig()

      expect(config.pollIntervalMinutes).toBe(90)
      expect(config.pollIntervalAcceleratedMinutes).toBe(45)
    })

    it('loads custom polling hours from env', () => {
      process.env.POLL_START_HOUR = '8'
      process.env.POLL_END_HOUR = '22'

      const config = loadConfig()

      expect(config.pollStartHour).toBe(8)
      expect(config.pollEndHour).toBe(22)
    })

    it('loads custom forward window from env', () => {
      process.env.FORWARD_WINDOW_DAYS = '7'

      const config = loadConfig()

      expect(config.forwardWindowDays).toBe(7)
    })

    it('loads custom alert thresholds from env', () => {
      process.env.MIN_GOALIES = '3'
      process.env.MIN_PLAYERS_REGISTERED = '8'
      process.env.PLAYER_SPOTS_URGENT = '3'

      const config = loadConfig()

      expect(config.minGoalies).toBe(3)
      expect(config.minPlayersRegistered).toBe(8)
      expect(config.playerSpotsUrgent).toBe(3)
    })

    it('ignores invalid numeric values and uses defaults', () => {
      process.env.POLL_INTERVAL_MINUTES = 'invalid'
      process.env.POLL_START_HOUR = 'not-a-number'

      const config = loadConfig()

      expect(config.pollIntervalMinutes).toBe(60) // default
      expect(config.pollStartHour).toBe(6) // default
    })

    it('ignores empty string env vars and uses defaults', () => {
      process.env.POLL_INTERVAL_MINUTES = ''
      process.env.FORWARD_WINDOW_DAYS = ''

      const config = loadConfig()

      expect(config.pollIntervalMinutes).toBe(60)
      expect(config.forwardWindowDays).toBe(5)
    })

    it('treats empty SLACK_WEBHOOK_URL as undefined', () => {
      process.env.SLACK_WEBHOOK_URL = ''

      const config = loadConfig()

      expect(config.slackWebhookUrl).toBeUndefined()
    })
  })

  describe('validateConfig', () => {
    it('accepts valid config with all defaults', () => {
      const config: Config = {
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

      expect(() => validateConfig(config)).not.toThrow()
    })

    it('accepts valid config with Slack webhook', () => {
      const config: Config = {
        pollIntervalMinutes: 60,
        pollIntervalAcceleratedMinutes: 30,
        pollStartHour: 6,
        pollEndHour: 23,
        forwardWindowDays: 5,
        minGoalies: 1,
        minPlayersRegistered: 10,
        playerSpotsUrgent: 4,
        slackWebhookUrl: 'https://hooks.slack.com/test',
      }

      expect(() => validateConfig(config)).not.toThrow()
    })

    it('throws when poll interval is zero', () => {
      const config = loadConfig()
      config.pollIntervalMinutes = 0

      expect(() => validateConfig(config)).toThrow('pollIntervalMinutes must be > 0')
    })

    it('throws when poll interval is negative', () => {
      const config = loadConfig()
      config.pollIntervalMinutes = -5

      expect(() => validateConfig(config)).toThrow('pollIntervalMinutes must be > 0')
    })

    it('throws when accelerated interval is zero', () => {
      const config = loadConfig()
      config.pollIntervalAcceleratedMinutes = 0

      expect(() => validateConfig(config)).toThrow('pollIntervalAcceleratedMinutes must be > 0')
    })

    it('throws when pollStartHour is out of range', () => {
      const config = loadConfig()
      config.pollStartHour = 24

      expect(() => validateConfig(config)).toThrow('pollStartHour must be 0-23')
    })

    it('throws when pollEndHour is out of range', () => {
      const config = loadConfig()
      config.pollEndHour = -1

      expect(() => validateConfig(config)).toThrow('pollEndHour must be 0-23')
    })

    it('throws when pollEndHour <= pollStartHour', () => {
      const config = loadConfig()
      config.pollStartHour = 10
      config.pollEndHour = 10

      expect(() => validateConfig(config)).toThrow('pollEndHour must be > pollStartHour')
    })

    it('throws when forwardWindowDays is zero', () => {
      const config = loadConfig()
      config.forwardWindowDays = 0

      expect(() => validateConfig(config)).toThrow('forwardWindowDays must be > 0')
    })

    it('throws when minGoalies is negative', () => {
      const config = loadConfig()
      config.minGoalies = -1

      expect(() => validateConfig(config)).toThrow('minGoalies must be >= 0')
    })

    it('throws when minPlayersRegistered is zero', () => {
      const config = loadConfig()
      config.minPlayersRegistered = 0

      expect(() => validateConfig(config)).toThrow('minPlayersRegistered must be > 0')
    })

    it('throws when playerSpotsUrgent is zero', () => {
      const config = loadConfig()
      config.playerSpotsUrgent = 0

      expect(() => validateConfig(config)).toThrow('playerSpotsUrgent must be > 0')
    })

    it('throws when Slack webhook URL is invalid', () => {
      const config = loadConfig()
      config.slackWebhookUrl = 'not-a-url'

      expect(() => validateConfig(config)).toThrow('slackWebhookUrl must be a valid URL')
    })

    it('accepts valid Slack webhook URL', () => {
      const config = loadConfig()
      config.slackWebhookUrl = 'https://hooks.slack.com/services/T00/B00/XXX'

      expect(() => validateConfig(config)).not.toThrow()
    })
  })

  describe('integration', () => {
    it('loadConfig returns validated config', () => {
      process.env.POLL_INTERVAL_MINUTES = '120'
      process.env.SLACK_WEBHOOK_URL = 'https://hooks.slack.com/test'

      const config = loadConfig()

      expect(() => validateConfig(config)).not.toThrow()
      expect(config.pollIntervalMinutes).toBe(120)
      expect(config.slackWebhookUrl).toBe('https://hooks.slack.com/test')
    })
  })
})
