import { parseEvents } from './parser.js'
import type { Session } from './parser'

const BASE_URL = 'https://apps.daysmartrecreation.com'
const DEFAULT_COMPANY = 'charlotteice'

interface DateAvailabilitiesResponse {
  data: Array<{
    id: string
    attributes: {
      events: number[]
    }
  }>
}

/**
 * Calculate target dates (every day) within forward window from today.
 * Post-merger, PIH runs pickup on days XIC never did (e.g. Tuesdays), so the
 * scraper covers all days; the evaluator's morning gate controls alert volume.
 */
export function calculateTargetDates(today: Date = new Date(), forwardDays: number = 5): string[] {
  const dates: string[] = []
  const endDate = new Date(today)
  endDate.setDate(endDate.getDate() + forwardDays)

  const current = new Date(today)
  while (current <= endDate) {
    dates.push(current.toISOString().split('T')[0])
    current.setDate(current.getDate() + 1)
  }

  return dates
}

/**
 * Extract event IDs for target dates from date-availabilities response
 */
export function extractEventIds(
  response: DateAvailabilitiesResponse,
  targetDates: string[]
): number[] {
  const eventIds: number[] = []
  const seen = new Set<number>()

  for (const dateEntry of response.data) {
    if (targetDates.includes(dateEntry.id)) {
      for (const eventId of dateEntry.attributes.events || []) {
        if (!seen.has(eventId)) {
          seen.add(eventId)
          eventIds.push(eventId)
        }
      }
    }
  }

  return eventIds
}

/**
 * Scrape events from DASH API for all dates within forward window.
 * Returns parsed Session[] via two-step fetch: date-availabilities → events.
 * `company` is the DASH tenant slug (default `charlotteice`).
 * `facilityLabels` is optional facility ID → label mapping (passed to parser).
 */
export async function scrapeEvents(
  today: Date = new Date(),
  forwardDays: number = 5,
  company: string = DEFAULT_COMPANY,
  facilityLabels?: Record<number, string>
): Promise<Session[]> {
  // Step 1: Calculate target dates (all days in forward window)
  const targetDates = calculateTargetDates(today, forwardDays)

  if (targetDates.length === 0) {
    return []
  }

  // Step 2: Fetch date-availabilities to get event IDs
  const startDate = targetDates[0]
  const dateAvailabilitiesUrl = `${BASE_URL}/dash/jsonapi/api/v1/date-availabilities?cache[save]=false&page[size]=365&sort=id&filter[date__gte]=${startDate}&company=${company}`

  const dateAvailabilitiesResponse = await fetch(dateAvailabilitiesUrl)
  if (!dateAvailabilitiesResponse.ok) {
    throw new Error(
      `Failed to fetch date-availabilities: ${dateAvailabilitiesResponse.status} ${dateAvailabilitiesResponse.statusText}`
    )
  }

  const dateAvailabilitiesData =
    (await dateAvailabilitiesResponse.json()) as DateAvailabilitiesResponse

  // Step 3: Extract event IDs for target dates
  const eventIds = extractEventIds(dateAvailabilitiesData, targetDates)

  if (eventIds.length === 0) {
    return []
  }

  // Step 4: Fetch events by IDs
  const eventsUrl = `${BASE_URL}/dash/jsonapi/api/v1/events?cache[save]=false&filter[id__in]=${eventIds.join(',')}&filter[unconstrained]=1&company=${company}&include=summary,homeTeam,resource`

  const eventsResponse = await fetch(eventsUrl)
  if (!eventsResponse.ok) {
    throw new Error(`Failed to fetch events: ${eventsResponse.status} ${eventsResponse.statusText}`)
  }

  // eslint-disable-next-line @typescript-eslint/no-unsafe-assignment
  const eventsData = await eventsResponse.json()

  // Step 5: Parse events into sessions
  return parseEvents(eventsData, facilityLabels)
}
