import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import type { Express } from 'express'
import type { Server } from 'http'
import fs from 'fs'
import path from 'path'

// Import the server factory function
import { createServer } from '../src/server.js'

describe('Health Endpoint', () => {
  let app: Express
  let server: Server
  const TEST_STATE_PATH = './data/test-state.json'
  const TEST_PORT = 3999 // Use a different port to avoid conflicts

  beforeEach(() => {
    // Clean up test state file before each test
    if (fs.existsSync(TEST_STATE_PATH)) {
      fs.unlinkSync(TEST_STATE_PATH)
    }
  })

  afterEach(
    () =>
      new Promise<void>((resolve) => {
        // Clean up test state file after each test
        if (fs.existsSync(TEST_STATE_PATH)) {
          fs.unlinkSync(TEST_STATE_PATH)
        }

        // Stop server if it's running
        if (server) {
          server.close(() => resolve())
        } else {
          resolve()
        }
      })
  )

  async function startTestServer(): Promise<void> {
    app = createServer({ statePath: TEST_STATE_PATH })
    return new Promise((resolve) => {
      server = app.listen(TEST_PORT, () => {
        resolve()
      })
    })
  }

  it('should return 200 status code', async () => {
    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)

    expect(response.status).toBe(200)
  })

  it('should return JSON with required fields', async () => {
    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)
    const data = await response.json()

    expect(data).toHaveProperty('status')
    expect(data).toHaveProperty('uptime')
    expect(data).toHaveProperty('lastPoll')
  })

  it('should return status=ok', async () => {
    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)
    const data = await response.json()

    expect(data.status).toBe('ok')
  })

  it('should return uptime as a number', async () => {
    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)
    const data = await response.json()

    expect(typeof data.uptime).toBe('number')
    expect(data.uptime).toBeGreaterThanOrEqual(0)
  })

  it('should return lastPoll=null when state file does not exist', async () => {
    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)
    const data = await response.json()

    expect(data.lastPoll).toBeNull()
  })

  it('should return lastPoll as ISO timestamp when state exists with sessions', async () => {
    // Create state directory if it doesn't exist
    const stateDir = path.dirname(TEST_STATE_PATH)
    if (!fs.existsSync(stateDir)) {
      fs.mkdirSync(stateDir, { recursive: true })
    }

    // Create a state file with a session
    const testTimestamp = '2026-02-17T12:00:00.000Z'
    const testState = [
      {
        session: {
          date: '2026-02-17',
          time: '11:45 AM',
          playersRegistered: 15,
          playersMax: 24,
          goaliesRegistered: 2,
          goaliesMax: 2,
          isFull: false,
          registrationUrl: 'https://example.com',
        },
        lastAlertType: 'OPPORTUNITY',
        lastAlertAt: testTimestamp,
        lastPlayerCount: 15,
        isRegistered: false,
      },
    ]

    fs.writeFileSync(TEST_STATE_PATH, JSON.stringify(testState, null, 2))

    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)
    const data = await response.json()

    // lastPoll should be the file modification time (recent, not the exact testTimestamp)
    expect(data.lastPoll).toBeTruthy()
    expect(typeof data.lastPoll).toBe('string')
    // Verify it's a valid ISO timestamp
    expect(new Date(data.lastPoll).toISOString()).toBe(data.lastPoll)
  })

  it('should return file modification time as lastPoll', async () => {
    // Create state directory if it doesn't exist
    const stateDir = path.dirname(TEST_STATE_PATH)
    if (!fs.existsSync(stateDir)) {
      fs.mkdirSync(stateDir, { recursive: true })
    }

    // Create a state file with multiple sessions
    const olderTimestamp = '2026-02-17T10:00:00.000Z'
    const newerTimestamp = '2026-02-17T12:00:00.000Z'

    const testState = [
      {
        session: {
          date: '2026-02-17',
          time: '11:45 AM',
          playersRegistered: 15,
          playersMax: 24,
          goaliesRegistered: 2,
          goaliesMax: 2,
          isFull: false,
          registrationUrl: 'https://example.com',
        },
        lastAlertType: 'OPPORTUNITY',
        lastAlertAt: olderTimestamp,
        lastPlayerCount: 15,
        isRegistered: false,
      },
      {
        session: {
          date: '2026-02-19',
          time: '11:45 AM',
          playersRegistered: 18,
          playersMax: 24,
          goaliesRegistered: 2,
          goaliesMax: 2,
          isFull: false,
          registrationUrl: 'https://example.com',
        },
        lastAlertType: 'FILLING_FAST',
        lastAlertAt: newerTimestamp,
        lastPlayerCount: 18,
        isRegistered: false,
      },
    ]

    // Record time before writing file
    const beforeWrite = new Date()

    fs.writeFileSync(TEST_STATE_PATH, JSON.stringify(testState, null, 2))

    // Record time after writing file
    const afterWrite = new Date()

    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)
    const data = await response.json()

    // lastPoll should be the file modification time (between beforeWrite and afterWrite)
    expect(data.lastPoll).toBeTruthy()
    const lastPollDate = new Date(data.lastPoll)
    expect(lastPollDate.getTime()).toBeGreaterThanOrEqual(beforeWrite.getTime())
    expect(lastPollDate.getTime()).toBeLessThanOrEqual(afterWrite.getTime() + 1000) // +1s tolerance
  })

  it('should handle empty state array', async () => {
    // Create state directory if it doesn't exist
    const stateDir = path.dirname(TEST_STATE_PATH)
    if (!fs.existsSync(stateDir)) {
      fs.mkdirSync(stateDir, { recursive: true })
    }

    // Create an empty state file
    const beforeWrite = new Date()
    fs.writeFileSync(TEST_STATE_PATH, '[]')
    const afterWrite = new Date()

    await startTestServer()

    const response = await fetch(`http://localhost:${TEST_PORT}/health`)
    const data = await response.json()

    // Even with empty state array, the file exists and has a modification time
    // This represents when the last poll happened (created the empty state file)
    expect(data.lastPoll).toBeTruthy()
    const lastPollDate = new Date(data.lastPoll)
    expect(lastPollDate.getTime()).toBeGreaterThanOrEqual(beforeWrite.getTime())
    expect(lastPollDate.getTime()).toBeLessThanOrEqual(afterWrite.getTime() + 1000)
  })
})
