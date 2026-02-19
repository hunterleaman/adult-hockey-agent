import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { buildConfirmationText, sendConfirmation } from '../../src/interactions/confirm'
import type { ActionResult } from '../../src/interactions/actions'

describe('buildConfirmationText', () => {
  const baseResult: Omit<ActionResult, 'userResponse'> = {
    date: '2026-02-20',
    time: '06:00',
    eventName: '(PLAYERS) ADULT Pick Up MORNINGS',
    found: true,
    responseUrl: 'https://hooks.slack.com/actions/test',
  }

  it('returns registered confirmation text', () => {
    const result: ActionResult = { ...baseResult, userResponse: 'registered' }
    const text = buildConfirmationText(result, 2)

    expect(text).toContain('✅')
    expect(text).toContain('registered')
    expect(text).toContain('Friday 2/20')
    expect(text).toContain('6:00am')
    expect(text).toContain("won't receive further alerts")
  })

  it('returns not_interested confirmation text', () => {
    const result: ActionResult = { ...baseResult, userResponse: 'not_interested' }
    const text = buildConfirmationText(result, 2)

    expect(text).toContain('❌')
    expect(text).toContain('Dismissed')
    expect(text).toContain('Friday 2/20')
    expect(text).toContain('6:00am')
    expect(text).toContain("won't receive further alerts")
  })

  it('returns remind_later confirmation text with interval', () => {
    const result: ActionResult = { ...baseResult, userResponse: 'remind_later' }
    const text = buildConfirmationText(result, 2)

    expect(text).toContain('⏰')
    expect(text).toContain('Snoozed')
    expect(text).toContain('Friday 2/20')
    expect(text).toContain('6:00am')
    expect(text).toContain('2 hours')
  })

  it('uses configurable remind interval in text', () => {
    const result: ActionResult = { ...baseResult, userResponse: 'remind_later' }
    const text = buildConfirmationText(result, 4)

    expect(text).toContain('4 hours')
  })

  it('formats afternoon times correctly', () => {
    const result: ActionResult = { ...baseResult, time: '18:30', userResponse: 'registered' }
    const text = buildConfirmationText(result, 2)

    expect(text).toContain('6:30pm')
  })

  it('formats noon correctly', () => {
    const result: ActionResult = { ...baseResult, time: '12:00', userResponse: 'registered' }
    const text = buildConfirmationText(result, 2)

    expect(text).toContain('12:00pm')
  })
})

describe('sendConfirmation', () => {
  const originalFetch = global.fetch

  beforeEach(() => {
    global.fetch = vi.fn()
  })

  afterEach(() => {
    global.fetch = originalFetch
  })

  it('POSTs ephemeral message to response_url', async () => {
    ;(global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce({ ok: true })

    await sendConfirmation('https://hooks.slack.com/actions/test', 'Test message')

    expect(global.fetch).toHaveBeenCalledWith('https://hooks.slack.com/actions/test', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        response_type: 'ephemeral',
        replace_original: false,
        text: 'Test message',
      }),
    })
  })

  it('throws on non-ok response', async () => {
    ;(global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: false,
      status: 500,
    })

    await expect(sendConfirmation('https://hooks.slack.com/actions/test', 'msg')).rejects.toThrow(
      'Confirmation POST failed: 500'
    )
  })

  it('propagates network errors', async () => {
    ;(global.fetch as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('Network error'))

    await expect(sendConfirmation('https://hooks.slack.com/actions/test', 'msg')).rejects.toThrow(
      'Network error'
    )
  })
})
