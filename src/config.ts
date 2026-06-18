export interface Config {
  pollIntervalMinutes: number
  pollIntervalAcceleratedMinutes: number
  pollStartHour: number
  pollEndHour: number
  forwardWindowDays: number
  company: string
  approachWindowHours: number
  maxSleepHours: number
  minGoalies: number
  minPlayersRegistered: number
  playerSpotsUrgent: number
  morningPickupMaxHour: number
  canaryThresholdPolls: number
  port: number
  slackWebhookUrl?: string
  slackSigningSecret?: string
  slackBotToken?: string
  remindIntervalHours: number
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
    // DASH tenant slug. The rink rebranded Extreme Ice -> Charlotte Ice and moved
    // to the `charlotteice` tenant; the old `extremeice` tenant is now a stale
    // mirror (missing the 6am pickup, zeroed registration counts). Env-overridable
    // so the next rename is a config change, not a deploy.
    company: process.env.DASH_COMPANY?.trim() || 'charlotteice',
    approachWindowHours: parseIntOrDefault(process.env.APPROACH_WINDOW_HOURS, 96),
    maxSleepHours: parseIntOrDefault(process.env.MAX_SLEEP_HOURS, 12),
    minGoalies: parseIntOrDefault(process.env.MIN_GOALIES, 1),
    minPlayersRegistered: parseIntOrDefault(process.env.MIN_PLAYERS_REGISTERED, 10),
    playerSpotsUrgent: parseIntOrDefault(process.env.PLAYER_SPOTS_URGENT, 4),
    morningPickupMaxHour: parseIntOrDefault(process.env.MORNING_PICKUP_MAX_HOUR, 9),
    // Canary: number of consecutive polls that find no usable pickup data before
    // the agent warns that it has likely gone blind (tenant/parser regression).
    canaryThresholdPolls: parseIntOrDefault(process.env.CANARY_THRESHOLD_POLLS, 3),
    port: parseIntOrDefault(process.env.PORT, 3000),
    slackWebhookUrl: process.env.SLACK_WEBHOOK_URL || undefined,
    slackSigningSecret: process.env.SLACK_SIGNING_SECRET || undefined,
    slackBotToken: process.env.SLACK_BOT_TOKEN || undefined,
    remindIntervalHours: parseIntOrDefault(process.env.REMIND_INTERVAL_HOURS, 2),
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

  if (!config.company || config.company.trim() === '') {
    throw new Error('company must not be empty')
  }

  if (config.approachWindowHours <= 0) {
    throw new Error('approachWindowHours must be > 0')
  }

  if (config.maxSleepHours <= 0) {
    throw new Error('maxSleepHours must be > 0')
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

  if (config.morningPickupMaxHour < 0 || config.morningPickupMaxHour > 23) {
    throw new Error('morningPickupMaxHour must be 0-23')
  }

  if (config.canaryThresholdPolls <= 0) {
    throw new Error('canaryThresholdPolls must be > 0')
  }

  if (config.port <= 0 || config.port > 65535) {
    throw new Error('port must be 1-65535')
  }

  if (config.slackWebhookUrl) {
    try {
      new URL(config.slackWebhookUrl)
    } catch {
      throw new Error('slackWebhookUrl must be a valid URL')
    }
  }

  if (config.remindIntervalHours <= 0) {
    throw new Error('remindIntervalHours must be > 0')
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
