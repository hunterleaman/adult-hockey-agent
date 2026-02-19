import { describe, it, expect, vi, afterEach } from 'vitest'
import crypto from 'crypto'
import { verifySlackSignature } from '../../src/interactions/verify'

const SIGNING_SECRET = 'test-signing-secret-12345'

function makeSignature(secret: string, timestamp: string, body: string): string {
  const sigBasestring = `v0:${timestamp}:${body}`
  return 'v0=' + crypto.createHmac('sha256', secret).update(sigBasestring).digest('hex')
}

function currentTimestamp(): string {
  return Math.floor(Date.now() / 1000).toString()
}

describe('verifySlackSignature', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('accepts a valid signature with current timestamp', () => {
    const ts = currentTimestamp()
    const body = 'payload=%7B%22test%22%3Atrue%7D'
    const sig = makeSignature(SIGNING_SECRET, ts, body)

    expect(verifySlackSignature(SIGNING_SECRET, sig, ts, body)).toBe(true)
  })

  it('rejects an invalid signature', () => {
    const ts = currentTimestamp()
    const body = 'payload=%7B%22test%22%3Atrue%7D'

    expect(verifySlackSignature(SIGNING_SECRET, 'v0=invalid', ts, body)).toBe(false)
  })

  it('rejects a signature from a different secret', () => {
    const ts = currentTimestamp()
    const body = 'payload=%7B%22test%22%3Atrue%7D'
    const sig = makeSignature('wrong-secret', ts, body)

    expect(verifySlackSignature(SIGNING_SECRET, sig, ts, body)).toBe(false)
  })

  it('rejects requests older than 5 minutes', () => {
    const sixMinutesAgo = (Math.floor(Date.now() / 1000) - 360).toString()
    const body = 'payload=%7B%22test%22%3Atrue%7D'
    const sig = makeSignature(SIGNING_SECRET, sixMinutesAgo, body)

    expect(verifySlackSignature(SIGNING_SECRET, sig, sixMinutesAgo, body)).toBe(false)
  })

  it('accepts requests exactly at the 5-minute boundary', () => {
    const fiveMinutesAgo = (Math.floor(Date.now() / 1000) - 300).toString()
    const body = 'payload=%7B%22test%22%3Atrue%7D'
    const sig = makeSignature(SIGNING_SECRET, fiveMinutesAgo, body)

    // Exactly 5 minutes ago: timestamp === fiveMinutesAgo, check is < not <=
    expect(verifySlackSignature(SIGNING_SECRET, sig, fiveMinutesAgo, body)).toBe(true)
  })

  it('rejects when body has been tampered with', () => {
    const ts = currentTimestamp()
    const originalBody = 'payload=%7B%22test%22%3Atrue%7D'
    const sig = makeSignature(SIGNING_SECRET, ts, originalBody)
    const tamperedBody = 'payload=%7B%22test%22%3Afalse%7D'

    expect(verifySlackSignature(SIGNING_SECRET, sig, ts, tamperedBody)).toBe(false)
  })
})
