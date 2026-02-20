import type { SessionState } from './evaluator'

export interface PollScheduleResult {
  delayMs: number
  reason: 'approach' | 'sleep' | 'fallback'
  scheduleLog: string
  wakeLog: string
}

interface ScheduleConfig {
  approachWindowHours: number
  maxSleepHours: number
  pollIntervalMinutes: number
  pollIntervalAcceleratedMinutes: number
  pollStartHour: number
  pollEndHour: number
}

/**
 * Parse a session date+time (ET wall-clock) into a UTC Date object.
 * Handles both EST (UTC-5) and EDT (UTC-4) automatically.
 */
export function parseSessionTimeET(dateStr: string, timeStr: string): Date {
  const [year, month, day] = dateStr.split('-').map(Number)
  const [hours, minutes] = timeStr.split(':').map(Number)

  // Try EST (UTC-5) first, then EDT (UTC-4)
  const estCandidate = new Date(Date.UTC(year, month - 1, day, hours + 5, minutes))
  const estCheck = getETComponents(estCandidate)

  if (estCheck.hour === hours && estCheck.minute === minutes) {
    return estCandidate
  }

  return new Date(Date.UTC(year, month - 1, day, hours + 4, minutes))
}

/**
 * Find the earliest future session time from state.
 * Returns null if no future sessions exist.
 */
export function getNextSessionTime(sessions: SessionState[], now: Date): Date | null {
  let earliest: Date | null = null

  for (const s of sessions) {
    const sessionTime = parseSessionTimeET(s.session.date, s.session.time)
    if (sessionTime <= now) continue
    if (earliest === null || sessionTime < earliest) {
      earliest = sessionTime
    }
  }

  return earliest
}

/**
 * Calculate the optimal delay until the next poll based on session proximity.
 *
 * - Inside approach window: use normal/accelerated interval
 * - Outside approach window: sleep until approach window opens (capped at maxSleepHours)
 * - No sessions: sleep maxSleepHours (fallback)
 * - All wake times are clamped to active hours (pollStartHour/pollEndHour ET)
 */
export function calculateNextPollDelay(
  now: Date,
  nextSessionTimeUTC: Date | null,
  config: ScheduleConfig,
  accelerated: boolean
): PollScheduleResult {
  const maxSleepMs = config.maxSleepHours * 60 * 60 * 1000

  // No sessions: fallback to max sleep
  if (nextSessionTimeUTC === null) {
    const fallbackWake = new Date(now.getTime() + maxSleepMs)
    const clampedWake = clampToActiveHoursET(fallbackWake, config.pollStartHour, config.pollEndHour)
    const delayMs = clampedWake.getTime() - now.getTime()

    return {
      delayMs,
      reason: 'fallback',
      scheduleLog: `💤 No upcoming sessions found. Fallback wake: ${formatDateET(clampedWake)} (max ${config.maxSleepHours}h).`,
      wakeLog: `⏰ Max sleep reached (${config.maxSleepHours}h). Running fallback poll.`,
    }
  }

  // Calculate approach window open time
  const approachWindowOpenUTC = new Date(
    nextSessionTimeUTC.getTime() - config.approachWindowHours * 60 * 60 * 1000
  )

  // Inside approach window: use normal/accelerated interval
  if (now.getTime() >= approachWindowOpenUTC.getTime()) {
    const intervalMinutes = accelerated
      ? config.pollIntervalAcceleratedMinutes
      : config.pollIntervalMinutes
    const intervalMs = intervalMinutes * 60 * 1000

    const wakeTime = new Date(now.getTime() + intervalMs)
    const clampedWake = clampToActiveHoursET(wakeTime, config.pollStartHour, config.pollEndHour)
    const delayMs = clampedWake.getTime() - now.getTime()

    const modeLabel = accelerated ? 'accelerated - FILLING_FAST detected' : 'normal'

    return {
      delayMs,
      reason: 'approach',
      scheduleLog: `⏰ Approach window open for ${formatDateET(nextSessionTimeUTC)}. Next poll in ${intervalMinutes} minutes (${modeLabel}).`,
      wakeLog: `⏰ Polling (approach window for ${formatDateET(nextSessionTimeUTC)}).`,
    }
  }

  // Outside approach window: sleep until approach opens or max sleep
  const maxWakeUTC = new Date(now.getTime() + maxSleepMs)
  const useFallback = approachWindowOpenUTC.getTime() > maxWakeUTC.getTime()
  const targetWake = useFallback ? maxWakeUTC : approachWindowOpenUTC
  const clampedWake = clampToActiveHoursET(targetWake, config.pollStartHour, config.pollEndHour)
  const delayMs = clampedWake.getTime() - now.getTime()

  const hoursUntilApproach = Math.round(
    (approachWindowOpenUTC.getTime() - now.getTime()) / (60 * 60 * 1000)
  )

  if (useFallback) {
    return {
      delayMs,
      reason: 'fallback',
      scheduleLog: `💤 No sessions in approach window. Next session: ${formatDateET(nextSessionTimeUTC)}. Approach window opens in ${hoursUntilApproach}h. Fallback wake: ${formatDateET(clampedWake)} (max ${config.maxSleepHours}h).`,
      wakeLog: `⏰ Max sleep reached (${config.maxSleepHours}h). Running fallback poll.`,
    }
  }

  return {
    delayMs,
    reason: 'sleep',
    scheduleLog: `💤 No sessions in approach window. Next session: ${formatDateET(nextSessionTimeUTC)}. Sleeping until ${formatDateET(clampedWake)} (approach window opens in ${hoursUntilApproach}h). Fallback wake: ${formatDateET(maxWakeUTC)} (max ${config.maxSleepHours}h).`,
    wakeLog: `⏰ Approach window open for ${formatDateET(nextSessionTimeUTC)}. Resuming normal polling.`,
  }
}

