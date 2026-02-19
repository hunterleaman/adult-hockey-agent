import type { ActionResult } from './actions.js'

/**
 * Build ephemeral confirmation text for a Slack interaction response.
 */
export function buildConfirmationText(result: ActionResult, remindIntervalHours: number): string {
  const dateStr = formatSessionDate(result.date)
  const timeStr = formatSessionTime(result.time)

  switch (result.userResponse) {
    case 'registered':
      return `✅ Marked as registered for ${dateStr} at ${timeStr}. You won't receive further alerts for this session.`
    case 'not_interested':
      return `❌ Dismissed ${dateStr} at ${timeStr}. You won't receive further alerts for this session.`
    case 'remind_later':
      return `⏰ Snoozed ${dateStr} at ${timeStr}. I'll remind you again in ${remindIntervalHours} hours.`
  }
}

/**
 * POST an ephemeral confirmation to Slack's response_url.
 * Best-effort delivery — errors are silently ignored since the user
 * already received visual feedback when we responded 200.
 */
export async function sendConfirmation(responseUrl: string, text: string): Promise<void> {
  const response = await fetch(responseUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      response_type: 'ephemeral',
      replace_original: false,
      text,
    }),
  })

  if (!response.ok) {
    throw new Error(`Confirmation POST failed: ${response.status}`)
  }
}

function formatSessionDate(date: string): string {
  const d = new Date(date + 'T00:00:00')
  const dayOfWeek = d.toLocaleDateString('en-US', { weekday: 'long' })
  const month = d.getMonth() + 1
  const day = d.getDate()
  return `${dayOfWeek} ${month}/${day}`
}

function formatSessionTime(time: string): string {
  const [hours, minutes] = time.split(':').map(Number)
  const period = hours >= 12 ? 'pm' : 'am'
  const displayHours = hours % 12 || 12
  return `${displayHours}:${minutes.toString().padStart(2, '0')}${period}`
}
