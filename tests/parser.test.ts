import { describe, it, expect } from 'vitest'
import { readFile } from 'fs/promises'
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
