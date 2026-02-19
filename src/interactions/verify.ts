import crypto from 'crypto'

/**
 * Verify Slack request signature using HMAC-SHA256.
 * Rejects requests older than 5 minutes (replay attack prevention).
 */
export function verifySlackSignature(
  signingSecret: string,
  signature: string,
  timestamp: string,
  body: string
): boolean {
  // Reject requests older than 5 minutes
  const fiveMinutesAgo = Math.floor(Date.now() / 1000) - 60 * 5
  if (parseInt(timestamp, 10) < fiveMinutesAgo) return false

  const sigBasestring = `v0:${timestamp}:${body}`
  const mySignature =
    'v0=' + crypto.createHmac('sha256', signingSecret).update(sigBasestring).digest('hex')

  const expected = Buffer.from(mySignature)
  const received = Buffer.from(signature)

  if (expected.length !== received.length) return false

  return crypto.timingSafeEqual(expected, received)
}
