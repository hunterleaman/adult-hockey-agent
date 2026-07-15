import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { scrapeEvents, calculateTargetDates, extractEventIds } from '../src/scraper'
import type { Session } from '../src/parser'

// Mock fetch globally
global.fetch = vi.fn()

describe('scraper', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  describe('calculateTargetDates', () => {
    it('returns every date in the forward window, all days of week', () => {
      const monday = new Date('2026-07-13T12:00:00Z')
      const dates = calculateTargetDates(monday, 5)
      expect(dates).toEqual([
        '2026-07-13',
        '2026-07-14',
        '2026-07-15',
        '2026-07-16',
        '2026-07-17',
        '2026-07-18',
      ])
    })

    it('includes all days when forward window spans a week', () => {
      const today = new Date('2026-02-15T12:00:00Z') // Sunday
      const forwardDays = 7

      const dates = calculateTargetDates(today, forwardDays)

      // Should include: Feb 15 (Sun) through Feb 22 (Sun), all 8 days
      expect(dates).toEqual([
        '2026-02-15',
        '2026-02-16',
        '2026-02-17',
        '2026-02-18',
        '2026-02-19',
        '2026-02-20',
        '2026-02-21',
        '2026-02-22',
      ])
    })

    it('includes today regardless of day of week', () => {
      const today = new Date('2026-02-14T12:00:00Z') // Saturday
      const forwardDays = 1

      const dates = calculateTargetDates(today, forwardDays)

      expect(dates[0]).toBe('2026-02-14')
      expect(dates).toEqual(['2026-02-14', '2026-02-15'])
    })

    it('returns correct count for forward window', () => {
      const today = new Date('2026-02-16T12:00:00Z') // Monday
      const forwardDays = 5

      const dates = calculateTargetDates(today, forwardDays)

      // Should return forwardDays + 1 dates (today inclusive)
      expect(dates).toHaveLength(6)
    })

    it('returns dates in chronological order', () => {
      const today = new Date('2026-02-16T12:00:00Z') // Monday
      const forwardDays = 10

      const dates = calculateTargetDates(today, forwardDays)

      // Should be sorted
      for (let i = 1; i < dates.length; i++) {
        expect(dates[i] > dates[i - 1]).toBe(true)
      }
    })

    it('handles default forward window of 5 days', () => {
      const today = new Date('2026-02-16T12:00:00Z') // Monday

      const dates = calculateTargetDates(today)

      expect(dates.length).toBe(6)
      expect(dates[0]).toBe('2026-02-16')
    })
  })

  describe('extractEventIds', () => {
    it('extracts event IDs for target dates from date-availabilities response', () => {
      const response = {
        data: [
          {
            id: '2026-02-16',
            attributes: { events: [101, 102, 103] },
          },
          {
            id: '2026-02-17',
            attributes: { events: [201, 202] },
          },
          {
            id: '2026-02-18',
            attributes: { events: [301, 302] },
          },
        ],
      }

      const targetDates = ['2026-02-16', '2026-02-18']
      const eventIds = extractEventIds(response, targetDates)

      expect(eventIds).toEqual([101, 102, 103, 301, 302])
    })

    it('returns empty array when no dates match', () => {
      const response = {
        data: [
          {
            id: '2026-02-17',
            attributes: { events: [201, 202] },
          },
        ],
      }

      const targetDates = ['2026-02-16', '2026-02-18']
      const eventIds = extractEventIds(response, targetDates)

      expect(eventIds).toEqual([])
    })

    it('handles dates with no events', () => {
      const response = {
        data: [
          {
            id: '2026-02-16',
            attributes: { events: [] },
          },
          {
            id: '2026-02-18',
            attributes: { events: [301, 302] },
          },
        ],
      }

      const targetDates = ['2026-02-16', '2026-02-18']
      const eventIds = extractEventIds(response, targetDates)

      expect(eventIds).toEqual([301, 302])
    })

    it('deduplicates event IDs', () => {
      const response = {
        data: [
          {
            id: '2026-02-16',
            attributes: { events: [101, 102, 101] },
          },
        ],
      }

      const targetDates = ['2026-02-16']
      const eventIds = extractEventIds(response, targetDates)

      expect(eventIds).toEqual([101, 102])
    })
  })

  describe('scrapeEvents', () => {
    it('fetches date-availabilities then events in sequence', async () => {
      const dateAvailabilitiesResponse = {
        data: [
          {
            id: '2026-02-20',
            attributes: { events: [213364, 213376] },
          },
        ],
      }

      const eventsResponse = {
        data: [
          {
            id: '213364',
            type: 'events',
            attributes: {
              start: '2026-02-20T06:00:00',
              end: '2026-02-20T07:10:00',
            },
            relationships: {
              homeTeam: { data: { type: 'teams', id: '5421' } },
              summary: { data: { type: 'event-summaries', id: '213364' } },
            },
          },
          {
            id: '213376',
            type: 'events',
            attributes: {
              start: '2026-02-20T06:00:00',
              end: '2026-02-20T07:10:00',
            },
            relationships: {
              homeTeam: { data: { type: 'teams', id: '5422' } },
              summary: { data: { type: 'event-summaries', id: '213376' } },
            },
          },
        ],
        included: [
          {
            id: '5421',
            type: 'teams',
            attributes: { name: '(PLAYERS) ADULT Pick Up MORNINGS' },
          },
          {
            id: '5422',
            type: 'teams',
            attributes: { name: '(GOALIES) Adult Pick Up MORNINGS' },
          },
          {
            id: '213364',
            type: 'event-summaries',
            attributes: {
              registered_count: 14,
              composite_capacity: 24,
              registration_status: 'open',
              remaining_registration_slots: 10,
            },
          },
          {
            id: '213376',
            type: 'event-summaries',
            attributes: {
              registered_count: 2,
              composite_capacity: 3,
              registration_status: 'open',
              remaining_registration_slots: 1,
            },
          },
        ],
      }

      ;(global.fetch as any)
        .mockResolvedValueOnce({
          ok: true,
          json: async () => dateAvailabilitiesResponse,
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => eventsResponse,
        })

      const today = new Date('2026-02-20T12:00:00Z')
      const sessions = await scrapeEvents(today, 5)

      expect(global.fetch).toHaveBeenCalledTimes(2)
      expect(sessions).toHaveLength(1)
      expect(sessions[0].date).toBe('2026-02-20')
    })

    it('returns empty array when no event IDs found', async () => {
      const dateAvailabilitiesResponse = {
        data: [
          {
            id: '2026-02-20',
            attributes: { events: [] },
          },
        ],
      }

      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        json: async () => dateAvailabilitiesResponse,
      })

      const today = new Date('2026-02-20T12:00:00Z')
      const sessions = await scrapeEvents(today, 5)

      expect(global.fetch).toHaveBeenCalledTimes(1) // Only date-availabilities
      expect(sessions).toEqual([])
    })

    it('throws error when date-availabilities request fails', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: false,
        status: 500,
        statusText: 'Internal Server Error',
      })

      const today = new Date('2026-02-20T12:00:00Z')

      await expect(scrapeEvents(today, 5)).rejects.toThrow(
        'Failed to fetch date-availabilities: 500 Internal Server Error'
      )
    })

    it('throws error when events request fails', async () => {
      const dateAvailabilitiesResponse = {
        data: [
          {
            id: '2026-02-20',
            attributes: { events: [213364] },
          },
        ],
      }

      ;(global.fetch as any)
        .mockResolvedValueOnce({
          ok: true,
          json: async () => dateAvailabilitiesResponse,
        })
        .mockResolvedValueOnce({
          ok: false,
          status: 404,
          statusText: 'Not Found',
        })

      const today = new Date('2026-02-20T12:00:00Z')

      await expect(scrapeEvents(today, 5)).rejects.toThrow('Failed to fetch events: 404 Not Found')
    })

    it('builds correct date-availabilities URL', async () => {
      const dateAvailabilitiesResponse = {
        data: [],
      }

      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        json: async () => dateAvailabilitiesResponse,
      })

      const today = new Date('2026-02-20T12:00:00Z')
      await scrapeEvents(today, 5)

      const call = (global.fetch as any).mock.calls[0]
      const url = call[0]

      expect(url).toContain('/dash/jsonapi/api/v1/date-availabilities')
      expect(url).toContain('cache[save]=false')
      expect(url).toContain('page[size]=365')
      expect(url).toContain('sort=id')
      expect(url).toContain('filter[date__gte]=2026-02-20')
      expect(url).toContain('company=charlotteice')
    })

    it('builds correct events URL with event IDs', async () => {
      const dateAvailabilitiesResponse = {
        data: [
          {
            id: '2026-02-20',
            attributes: { events: [213364, 213376] },
          },
        ],
      }

      const eventsResponse = { data: [], included: [] }

      ;(global.fetch as any)
        .mockResolvedValueOnce({
          ok: true,
          json: async () => dateAvailabilitiesResponse,
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => eventsResponse,
        })

      const today = new Date('2026-02-20T12:00:00Z')
      await scrapeEvents(today, 5)

      const call = (global.fetch as any).mock.calls[1]
      const url = call[0]

      expect(url).toContain('/dash/jsonapi/api/v1/events')
      expect(url).toContain('cache[save]=false')
      expect(url).toContain('filter[id__in]=213364,213376')
      expect(url).toContain('filter[unconstrained]=1')
      expect(url).toContain('company=charlotteice')
      expect(url).toContain('include=summary,homeTeam,resource')
    })

    it('handles network timeout gracefully', async () => {
      ;(global.fetch as any).mockRejectedValueOnce(new Error('Network timeout'))

      const today = new Date('2026-02-20T12:00:00Z')

      await expect(scrapeEvents(today, 5)).rejects.toThrow('Network timeout')
    })

    it('handles malformed JSON response', async () => {
      ;(global.fetch as any).mockResolvedValueOnce({
        ok: true,
        json: async () => {
          throw new Error('Unexpected token')
        },
      })

      const today = new Date('2026-02-20T12:00:00Z')

      await expect(scrapeEvents(today, 5)).rejects.toThrow()
    })

    it('passes events response to parser and returns sessions', async () => {
      const dateAvailabilitiesResponse = {
        data: [
          {
            id: '2026-02-20',
            attributes: { events: [213364, 213376] },
          },
        ],
      }

      // Realistic events response from Session 1 fixture
      const eventsResponse = {
        data: [
          {
            id: '213364',
            type: 'events',
            attributes: {
              start: '2026-02-20T06:00:00',
              end: '2026-02-20T07:10:00',
            },
            relationships: {
              homeTeam: { data: { type: 'teams', id: '5421' } },
              summary: { data: { type: 'event-summaries', id: '213364' } },
            },
          },
          {
            id: '213376',
            type: 'events',
            attributes: {
              start: '2026-02-20T06:00:00',
              end: '2026-02-20T07:10:00',
            },
            relationships: {
              homeTeam: { data: { type: 'teams', id: '5422' } },
              summary: { data: { type: 'event-summaries', id: '213376' } },
            },
          },
        ],
        included: [
          {
            id: '5421',
            type: 'teams',
            attributes: { name: '(PLAYERS) ADULT Pick Up MORNINGS' },
          },
          {
            id: '5422',
            type: 'teams',
            attributes: { name: '(GOALIES) Adult Pick Up MORNINGS' },
          },
          {
            id: '213364',
            type: 'event-summaries',
            attributes: {
              registered_count: 14,
              composite_capacity: 24,
              registration_status: 'open',
              remaining_registration_slots: 10,
            },
          },
          {
            id: '213376',
            type: 'event-summaries',
            attributes: {
              registered_count: 2,
              composite_capacity: 3,
              registration_status: 'open',
              remaining_registration_slots: 1,
            },
          },
        ],
      }

      ;(global.fetch as any)
        .mockResolvedValueOnce({
          ok: true,
          json: async () => dateAvailabilitiesResponse,
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => eventsResponse,
        })

      const today = new Date('2026-02-20T12:00:00Z')
      const sessions = await scrapeEvents(today, 5)

      // Should get paired session (PLAYERS + GOALIES combined)
      expect(sessions).toHaveLength(1)
      expect(sessions[0].date).toBe('2026-02-20')
      expect(sessions[0].time).toBe('06:00')
      expect(sessions[0].playersRegistered).toBe(14)
      expect(sessions[0].goaliesRegistered).toBe(2)
    })
  })
})
