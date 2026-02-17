import express, { type Express } from 'express'
import type { Server } from 'http'
import fs from 'fs'

/**
 * Get the most recent poll timestamp from state file modification time
 * The state file is updated after every poll, so its mtime reflects the last poll time
 */
function getLastPollTimestamp(statePath: string): string | null {
  try {
    // Check if state file exists
    if (!fs.existsSync(statePath)) {
      return null
    }

    // Get file stats
    const stats = fs.statSync(statePath)

    // Return modification time as ISO string
    return stats.mtime.toISOString()
  } catch {
    // If there's any error reading file stats, return null
    return null
  }
}

/**
 * Create Express server with health endpoint
 */
export function createServer(statePath: string): Express {
  const app = express()

  // Health check endpoint
  app.get('/health', (_req, res) => {
    const lastPoll = getLastPollTimestamp(statePath)

    res.json({
      status: 'ok',
      uptime: process.uptime(),
      lastPoll,
    })
  })

  return app
}

/**
 * Start the Express server on the configured port
 */
export function startServer(port: number, statePath: string): Server {
  const app = createServer(statePath)

  const server = app.listen(port, () => {
    // Server started successfully
    // Log message is handled by scheduler.ts
  })

  return server
}
