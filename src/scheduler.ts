#!/usr/bin/env node
import 'dotenv/config'
import cron from 'node-cron'
import { loadConfig, validateConfig } from './config.js'
import { poll } from './index.js'

const STATE_PATH = './data/state.json'

/**
 * Main entry point - runs the agent with scheduled polling
 */
async function main() {
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

    // Run initial poll immediately
    console.log(
      `⏰ Running initial poll at ${new Date().toLocaleString('en-US', { timeZone: 'America/New_York' })}`
    )
    await poll(config, STATE_PATH)
    console.log('✓ Initial poll complete\n')

    // Schedule regular polls
    const cronSchedule = `*/${config.pollIntervalMinutes} * * * *` // Every N minutes
    console.log(`📅 Scheduling polls: ${cronSchedule}`)
    console.log(`   (every ${config.pollIntervalMinutes} minutes)\n`)

    cron.schedule(cronSchedule, async () => {
      const now = new Date()
      const etHour = parseInt(
        now.toLocaleString('en-US', {
          timeZone: 'America/New_York',
          hour: '2-digit',
          hour12: false,
        })
      )

      // Check if within active hours
      if (etHour >= config.pollStartHour && etHour <= config.pollEndHour) {
        console.log(
          `⏰ Polling at ${now.toLocaleString('en-US', { timeZone: 'America/New_York' })}`
        )
        await poll(config, STATE_PATH)
        console.log('✓ Poll complete\n')
      } else {
        console.log(`⏸  Outside active hours (${etHour}:00 ET) - skipping poll\n`)
      }
    })

    console.log('✅ Agent running. Press Ctrl+C to stop.\n')

    // Keep process alive
    process.on('SIGINT', () => {
      console.log('\n👋 Shutting down gracefully...')
      process.exit(0)
    })

    process.on('SIGTERM', () => {
      console.log('\n👋 Shutting down gracefully...')
      process.exit(0)
    })
  } catch (error) {
    console.error('❌ Failed to start agent:', error)
    process.exit(1)
  }
}

export { main }

// Run main when module is executed
main()
