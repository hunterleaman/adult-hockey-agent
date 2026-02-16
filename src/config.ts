export interface Config {
  pollIntervalMinutes: number
  pollIntervalAcceleratedMinutes: number
  pollStartHour: number
  pollEndHour: number
  forwardWindowDays: number
  minGoalies: number
  minPlayersRegistered: number
  playerSpotsUrgent: number
  slackWebhookUrl?: string
}

/**
 * Load configuration from environment variables with defaults
 */
export function loadConfig(): Config {
  return {
    pollIntervalMinutes: parseIntOrDefault(process.env.POLL_INTERVAL_MINUTES, 60),
    pollIntervalAcceleratedMinutes: parseIntOrDefault(
      process.env.POLL_INTERVAL_ACCELERATED_MINUTES,
      30
    ),
    pollStartHour: parseIntOrDefault(process.env.POLL_START_HOUR, 6),
    pollEndHour: parseIntOrDefault(process.env.POLL_END_HOUR, 23),
    forwardWindowDays: parseIntOrDefault(process.env.FORWARD_WINDOW_DAYS, 5),
    minGoalies: parseIntOrDefault(process.env.MIN_GOALIES, 1),
    minPlayersRegistered: parseIntOrDefault(process.env.MIN_PLAYERS_REGISTERED, 10),
    playerSpotsUrgent: parseIntOrDefault(process.env.PLAYER_SPOTS_URGENT, 4),
    slackWebhookUrl: process.env.SLACK_WEBHOOK_URL || undefined,
  }
}

/**
 * Validate configuration values
 * Throws descriptive errors if any values are invalid
 */
export function validateConfig(config: Config): void {
  if (config.pollIntervalMinutes <= 0) {
    throw new Error('pollIntervalMinutes must be > 0')
  }

  if (config.pollIntervalAcceleratedMinutes <= 0) {
    throw new Error('pollIntervalAcceleratedMinutes must be > 0')
  }

  if (config.pollStartHour < 0 || config.pollStartHour > 23) {
    throw new Error('pollStartHour must be 0-23')
  }

  if (config.pollEndHour < 0 || config.pollEndHour > 23) {
    throw new Error('pollEndHour must be 0-23')
  }

  if (config.pollEndHour <= config.pollStartHour) {
    throw new Error('pollEndHour must be > pollStartHour')
  }

  if (config.forwardWindowDays <= 0) {
    throw new Error('forwardWindowDays must be > 0')
  }

  if (config.minGoalies < 0) {
    throw new Error('minGoalies must be >= 0')
  }

  if (config.minPlayersRegistered <= 0) {
    throw new Error('minPlayersRegistered must be > 0')
  }

  if (config.playerSpotsUrgent <= 0) {
    throw new Error('playerSpotsUrgent must be > 0')
  }

  if (config.slackWebhookUrl) {
    try {
      new URL(config.slackWebhookUrl)
    } catch {
      throw new Error('slackWebhookUrl must be a valid URL')
    }
  }
}

function parseIntOrDefault(value: string | undefined, defaultValue: number): number {
  if (!value || value.trim() === '') {
    return defaultValue
  }

  const parsed = parseInt(value, 10)
  if (isNaN(parsed)) {
    return defaultValue
  }

  return parsed
}
