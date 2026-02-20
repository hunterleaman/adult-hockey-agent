import type { Request, Response } from 'express'
import { verifySlackSignature } from '../interactions/verify.js'
import { loadState, type SessionState } from '../state.js'
import type { AlertType, UserResponse } from '../evaluator.js'
import fs from 'fs'

interface SlackBlock {
  type: string
  text?: {
    type: string
    text: string
    emoji?: boolean
  }
  elements?: Array<{
    type: string
    text: string
  }>
}

interface SlackCommandResponse {
  response_type: 'ephemeral' | 'in_channel'
  blocks: SlackBlock[]
}

export interface CommandHandlerDeps {
  signingSecret: string
  statePath: string
}

/**
 * Express route handler for POST /slack/commands.
 * Verifies signature, loads state, returns Block Kit response.
 */
export function createCommandHandler(
  deps: CommandHandlerDeps
): (req: Request, res: Response) => void {
  return (req: Request, res: Response): void => {
    const rawBody = (req as Request & { rawBody?: string }).rawBody
    if (!rawBody) {
      res.status(400).json({ error: 'Missing request body' })
      return
    }

    const signature = req.headers['x-slack-signature'] as string | undefined
    const timestamp = req.headers['x-slack-request-timestamp'] as string | undefined

    if (!signature || !timestamp) {
      res.status(400).json({ error: 'Missing Slack signature headers' })
      return
    }

    if (!verifySlackSignature(deps.signingSecret, signature, timestamp, rawBody)) {
      res.status(401).json({ error: 'Invalid signature' })
      return
    }

    const body = req.body as Record<string, unknown> | undefined
    const command = body?.command as string | undefined

    if (command !== '/sessions') {
      res.status(400).json({ error: 'Unknown command' })
      return
    }

    const state = loadState(deps.statePath)
    const lastPoll = getLastPollTimestamp(deps.statePath)
    const response = buildSessionsResponse(state, lastPoll)

    res.status(200).json(response)
  }
}

/**
 * Build a Block Kit response showing all tracked sessions.
 * Pure function — no side effects, easy to test.
 */
export function buildSessionsResponse(
  state: SessionState[],
  lastPoll: string | null
): SlackCommandResponse {
  if (state.length === 0) {
    return {
      response_type: 'ephemeral',
      blocks: [
        {
          type: 'section',
          text: {
            type: 'mrkdwn',
            text: 'No sessions currently tracked. Sessions appear after the next poll cycle.',
          },
        },
      ],
    }
  }

  // Sort by date ascending, then time ascending
  const sorted = [...state].sort((a, b) => {
    const dateCompare = a.session.date.localeCompare(b.session.date)
    if (dateCompare !== 0) return dateCompare
    return a.session.time.localeCompare(b.session.time)
  })

  const blocks: SlackBlock[] = [
    {
      type: 'header',
      text: {
        type: 'plain_text',
        text: 'Hockey Sessions (next 5 days)',
        emoji: true,
      },
    },
  ]

  for (const entry of sorted) {
    blocks.push({
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: formatSessionBlock(entry),
      },
    })
    blocks.push({ type: 'divider' })
  }

  // Footer with last poll time
  const footerParts: string[] = []
  if (lastPoll) {
    const pollDate = new Date(lastPoll)
    footerParts.push(`Last polled: ${formatTimestamp(pollDate)}`)
  }
  blocks.push({
    type: 'context',
    elements: [
      {
        type: 'mrkdwn',
        text: footerParts.length > 0 ? footerParts.join(' | ') : 'No poll data available.',
      },
    ],
  })

  return {
    response_type: 'ephemeral',
    blocks,
  }
}

function formatSessionBlock(entry: SessionState): string {
  const { session } = entry
  const spotsRemaining = session.playersMax - session.playersRegistered
  const status = session.isFull
    ? ':no_entry: *FULL*'
    : `:white_check_mark: *Open* (${spotsRemaining} spot${spotsRemaining === 1 ? '' : 's'} left)`
  const regUrl = `https://apps.daysmartrecreation.com/dash/x/#/online/extremeice/event-registration?date=${session.date}&facility_ids=1`

  let text = `*${session.dayOfWeek}, ${formatDate(session.date)}* at *${formatTime(session.time)}*\n`
  text += `Players: *${session.playersRegistered}/${session.playersMax}* | Goalies: *${session.goaliesRegistered}/${session.goaliesMax}*\n`
  text += `Status: ${status}\n`

  if (entry.lastAlertType) {
    text += `Alert: _${formatAlertType(entry.lastAlertType)}_\n`
  }

  if (entry.userResponse) {
    text += `Response: _${formatUserResponse(entry.userResponse)}_\n`
  }

  text += `<${regUrl}|Register>`

  return text
}

function formatAlertType(type: AlertType): string {
  const labels: Record<AlertType, string> = {
    OPPORTUNITY: 'Opportunity',
    FILLING_FAST: 'FILLING FAST',
    SOLD_OUT: 'SOLD OUT',
    NEWLY_AVAILABLE: 'Newly Available',
  }
  return labels[type]
}

function formatUserResponse(response: UserResponse): string {
  const labels: Record<UserResponse, string> = {
    registered: 'Registered',
    not_interested: 'Not Interested',
    remind_later: 'Remind Later',
  }
  return labels[response]
}

function formatDate(date: string): string {
  const d = new Date(date + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

function formatTime(time: string): string {
  const [hours, minutes] = time.split(':').map(Number)
  const period = hours >= 12 ? 'pm' : 'am'
  const displayHours = hours % 12 || 12
  return `${displayHours}:${minutes.toString().padStart(2, '0')}${period}`
}

function formatTimestamp(date: Date): string {
  return date.toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZoneName: 'short',
  })
}

function getLastPollTimestamp(statePath: string): string | null {
  try {
    if (!fs.existsSync(statePath)) return null
    const stats = fs.statSync(statePath)
    return stats.mtime.toISOString()
  } catch {
    return null
  }
}
