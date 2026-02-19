import type { UserResponse } from '../evaluator.js'
import { loadState, saveState, updateUserResponse } from '../state.js'

export interface ParsedAction {
  actionId: string
  value: string
  responseUrl: string
}

export interface SessionIdentity {
  date: string
  time: string
  eventName: string
}

export interface ActionResult {
  userResponse: UserResponse
  date: string
  time: string
  eventName: string
  found: boolean
  responseUrl: string
}

const VALID_ACTIONS: Record<string, UserResponse> = {
  session_registered: 'registered',
  session_not_interested: 'not_interested',
  session_remind_later: 'remind_later',
}

/**
 * Parse a Slack block_actions interaction payload.
 * Returns null if the payload is not a valid interaction we handle.
 */
export function parseInteractionPayload(payload: unknown): ParsedAction | null {
  if (typeof payload !== 'object' || payload === null) return null

  const p = payload as Record<string, unknown>
  if (p.type !== 'block_actions') return null

  const actions = p.actions
  if (!Array.isArray(actions) || actions.length === 0) return null

  const action = actions[0] as Record<string, unknown>
  const actionId = action.action_id
  const value = action.value
  const responseUrl = p.response_url

  if (typeof actionId !== 'string' || typeof value !== 'string' || typeof responseUrl !== 'string')
    return null

  return { actionId, value, responseUrl }
}

/**
 * Parse the pipe-delimited session identity from a button value.
 * Format: {date}|{time}|{eventName}
 */
export function parseActionValue(value: string): SessionIdentity | null {
  const parts = value.split('|')
  if (parts.length < 3) return null

  const [date, time, ...rest] = parts
  const eventName = rest.join('|')

  if (!date || !time || !eventName) return null

  return { date, time, eventName }
}

/**
 * Process a Slack interaction: parse payload, update state, return result.
 * Returns null if the payload is invalid or the action is unrecognized.
 */
export function processInteraction(
  statePath: string,
  payload: unknown,
  remindIntervalHours: number
): ActionResult | null {
  const parsed = parseInteractionPayload(payload)
  if (!parsed) return null

  const userResponse = VALID_ACTIONS[parsed.actionId]
  if (!userResponse) return null

  const sessionId = parseActionValue(parsed.value)
  if (!sessionId) return null

  const state = loadState(statePath)
  const found = state.some(
    (s) => s.session.date === sessionId.date && s.session.time === sessionId.time
  )

  if (found) {
    const updatedState = updateUserResponse(
      state,
      sessionId.date,
      sessionId.time,
      userResponse,
      remindIntervalHours
    )
    saveState(statePath, updatedState)
  }

  return {
    userResponse,
    date: sessionId.date,
    time: sessionId.time,
    eventName: sessionId.eventName,
    found,
    responseUrl: parsed.responseUrl,
  }
}
