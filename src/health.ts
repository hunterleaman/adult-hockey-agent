import * as fs from 'fs'
import * as path from 'path'

/**
 * Health state for the canary — a watchdog that detects silent data outages
 * (the agent polling normally but seeing no usable pickup data, e.g. after a
 * DASH tenant migration or a parser-breaking rename). Persisted separately from
 * session state so the SessionState[] file shape stays untouched.
 */
export interface HealthState {
  consecutiveSuspectPolls: number
  canaryActive: boolean
  lastTransitionAt: string | null // ISO timestamp of the last fire/recover
}

export interface HealthEvaluation {
  health: HealthState
  notification: string | null
}

export function defaultHealthState(): HealthState {
  return { consecutiveSuspectPolls: 0, canaryActive: false, lastTransitionAt: null }
}

/**
 * Load health state from disk. Returns a fresh default on missing/corrupt file.
 */
export function loadHealth(filePath: string): HealthState {
  try {
    if (!fs.existsSync(filePath)) {
      return defaultHealthState()
    }

    const contents = fs.readFileSync(filePath, 'utf-8').trim()
    if (!contents) {
      return defaultHealthState()
    }

    const parsed = JSON.parse(contents) as Partial<HealthState>
    return {
      consecutiveSuspectPolls:
        typeof parsed.consecutiveSuspectPolls === 'number' ? parsed.consecutiveSuspectPolls : 0,
      canaryActive: parsed.canaryActive === true,
      lastTransitionAt:
        typeof parsed.lastTransitionAt === 'string' ? parsed.lastTransitionAt : null,
    }
  } catch {
    // Gracefully handle corrupted/invalid health files
    return defaultHealthState()
  }
}

/**
 * Save health state to disk using atomic write (temp file + rename).
 */
export function saveHealth(filePath: string, health: HealthState): void {
  const dir = path.dirname(filePath)
  const tempPath = path.join(dir, `.${path.basename(filePath)}.tmp`)

  try {
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true })
    }

    fs.writeFileSync(tempPath, JSON.stringify(health, null, 2), 'utf-8')
    fs.renameSync(tempPath, filePath)
  } catch (error) {
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
 * Decide whether the agent is seeing usable pickup data and whether to fire (or
 * clear) the canary.
 *
 * A poll is "healthy" when it found at least one session AND at least one session
 * has real registrations. This catches both failure modes the agent has hit:
 * the parser dropping every session (0 sessions) and a stale DASH tenant
 * returning sessions with all-zero counts.
 *
 * Fires one warning when suspect polls reach the threshold, then stays quiet
 * until a healthy poll recovers it (which fires one recovery message).
 */
export function evaluateHealth(
  sessionCount: number,
  hasRegistrations: boolean,
  prev: HealthState,
  thresholdPolls: number,
  nowIso: string
): HealthEvaluation {
  const healthy = sessionCount > 0 && hasRegistrations

  if (healthy) {
    const recovered = prev.canaryActive
    return {
      health: {
        consecutiveSuspectPolls: 0,
        canaryActive: false,
        lastTransitionAt: recovered ? nowIso : prev.lastTransitionAt,
      },
      notification: recovered
        ? `✅ Adult Hockey Agent recovered — ${sessionCount} pickup session(s) visible again.`
        : null,
    }
  }

  const consecutiveSuspectPolls = prev.consecutiveSuspectPolls + 1
  const shouldFire = consecutiveSuspectPolls >= thresholdPolls && !prev.canaryActive

  return {
    health: {
      consecutiveSuspectPolls,
      canaryActive: prev.canaryActive || shouldFire,
      lastTransitionAt: shouldFire ? nowIso : prev.lastTransitionAt,
    },
    notification: shouldFire
      ? `⚠️ Adult Hockey Agent: found 0 usable pickup sessions for ${consecutiveSuspectPolls} consecutive polls. DASH may have renamed teams or migrated tenants again — check the rink's registration page.`
      : null,
  }
}
