import { describe, it, expect } from 'vitest'
import { readFile } from 'fs/promises'
import fs from 'fs'
import { join } from 'path'
import { parseEvents, type Session } from '../src/parser.js'

describe('Parser', () => {
  it('should parse Friday fixture with ADULT Pick Up sessions', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    // Should extract multiple ADULT Pick Up sessions (not Broomball)
    expect(sessions.length).toBeGreaterThan(0)

    // All sessions should be from Friday 2026-02-13
    sessions.forEach((session) => {
      expect(session.date).toBe('2026-02-13')
      expect(session.dayOfWeek).toBe('Friday')
    })
  })

  it('should match Session interface structure', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)
    const firstSession = sessions[0]

    // Verify all required fields exist
    expect(firstSession).toHaveProperty('date')
    expect(firstSession).toHaveProperty('dayOfWeek')
    expect(firstSession).toHaveProperty('time')
    expect(firstSession).toHaveProperty('timeLabel')
    expect(firstSession).toHaveProperty('eventName')
    expect(firstSession).toHaveProperty('playersRegistered')
    expect(firstSession).toHaveProperty('playersMax')
    expect(firstSession).toHaveProperty('goaliesRegistered')
    expect(firstSession).toHaveProperty('goaliesMax')
    expect(firstSession).toHaveProperty('isFull')
    expect(firstSession).toHaveProperty('price')

    // Verify types
    expect(typeof firstSession.date).toBe('string')
    expect(typeof firstSession.dayOfWeek).toBe('string')
    expect(typeof firstSession.time).toBe('string')
    expect(typeof firstSession.timeLabel).toBe('string')
    expect(typeof firstSession.eventName).toBe('string')
    expect(typeof firstSession.playersRegistered).toBe('number')
    expect(typeof firstSession.playersMax).toBe('number')
    expect(typeof firstSession.goaliesRegistered).toBe('number')
    expect(typeof firstSession.goaliesMax).toBe('number')
    expect(typeof firstSession.isFull).toBe('boolean')
    expect(typeof firstSession.price).toBe('number')
  })

  it('should correctly parse morning session registration counts', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    // Find the 6:00am morning session
    const morningSession = sessions.find((s) => s.time === '06:00')

    expect(morningSession).toBeDefined()
    expect(morningSession!.playersRegistered).toBe(24)
    expect(morningSession!.playersMax).toBe(24)
    expect(morningSession!.goaliesRegistered).toBe(3)
    // Goalies max might be 3 based on the data (full status)
    expect(morningSession!.goaliesMax).toBeGreaterThanOrEqual(3)
  })

  it('should pair PLAYERS and GOALIES entries by time slot', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    // Each session should have both player and goalie data
    sessions.forEach((session) => {
      expect(session.playersRegistered).toBeGreaterThanOrEqual(0)
      expect(session.playersMax).toBeGreaterThan(0)
      expect(session.goaliesRegistered).toBeGreaterThanOrEqual(0)
      expect(session.goaliesMax).toBeGreaterThan(0)
    })
  })

  it('should filter out Broomball events', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    // No session should mention Broomball
    sessions.forEach((session) => {
      expect(session.eventName.toLowerCase()).not.toContain('broomball')
    })
  })

  it('should correctly derive isFull status', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    sessions.forEach((session) => {
      const expectedFull = session.playersRegistered >= session.playersMax
      expect(session.isFull).toBe(expectedFull)
    })
  })

  it('should format time as HH:MM in 24-hour format', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    sessions.forEach((session) => {
      // Should match HH:MM pattern
      expect(session.time).toMatch(/^\d{2}:\d{2}$/)
    })
  })

  it('should generate timeLabel with am/pm format', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    sessions.forEach((session) => {
      // Should contain am or pm
      expect(session.timeLabel.toLowerCase()).toMatch(/(am|pm)/)
      // Should be a time range with hyphen
      expect(session.timeLabel).toContain('-')
    })
  })

  it('should handle sessions with different time slots', async () => {
    const fixturePath = join(process.cwd(), 'fixtures', 'friday-with-data.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    const apiResponse = JSON.parse(fixtureData)

    const sessions = parseEvents(apiResponse)

    // Should have multiple unique time slots
    const uniqueTimes = new Set(sessions.map((s) => s.time))
    expect(uniqueTimes.size).toBeGreaterThan(1)
  })
})

