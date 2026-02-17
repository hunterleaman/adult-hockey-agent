import type { Session } from './parser'
import type { Config } from './config'

export type AlertType = 'OPPORTUNITY' | 'FILLING_FAST' | 'SOLD_OUT' | 'NEWLY_AVAILABLE'

export interface SessionState {
  session: Session
  lastAlertType: AlertType | null
  lastAlertAt: string | null // ISO timestamp
  lastPlayerCount: number | null
  isRegistered: boolean
}

export interface Alert {
  type: AlertType
  session: Session
  message: string
  registrationUrl: string
}

export function evaluate(
  sessions: Session[],
  previousState: SessionState[],
  config: Config
): Alert[] {
  const alerts: Alert[] = []
  const now = new Date()

  for (const session of sessions) {
    // Skip sessions in the past
    const sessionDateTime = new Date(`${session.date}T${session.time}:00`)
    if (sessionDateTime < now) {
      continue
    }

    const prevState = findPreviousState(session, previousState)

    // Alert priority hierarchy - only ONE alert per session
    // Priority: SOLD_OUT > NEWLY_AVAILABLE > FILLING_FAST > OPPORTUNITY

    // Priority 1: SOLD_OUT - transitioned from available to full
    if (prevState && session.isFull && !prevState.session.isFull) {
      alerts.push(createAlert('SOLD_OUT', session))
      continue
    }

    // Priority 2: NEWLY_AVAILABLE - transitioned from full to available
    if (prevState && !session.isFull && prevState.session.isFull) {
      alerts.push(createAlert('NEWLY_AVAILABLE', session))
      continue
    }

    // Skip remaining alert types for registered sessions
    if (prevState?.isRegistered) {
      continue
    }

    // Skip remaining alert types if session is full
    if (session.isFull) {
      continue
    }

    // Calculate player spots remaining
    const spotsRemaining = session.playersMax - session.playersRegistered

    // Priority 3: FILLING_FAST - urgency alert when spots are running out
    if (spotsRemaining <= config.playerSpotsUrgent) {
      if (shouldAlertFillingFast(session, prevState)) {
        alerts.push(createAlert('FILLING_FAST', session))
        continue
      }
    }

    // Priority 4: OPPORTUNITY - general interest alert
    if (
      session.goaliesRegistered >= config.minGoalies &&
      session.playersRegistered >= config.minPlayersRegistered
    ) {
      if (shouldAlertOpportunity(session, prevState)) {
        alerts.push(createAlert('OPPORTUNITY', session))
        continue
      }
    }
  }

  // Sort alerts chronologically (earliest first)
  return alerts.sort((a, b) => {
    const dateCompare = a.session.date.localeCompare(b.session.date)
    if (dateCompare !== 0) return dateCompare
    return a.session.time.localeCompare(b.session.time)
  })
}

function findPreviousState(
  session: Session,
  previousState: SessionState[]
): SessionState | undefined {
  return previousState.find(
    (state) => state.session.date === session.date && state.session.time === session.time
  )
}

function shouldAlertOpportunity(session: Session, prevState: SessionState | undefined): boolean {
  // CRITICAL: Don't downgrade from higher-priority alerts
  // If previous alert was FILLING_FAST, NEWLY_AVAILABLE, or SOLD_OUT,
  // suppress OPPORTUNITY (maintains alert hierarchy)
  if (
    prevState?.lastAlertType === 'FILLING_FAST' ||
    prevState?.lastAlertType === 'NEWLY_AVAILABLE' ||
    prevState?.lastAlertType === 'SOLD_OUT'
  ) {
    return false
  }

  // No previous alert OR previous was also OPPORTUNITY - check if we should fire
  if (!prevState || prevState.lastAlertType !== 'OPPORTUNITY') {
    return true
  }

  // Suppression rule: only re-alert if spots decreased by >= 2
  const prevSpotsRemaining = session.playersMax - (prevState.lastPlayerCount ?? 0)
  const currentSpotsRemaining = session.playersMax - session.playersRegistered
  const decrease = prevSpotsRemaining - currentSpotsRemaining

  return decrease >= 2
}

function shouldAlertFillingFast(session: Session, prevState: SessionState | undefined): boolean {
  // CRITICAL: Don't downgrade from higher-priority alerts
  // If previous alert was NEWLY_AVAILABLE or SOLD_OUT, suppress FILLING_FAST
  // unless session state has changed (more registrations)
  if (prevState?.lastAlertType === 'NEWLY_AVAILABLE' || prevState?.lastAlertType === 'SOLD_OUT') {
    // Only allow FILLING_FAST if spots decreased since the higher-priority alert
    const prevPlayerCount = prevState.lastPlayerCount ?? 0
    return session.playersRegistered > prevPlayerCount
  }

  // No previous alert OR previous was also FILLING_FAST - check if we should fire
  if (!prevState || prevState.lastAlertType !== 'FILLING_FAST') {
    return true
  }

  // Suppression rule: only re-alert if spots decreased
  const prevPlayerCount = prevState.lastPlayerCount ?? 0
  return session.playersRegistered > prevPlayerCount
}

function createAlert(type: AlertType, session: Session): Alert {
  const spotsRemaining = session.playersMax - session.playersRegistered

  const messages: Record<AlertType, string> = {
    OPPORTUNITY: `🏒 OPPORTUNITY: ${session.dayOfWeek} ${formatDate(session.date)}, ${formatTime(session.time)}\nPlayers: ${session.playersRegistered}/${session.playersMax} (${spotsRemaining} spots left)\nGoalies: ${session.goaliesRegistered}/${session.goaliesMax}\nStatus: Worth signing up!`,
    FILLING_FAST: `⚡ FILLING FAST: ${session.dayOfWeek} ${formatDate(session.date)}, ${formatTime(session.time)}\nPlayers: ${session.playersRegistered}/${session.playersMax} (${spotsRemaining} spots left)\nGoalies: ${session.goaliesRegistered}/${session.goaliesMax}\nStatus: Act now!`,
    SOLD_OUT: `🚫 SOLD OUT: ${session.dayOfWeek} ${formatDate(session.date)}, ${formatTime(session.time)}\nSession is now full.`,
    NEWLY_AVAILABLE: `✅ NEWLY AVAILABLE: ${session.dayOfWeek} ${formatDate(session.date)}, ${formatTime(session.time)}\nSpots opened up! ${spotsRemaining} spot${spotsRemaining === 1 ? '' : 's'} available.`,
  }

  return {
    type,
    session,
    message: messages[type],
    registrationUrl: buildRegistrationUrl(session.date),
  }
}

function formatDate(date: string): string {
  // Convert YYYY-MM-DD to "Feb 20"
  const d = new Date(date + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

function formatTime(time: string): string {
  // Convert HH:MM to "6:00am"
  const [hours, minutes] = time.split(':').map(Number)
  const period = hours >= 12 ? 'pm' : 'am'
  const displayHours = hours % 12 || 12
  return `${displayHours}:${minutes.toString().padStart(2, '0')}${period}`
}

function buildRegistrationUrl(date: string): string {
  return `https://apps.daysmartrecreation.com/dash/x/#/online/extremeice/event-registration?date=${date}&facility_ids=1`
}
