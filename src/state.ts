import * as fs from 'fs'
import * as path from 'path'
import type { SessionState, AlertType } from './evaluator'
import type { Session } from './parser'

/**
 * Load session state from disk.
 * Returns empty array if file doesn't exist or is invalid.
 */
export function loadState(filePath: string): SessionState[] {
  try {
    if (!fs.existsSync(filePath)) {
      return []
    }

    const contents = fs.readFileSync(filePath, 'utf-8').trim()
    if (!contents) {
      return []
    }

    const state = JSON.parse(contents)
    return Array.isArray(state) ? state : []
  } catch (error) {
    // TODO: Use structured logger when available
    // Gracefully handle corrupted/invalid state files
    return []
  }
}

/**
 * Save session state to disk using atomic write (temp file + rename).
 * Creates parent directory if it doesn't exist.
 */
export function saveState(filePath: string, state: SessionState[]): void {
  const dir = path.dirname(filePath)
  const tempPath = path.join(dir, `.${path.basename(filePath)}.tmp`)

  try {
    // Ensure directory exists
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true })
    }

    // Write to temp file
    fs.writeFileSync(tempPath, JSON.stringify(state, null, 2), 'utf-8')

    // Atomic rename
    fs.renameSync(tempPath, filePath)
  } catch (error) {
    // Clean up temp file if it exists
    if (fs.existsSync(tempPath)) {
      try {
        fs.unlinkSync(tempPath)
      } catch {
        // Ignore cleanup errors
      }
    }
    throw error
  }
}

/**
 * Remove sessions older than the specified date (default: today).
 * Sessions with date >= compareDate are kept.
 */
export function pruneOldSessions(
  state: SessionState[],
  compareDate: Date = new Date()
): SessionState[] {
  const compareDateStr = compareDate.toISOString().split('T')[0]

  return state.filter((s) => s.session.date >= compareDateStr)
}

/**
 * Update the registration status for a specific session.
 * Returns new state array (immutable update).
 */
export function updateRegistrationStatus(
  state: SessionState[],
  date: string,
  time: string,
  isRegistered: boolean
): SessionState[] {
  return state.map((s) => {
    if (s.session.date === date && s.session.time === time) {
      return {
        ...s,
        isRegistered,
      }
    }
    return s
  })
}

/**
 * Update session state after a poll cycle.
 * If session doesn't exist in state, creates new entry.
 * If alert was fired, updates lastAlertType, lastAlertAt, and lastPlayerCount.
 * Always updates the session data to reflect current values.
 */
export function updateSessionState(
  state: SessionState[],
  session: Session,
  alertType: AlertType | null,
  alertAt: string | null
): SessionState[] {
  const existingIndex = state.findIndex(
    (s) => s.session.date === session.date && s.session.time === session.time
  )

  const existingState = existingIndex >= 0 ? state[existingIndex] : null

  const newState: SessionState = {
    session,
    lastAlertType: alertType !== null ? alertType : existingState?.lastAlertType ?? null,
    lastAlertAt: alertAt !== null ? alertAt : existingState?.lastAlertAt ?? null,
    lastPlayerCount: alertType !== null ? session.playersRegistered : existingState?.lastPlayerCount ?? null,
    isRegistered: existingState?.isRegistered ?? false,
  }

  if (existingIndex >= 0) {
    // Update existing entry
    return state.map((s, i) => (i === existingIndex ? newState : s))
  } else {
    // Add new entry
    return [...state, newState]
  }
}
