#!/usr/bin/env node
import 'dotenv/config'
import type { Server } from 'http'
import { loadConfig, validateConfig } from './config.js'
import { poll } from './index.js'
import { loadState } from './state.js'
import { startServer } from './server.js'

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
 * Get current ET hour for active hours check
 */
function getCurrentETHour(): number {
  const now = new Date()
  return parseInt(
    now.toLocaleString('en-US', {
      timeZone: 'America/New_York',
      hour: '2-digit',
      hour12: false,
    })
  )
}

/**
 * Schedule the next poll with dynamic interval based on session state
 */
function scheduleNextPoll(config: ReturnType<typeof loadConfig>): void {
  // Determine interval based on session state
  const accelerate = shouldAccelerate(config)
  const intervalMinutes = accelerate
    ? config.pollIntervalAcceleratedMinutes
    : config.pollIntervalMinutes
  const intervalMs = intervalMinutes * 60 * 1000

  console.log(
    `📅 Next poll in ${intervalMinutes} minutes ${accelerate ? '(accelerated - FILLING_FAST detected)' : '(normal)'}`
  )

  scheduledTimeout = setTimeout(() => {
    void (async () => {
      const etHour = getCurrentETHour()

      // Check if within active hours
      if (etHour >= config.pollStartHour && etHour <= config.pollEndHour) {
        console.log(
          `⏰ Polling at ${new Date().toLocaleString('en-US', { timeZone: 'America/New_York' })}`
        )
        await poll(config, STATE_PATH)
        console.log('✓ Poll complete\n')

        // Schedule next poll (recursive)
        scheduleNextPoll(config)
      } else {
        console.log(`⏸  Outside active hours (${etHour}:00 ET) - skipping poll\n`)

        // Still schedule next poll to check again later
        scheduleNextPoll(config)
      }
    })()
  }, intervalMs)
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
    console.log(`   Slack: ${config.slackWebhookUrl ? 'configured ✓' : 'not configured'}`)
    console.log()

    // Start HTTP server for health endpoint and Slack interactions
    httpServer = startServer(config.port, {
      statePath: STATE_PATH,
      slackSigningSecret: config.slackSigningSecret,
      remindIntervalHours: config.remindIntervalHours,
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

    // Start dynamic polling
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
