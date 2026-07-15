import * as path from 'path'
import type { Config } from './config'
import type { Notifier } from './notifiers/interface'
import type { Session } from './parser'
import { scrapeEvents } from './scraper.js'
import { evaluate } from './evaluator.js'
import {
  loadState,
  saveState,
  pruneOldSessions,
  updateSessionState,
  mergeUserResponses,
} from './state.js'
import { loadHealth, saveHealth, evaluateHealth } from './health.js'
import { ConsoleNotifier } from './notifiers/console.js'
import { SlackNotifier } from './notifiers/slack.js'
import { sessionKey } from './session-identity.js'

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
 * 7. Canary: warn if the agent has seen no usable pickup data for N polls
 */
export async function poll(config: Config, statePath: string = DEFAULT_STATE_PATH): Promise<void> {
  const notifiers = createNotifiers(config)
  let sessions: Session[] = []

  try {
    // Step 1: Scrape current events
    sessions = await scrapeEvents(
      new Date(),
      config.forwardWindowDays,
      config.company,
      config.facilityLabels
    )

    // Step 2: Load and prune state
    let state = loadState(statePath)
    state = pruneOldSessions(state, new Date())

    // Step 3: Evaluate alerts
    const alerts = evaluate(sessions, state, config)

    // Step 4: Send notifications
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
      alerts.map((a) => [sessionKey(a.session), { type: a.type, at: new Date().toISOString() }])
    )

    for (const session of sessions) {
      const alertInfo = alertedSessions.get(sessionKey(session))

      state = updateSessionState(state, session, alertInfo?.type || null, alertInfo?.at || null)
    }

    // Step 6: Re-read fresh state to preserve user responses from Slack interactions
    // that may have arrived during the async poll window
    const freshState = loadState(statePath)
    state = mergeUserResponses(state, freshState)

    // Step 7: Save state
    saveState(statePath, state)
  } catch (error) {
    // Gracefully handle errors - log but don't crash. The next poll cycle retries.
    // A thrown scrape leaves `sessions` empty, which the canary below correctly
    // counts as a suspect poll, so hard API failures also trip the warning.
    // TODO: Use structured logger when available
    console.error('Poll cycle error:', error)
  }

  // Step 8: Canary — detect silent data outages. Runs regardless of whether the
  // poll above succeeded so that scrape failures and zeroed/empty data both count.
  try {
    const healthPath = path.join(path.dirname(statePath), 'health.json')
    const prevHealth = loadHealth(healthPath)
    const hasRegistrations = sessions.some((s) => s.playersRegistered > 0)
    const { health, notification } = evaluateHealth(
      sessions.length,
      hasRegistrations,
      prevHealth,
      config.canaryThresholdPolls,
      new Date().toISOString()
    )

    if (notification) {
      for (const notifier of notifiers) {
        try {
          await notifier.sendDiagnostic(notification)
        } catch (error) {
          console.error(`Failed to send canary via ${notifier.name}:`, error)
        }
      }
    }

    saveHealth(healthPath, health)
  } catch (error) {
    // TODO: Use structured logger when available
    console.error('Canary error:', error)
  }
}
