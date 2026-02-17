import type { Config } from './config'
import type { Notifier } from './notifiers/interface'
import { scrapeEvents } from './scraper.js'
import { evaluate } from './evaluator.js'
import { loadState, saveState, pruneOldSessions, updateSessionState } from './state.js'
import { ConsoleNotifier } from './notifiers/console.js'
import { SlackNotifier } from './notifiers/slack.js'

const DEFAULT_STATE_PATH = './data/state.json'

/**
 * Create configured notifiers based on config
 */
export function createNotifiers(config: Config): Notifier[] {
  const notifiers: Notifier[] = []

  // Console notifier always active
  notifiers.push(new ConsoleNotifier())

  // Slack notifier if configured
  if (config.slackWebhookUrl) {
    const slack = new SlackNotifier(config.slackWebhookUrl)
    if (slack.isConfigured()) {
      notifiers.push(slack)
    }
  }

  return notifiers
}

/**
 * Execute one poll cycle:
 * 1. Scrape events from DASH
 * 2. Load previous state
 * 3. Prune old sessions
 * 4. Evaluate alerts
 * 5. Send notifications
 * 6. Update and save state
 */
export async function poll(config: Config, statePath: string = DEFAULT_STATE_PATH): Promise<void> {
  try {
    // Step 1: Scrape current events
    const sessions = await scrapeEvents(new Date(), config.forwardWindowDays)

    // Step 2: Load and prune state
    let state = loadState(statePath)
    state = pruneOldSessions(state, new Date())

    // Step 3: Evaluate alerts
    const alerts = evaluate(sessions, state, config)

    // Step 4: Send notifications
    const notifiers = createNotifiers(config)
    for (const alert of alerts) {
      for (const notifier of notifiers) {
        try {
          await notifier.send(alert)
        } catch (error) {
          console.error(`Failed to send via ${notifier.name}:`, error)
        }
      }
    }

    // Step 5: Update state for each session
    // Track which sessions had alerts
    const alertedSessions = new Map(
      alerts.map((a) => [
        `${a.session.date}:${a.session.time}`,
        { type: a.type, at: new Date().toISOString() },
      ])
    )

    for (const session of sessions) {
      const key = `${session.date}:${session.time}`
      const alertInfo = alertedSessions.get(key)

      state = updateSessionState(state, session, alertInfo?.type || null, alertInfo?.at || null)
    }

    // Step 6: Save state
    saveState(statePath, state)
  } catch (_error) {
    // TODO: Use structured logger when available
    // Gracefully handle errors - log but don't crash
    // The next poll cycle will retry
  }
}