/**
 * Format a UTC Date as ET for logging.
 * Example: "Wed, Feb 25, 7:30 PM ET"
 */
export function formatDateET(date: Date): string {
  return (
    date.toLocaleString('en-US', {
      timeZone: 'America/New_York',
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
      hour12: true,
    }) + ' ET'
  )
}

/**
 * Get date/time components in ET from a UTC Date.
 */
function getETComponents(date: Date): {
  year: number
  month: number
  day: number
  hour: number
  minute: number
} {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hourCycle: 'h23',
    hour: '2-digit',
    minute: '2-digit',
  }).formatToParts(date)

  return {
    year: parseInt(parts.find((p) => p.type === 'year')!.value),
    month: parseInt(parts.find((p) => p.type === 'month')!.value),
    day: parseInt(parts.find((p) => p.type === 'day')!.value),
    hour: parseInt(parts.find((p) => p.type === 'hour')!.value),
    minute: parseInt(parts.find((p) => p.type === 'minute')!.value),
  }
}

/**
 * Clamp a wake time to the next active hours window in ET.
 * If the wake time falls outside pollStartHour–pollEndHour ET,
 * push it to the next pollStartHour (same day or next day).
 */
function clampToActiveHoursET(wakeTime: Date, pollStartHour: number, pollEndHour: number): Date {
  const et = getETComponents(wakeTime)

  if (et.hour >= pollStartHour && et.hour <= pollEndHour) {
    return wakeTime
  }

  // Outside active hours — push to next pollStartHour in ET
  let targetDateStr: string
  if (et.hour < pollStartHour) {
    // Before active hours today — use pollStartHour today
    targetDateStr = `${et.year}-${pad(et.month)}-${pad(et.day)}`
  } else {
    // After active hours — use pollStartHour tomorrow
    const nextDay = new Date(wakeTime.getTime() + 24 * 60 * 60 * 1000)
    const nextET = getETComponents(nextDay)
    targetDateStr = `${nextET.year}-${pad(nextET.month)}-${pad(nextET.day)}`
  }

  return parseSessionTimeET(targetDateStr, `${pad(pollStartHour)}:00`)
}

function pad(n: number): string {
  return String(n).padStart(2, '0')
}
