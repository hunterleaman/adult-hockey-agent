#!/usr/bin/env node
import 'dotenv/config'
import type { Server } from 'http'
import { loadConfig, validateConfig } from './config.js'
import { poll } from './index.js'
import { loadState } from './state.js'
import { startServer } from './server.js'
import { calculateNextPollDelay, getNextSessionTime } from './poll-schedule.js'

const STATE_PATH = './data/state.json'

let scheduledTimeout: NodeJS.Timeout | null = null
let httpServer: Server | null = null

/**
 * Check if any tracked session requires accelerated polling
 * (any session with <= playerSpotsUrgent spots remaining)
 */
function shouldAccelerate(config: ReturnType<typeof loadConfig>): boolean {
  const state = loadState(STATE_PATH)

  for (const sessionState of state) {
    const session = sessionState.session
    const spotsRemaining = session.playersMax - session.playersRegistered

    // Check if session is in FILLING_FAST range
    if (!session.isFull && spotsRemaining <= config.playerSpotsUrgent) {
      return true
    }
  }

  return false
}

/**
 * Schedule the next poll using smart timing based on session proximity.
 * Sleeps until the approach window opens when no sessions are imminent,
 * then uses normal/accelerated intervals during active polling.
 */
function scheduleNextPoll(config: ReturnType<typeof loadConfig>): void {
  const now = new Date()
  const state = loadState(STATE_PATH)
  const nextSession = getNextSessionTime(state, now)
  const accelerated = shouldAccelerate(config)

  const schedule = calculateNextPollDelay(now, nextSession, config, accelerated)

  console.log(schedule.scheduleLog)

  scheduledTimeout = setTimeout(() => {
    void (async () => {
      console.log(schedule.wakeLog)
      await poll(config, STATE_PATH)
      console.log('✓ Poll complete\n')

      // Schedule next poll (recursive)
      scheduleNextPoll(config)
    })()
  }, schedule.delayMs)
}

/**
 * Main entry point - runs the agent with dynamic polling
 */
async function main(): Promise<void> {
  try {
    // Load and validate configuration
    const config = loadConfig()
    validateConfig(config)

    console.log('🏒 Adult Hockey Agent starting...')
    console.log(`📋 Config:`)
    console.log(`   Poll interval: ${config.pollIntervalMinutes} minutes`)
    console.log(`   Accelerated interval: ${config.pollIntervalAcceleratedMinutes} minutes`)
    console.log(`   Active hours: ${config.pollStartHour}:00 - ${config.pollEndHour}:00 ET`)
    console.log(`   Forward window: ${config.forwardWindowDays} days`)
    console.log(`   Approach window: ${config.approachWindowHours} hours`)
    console.log(`   Max sleep: ${config.maxSleepHours} hours`)
    console.log(`   Slack: ${config.slackWebhookUrl ? 'configured ✓' : 'not configured'}`)
    console.log()

    // Start HTTP server for health endpoint and Slack interactions
    httpServer = startServer(config.port, {
      statePath: STATE_PATH,
      slackSigningSecret: config.slackSigningSecret,
      remindIntervalHours: config.remindIntervalHours,
      company: config.company,
    })
    console.log(`🌐 Health endpoint available at http://localhost:${config.port}/health`)
    if (config.slackSigningSecret) {
      console.log(`🔗 Slack interactions at http://localhost:${config.port}/slack/interactions`)
    }
    console.log()

    // Run initial poll immediately
    console.log(
      `⏰ Running initial poll at ${new Date().toLocaleString('en-US', { timeZone: 'America/New_York' })}`
    )
    await poll(config, STATE_PATH)
    console.log('✓ Initial poll complete\n')

    // Start smart polling
    scheduleNextPoll(config)

    console.log('✅ Agent running. Press Ctrl+C to stop.\n')

    // Graceful shutdown
    process.on('SIGINT', () => {
      console.log('\n👋 Shutting down gracefully...')
      if (scheduledTimeout) {
        clearTimeout(scheduledTimeout)
      }
      if (httpServer) {
        httpServer.close(() => {
          console.log('✓ HTTP server stopped')
          process.exit(0)
        })
      } else {
        process.exit(0)
      }
    })

    process.on('SIGTERM', () => {
      console.log('\n👋 Shutting down gracefully...')
      if (scheduledTimeout) {
        clearTimeout(scheduledTimeout)
      }
      if (httpServer) {
        httpServer.close(() => {
          console.log('✓ HTTP server stopped')
          process.exit(0)
        })
      } else {
        process.exit(0)
      }
    })
  } catch (error) {
    console.error('❌ Failed to start agent:', error)
    process.exit(1)
  }
}

export { main }

// Run main when module is executed
void main()
