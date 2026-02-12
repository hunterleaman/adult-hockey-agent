export interface Session {
  date: string // YYYY-MM-DD
  dayOfWeek: string // Monday | Wednesday | Friday
  time: string // HH:MM (24h)
  timeLabel: string // "6:00am - 7:10am"
  eventName: string // Full event name from DASH
  playersRegistered: number
  playersMax: number
  goaliesRegistered: number
  goaliesMax: number
  isFull: boolean // Derived: playersRegistered >= playersMax
  price: number
}

interface JsonApiEvent {
  id: string
  type: string
  attributes: {
    start: string
    end: string
    [key: string]: any
  }
  relationships: {
    homeTeam?: {
      data: { type: string; id: string } | null
    }
    summary?: {
      data: { type: string; id: string } | null
    }
    [key: string]: any
  }
}

interface JsonApiIncluded {
  id: string
  type: string
  attributes: any
}

interface JsonApiResponse {
  data: JsonApiEvent[]
  included?: JsonApiIncluded[]
}

interface ParsedEvent {
  eventId: string
  teamName: string
  startTime: string
  endTime: string
  registered: number
  capacity: number
  price: number
}

export function parseEvents(apiResponse: JsonApiResponse): Session[] {
  const { data, included = [] } = apiResponse

  // Create lookup maps for relationships
  const includedMap = new Map<string, JsonApiIncluded>()
  included.forEach((item) => {
    const key = `${item.type}:${item.id}`
    includedMap.set(key, item)
  })

  // Parse all events and resolve relationships
  const parsedEvents: ParsedEvent[] = []

  for (const event of data) {
    // Get homeTeam name
    const homeTeamData = event.relationships.homeTeam?.data
    if (!homeTeamData) continue

    const homeTeamKey = `${homeTeamData.type}:${homeTeamData.id}`
    const homeTeam = includedMap.get(homeTeamKey)
    if (!homeTeam) continue

    const teamName = homeTeam.attributes?.name || ''
    const teamNameLower = teamName.toLowerCase()

    // Filter for ADULT Pick Up only (exclude Broomball, leagues, etc.)
    if (!teamNameLower.includes('adult pick up')) continue
    if (teamNameLower.includes('broomball')) continue

    // Get summary data for registration counts
    const summaryData = event.relationships.summary?.data
    if (!summaryData) continue

    const summaryKey = `${summaryData.type}:${summaryData.id}`
    const summary = includedMap.get(summaryKey)
    if (!summary) continue

    const registered = summary.attributes?.registered_count || 0
    const capacity = summary.attributes?.composite_capacity || 0

    // Price is in event attributes or summary - using 0 as default for now
    // TODO: Find actual price field in API response
    const price = 0

    parsedEvents.push({
      eventId: event.id,
      teamName,
      startTime: event.attributes.start,
      endTime: event.attributes.end,
      registered,
      capacity,
      price,
    })
  }

  // Group by time slot and pair PLAYERS with GOALIES
  const sessionMap = new Map<string, Partial<Session>>()

  for (const event of parsedEvents) {
    const startDate = new Date(event.startTime)
    const endDate = new Date(event.endTime)

    // Extract date and time
    const date = event.startTime.split('T')[0]
    const time = formatTime24h(startDate)
    const timeLabel = formatTimeLabel(startDate, endDate)
    const dayOfWeek = getDayOfWeek(startDate)

    const sessionKey = `${date}:${time}`

    if (!sessionMap.has(sessionKey)) {
      sessionMap.set(sessionKey, {
        date,
        dayOfWeek,
        time,
        timeLabel,
        eventName: '', // Will be set from PLAYERS entry
        playersRegistered: 0,
        playersMax: 0,
        goaliesRegistered: 0,
        goaliesMax: 0,
        isFull: false,
        price: event.price,
      })
    }

    const session = sessionMap.get(sessionKey)!

    if (event.teamName.includes('(PLAYERS)')) {
      session.playersRegistered = event.registered
      session.playersMax = event.capacity
      session.eventName = event.teamName
    } else if (event.teamName.includes('(GOALIES)')) {
      session.goaliesRegistered = event.registered
      session.goaliesMax = event.capacity
      // If eventName not set yet, use this (shouldn't happen in practice)
      if (!session.eventName) {
        session.eventName = event.teamName
      }
    }
  }

  // Convert to Session[] and calculate derived fields
  const sessions: Session[] = []

  for (const session of sessionMap.values()) {
    // Only include sessions that have both PLAYERS and GOALIES data
    if (session.playersMax! > 0 && session.goaliesMax! > 0) {
      session.isFull = session.playersRegistered! >= session.playersMax!
      sessions.push(session as Session)
    }
  }

  // Sort by time
  sessions.sort((a, b) => a.time.localeCompare(b.time))

  return sessions
}

function formatTime24h(date: Date): string {
  const hours = String(date.getHours()).padStart(2, '0')
  const minutes = String(date.getMinutes()).padStart(2, '0')
  return `${hours}:${minutes}`
}

function formatTimeLabel(start: Date, end: Date): string {
  const formatTime12h = (date: Date): string => {
    let hours = date.getHours()
    const minutes = date.getMinutes()
    const ampm = hours >= 12 ? 'pm' : 'am'
    hours = hours % 12 || 12
    const minutesStr = minutes > 0 ? `:${String(minutes).padStart(2, '0')}` : ''
    return `${hours}${minutesStr}${ampm}`
  }

  return `${formatTime12h(start)} - ${formatTime12h(end)}`
}

function getDayOfWeek(date: Date): string {
  const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
  return days[date.getDay()]
}