describe('Parser - renamed DASH teams (Adult Pickup Skater/Goalie)', () => {
  // In ~mid-2026 DASH renamed the pickup teams from "(PLAYERS) ADULT Pick Up"
  // to "Adult Pickup Skater" / "Adult Pickup Goalie", which broke the old
  // "adult pick up" filter and "(PLAYERS)"/"(GOALIES)" classification.
  async function loadRenameFixture(): Promise<Session[]> {
    const fixturePath = join(process.cwd(), 'fixtures', 'dash-api', 'events-pickup-rename.json')
    const fixtureData = await readFile(fixturePath, 'utf-8')
    return parseEvents(JSON.parse(fixtureData))
  }

  it('should parse Adult Pickup sessions despite the team rename', async () => {
    const sessions = await loadRenameFixture()
    expect(sessions.length).toBe(1)
  })

  it('should pair Skater (players) with Goalie at the same time slot', async () => {
    const sessions = await loadRenameFixture()
    const session = sessions[0]

    expect(session.date).toBe('2026-06-08')
    expect(session.time).toBe('11:30')
    expect(session.playersMax).toBe(22)
    expect(session.playersRegistered).toBe(0)
    expect(session.goaliesMax).toBe(3)
    expect(session.goaliesRegistered).toBe(0)
  })

  it('should exclude non-pickup events (Private Hockey Lessons)', async () => {
    const sessions = await loadRenameFixture()
    sessions.forEach((session) => {
      expect(session.eventName.toLowerCase()).not.toContain('private')
      expect(session.eventName.toLowerCase()).not.toContain('lesson')
    })
  })
})

describe('facility awareness (XIC/PIH merger)', () => {
  const multiFacility = JSON.parse(
    fs.readFileSync('fixtures/dash-api/events-multi-facility.json', 'utf-8')
  )
  const collision = JSON.parse(
    fs.readFileSync('fixtures/dash-api/events-cross-rink-collision.json', 'utf-8')
  )

  it('extracts facilityId, location label, and rinkName from the resource relationship', () => {
    const sessions = parseEvents(multiFacility)

    expect(sessions).toHaveLength(3)

    const morning = sessions.find((s) => s.time === '06:10')!
    expect(morning.facilityId).toBe(1)
    expect(morning.location).toBe('XIC')
    expect(morning.rinkName).toBe('MAIN RINK')
    expect(morning.playersRegistered).toBe(12)
    expect(morning.playersMax).toBe(22)
    expect(morning.goaliesRegistered).toBe(1)
    expect(morning.goaliesMax).toBe(3)

    const pih = sessions.find((s) => s.time === '11:30')!
    expect(pih.facilityId).toBe(2)
    expect(pih.location).toBe('PIH')
    expect(pih.rinkName).toBe('Pineville Rink')
    expect(pih.playersRegistered).toBe(22)
    expect(pih.isFull).toBe(true)

    const noon = sessions.find((s) => s.time === '12:00')!
    expect(noon.facilityId).toBe(1)
    expect(noon.location).toBe('XIC')
    expect(noon.rinkName).toBe('TRAINING RINK')
  })

  it('does NOT merge same-time sessions at different rinks (collision regression)', () => {
    const sessions = parseEvents(collision)

    expect(sessions).toHaveLength(2)

    const xic = sessions.find((s) => s.facilityId === 1)!
    expect(xic.playersRegistered).toBe(9)
    expect(xic.goaliesRegistered).toBe(1)
    expect(xic.location).toBe('XIC')

    const pih = sessions.find((s) => s.facilityId === 2)!
    expect(pih.playersRegistered).toBe(15)
    expect(pih.goaliesRegistered).toBe(2)
    expect(pih.location).toBe('PIH')
  })

  it('falls back to rink name for unmapped facilities', () => {
    const sessions = parseEvents(collision, { 1: 'XIC' }) // no label for facility 2
    const pih = sessions.find((s) => s.facilityId === 2)!
    expect(pih.location).toBe('Pineville Rink')
  })

  it('keeps sessions with a missing resource relationship (facilityId 0)', () => {
    const noResource = JSON.parse(JSON.stringify(collision)) as typeof collision
    // strip resource relationships from the XIC pair only
    delete noResource.data[0].relationships.resource
    delete noResource.data[1].relationships.resource

    const sessions = parseEvents(noResource)
    expect(sessions).toHaveLength(2)
    const unknown = sessions.find((s) => s.facilityId === 0)!
    expect(unknown.location).toBe('Facility 0')
  })

  it('normalizes a string facility_id to a numeric facilityId', () => {
    const cloned = JSON.parse(JSON.stringify(collision)) as typeof collision
    const pihResource = cloned.included.find(
      (item: { type: string; id: string }) => item.type === 'resources' && item.id === '4'
    )
    pihResource.attributes.facility_id = '2'

    const sessions = parseEvents(cloned)
    const pih = sessions.find((s) => s.facilityId === 2)
    expect(pih).toBeDefined()
    expect(pih!.facilityId).toBe(2)
    expect(pih!.location).toBe('PIH')
  })

  it('normalizes a null facility_id to 0 (unresolvable)', () => {
    const cloned = JSON.parse(JSON.stringify(collision)) as typeof collision
    const xicResource = cloned.included.find(
      (item: { type: string; id: string }) => item.type === 'resources' && item.id === '1'
    )
    xicResource.attributes.facility_id = null
    // No rink name to fall back on either, so location degrades all the way
    // to the generic "Facility 0" label (matches the missing-resource case).
    xicResource.attributes.name = null

    const sessions = parseEvents(cloned)
    const unresolved = sessions.find((s) => s.facilityId === 0)
    expect(unresolved).toBeDefined()
    expect(unresolved!.facilityId).toBe(0)
    expect(unresolved!.location).toBe('Facility 0')
  })
})
