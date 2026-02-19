import type { Request, Response } from 'express'
import { verifySlackSignature } from './verify.js'
import { processInteraction } from './actions.js'
import { buildConfirmationText, sendConfirmation } from './confirm.js'

export interface InteractionHandlerDeps {
  signingSecret: string
  statePath: string
  remindIntervalHours: number
}

/**
 * Express route handler for POST /slack/interactions.
 * Verifies signature, processes action, updates state, returns 200.
 */
export function createInteractionHandler(
  deps: InteractionHandlerDeps
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

    // Parse the payload from form-encoded body
    const body = req.body as Record<string, unknown> | undefined
    const payloadStr = body?.payload as string | undefined
    if (!payloadStr) {
      res.status(400).json({ error: 'Missing payload' })
      return
    }

    let payload: unknown
    try {
      payload = JSON.parse(payloadStr)
    } catch {
      res.status(400).json({ error: 'Invalid payload JSON' })
      return
    }

    // Process the interaction (parse action, update state)
    const result = processInteraction(deps.statePath, payload, deps.remindIntervalHours)

    // Respond 200 immediately (Slack requires <3s response)
    res.status(200).send()

    // Fire-and-forget: send ephemeral confirmation via response_url
    if (result) {
      const text = buildConfirmationText(result, deps.remindIntervalHours)
      void sendConfirmation(result.responseUrl, text).catch(() => {})
    }
  }
}
