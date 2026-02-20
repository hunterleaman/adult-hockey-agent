import express, { type Express, type Request } from 'express'
import type { Server } from 'http'
import fs from 'fs'
import { createInteractionHandler } from './interactions/handler.js'
import { createCommandHandler } from './commands/sessions.js'

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

export interface ServerOptions {
  statePath: string
  slackSigningSecret?: string
  remindIntervalHours?: number
}

/**
 * Create Express server with health endpoint and Slack interaction route
 */
export function createServer(options: ServerOptions): Express {
  const app = express()

  // Parse URL-encoded bodies (Slack sends application/x-www-form-urlencoded)
  // Capture raw body for signature verification
  app.use(
    express.urlencoded({
      extended: false,
      verify: (req: Request, _res, buf) => {
        ;(req as Request & { rawBody?: string }).rawBody = buf.toString()
      },
    })
  )

  // Health check endpoint
  app.get('/health', (_req, res) => {
    const lastPoll = getLastPollTimestamp(options.statePath)

    res.json({
      status: 'ok',
      uptime: process.uptime(),
      lastPoll,
    })
  })

  // Slack interaction endpoint
  if (options.slackSigningSecret) {
    app.post(
      '/slack/interactions',
      createInteractionHandler({
        signingSecret: options.slackSigningSecret,
        statePath: options.statePath,
        remindIntervalHours: options.remindIntervalHours ?? 2,
      })
    )

    // Slack slash command endpoint
    app.post(
      '/slack/commands',
      createCommandHandler({
        signingSecret: options.slackSigningSecret,
        statePath: options.statePath,
      })
    )
  }

  return app
}

/**
 * Start the Express server on the configured port
 */
export function startServer(port: number, options: ServerOptions): Server {
  const app = createServer(options)

  const server = app.listen(port, () => {
    // Server started successfully
    // Log message is handled by scheduler.ts
  })

  return server
}
