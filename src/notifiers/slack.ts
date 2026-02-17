import type { Notifier } from './interface'
import type { Alert, AlertType } from '../evaluator'

interface SlackBlock {
  type: string
  text?: {
    type: string
    text: string
    emoji?: boolean
  }
  elements?: Array<{
    type: string
    text?: {
      type: string
      text: string
    }
    url?: string
    style?: string
  }>
}

interface SlackPayload {
  blocks: SlackBlock[]
}

/**
 * Slack notifier - sends alerts to Slack via webhook.
 * Requires SLACK_WEBHOOK_URL environment variable.
 */
export class SlackNotifier implements Notifier {
  name = 'Slack'

  constructor(private webhookUrl: string) {}

  static fromEnv(): SlackNotifier {
    return new SlackNotifier(process.env.SLACK_WEBHOOK_URL || '')
  }

  isConfigured(): boolean {
    return !!this.webhookUrl && this.webhookUrl.length > 0
  }

  async send(alert: Alert): Promise<void> {
    if (!this.isConfigured()) {
      throw new Error('Slack notifier not configured')
    }

    const payload = this.buildPayload(alert)

    const response = await fetch(this.webhookUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    })

    if (!response.ok) {
      throw new Error(`Slack webhook failed: ${response.status} ${response.statusText}`)
    }
  }

  private buildPayload(alert: Alert): SlackPayload {
    const emoji = this.getEmoji(alert.type)

    const blocks: SlackBlock[] = [
      {
        type: 'header',
        text: {
          type: 'plain_text',
          text: `${emoji} ${alert.type.replace('_', ' ')}`,
          emoji: true,
        },
      },
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: this.formatMessage(alert),
        },
      },
    ]

    // Only include action button for alerts where registration is possible
    if (alert.type !== 'SOLD_OUT') {
      blocks.push({
        type: 'actions',
        elements: [
          {
            type: 'button',
            text: {
              type: 'plain_text',
              text: 'Register Now',
            },
            url: alert.registrationUrl,
            style: this.getButtonStyle(alert.type),
          },
        ],
      })
    }

    return { blocks }
  }

  private getEmoji(type: AlertType): string {
    const emojiMap: Record<AlertType, string> = {
      OPPORTUNITY: '🏒',
      FILLING_FAST: '⚡',
      SOLD_OUT: '🚫',
      NEWLY_AVAILABLE: '✅',
    }
    return emojiMap[type]
  }

  private getColor(type: AlertType): string {
    const colorMap: Record<AlertType, string> = {
      OPPORTUNITY: '#36a64f', // green
      FILLING_FAST: '#ff9900', // orange
      SOLD_OUT: '#ff0000', // red
      NEWLY_AVAILABLE: '#2eb886', // teal
    }
    return colorMap[type]
  }

  private getButtonStyle(type: AlertType): string | undefined {
    if (type === 'FILLING_FAST') {
      return 'danger' // red button for urgency
    }
    if (type === 'OPPORTUNITY' || type === 'NEWLY_AVAILABLE') {
      return 'primary' // green button
    }
    return undefined // omit style field for default styling
  }

  private formatMessage(alert: Alert): string {
    const session = alert.session
    const spotsRemaining = session.playersMax - session.playersRegistered

    let message = `*${session.dayOfWeek}, ${this.formatDate(session.date)}* at *${this.formatTime(session.time)}*\n\n`

    if (alert.type === 'SOLD_OUT') {
      message += 'Session is now full.'
    } else if (alert.type === 'NEWLY_AVAILABLE') {
      message += `Spots opened up! *${spotsRemaining}* spot${spotsRemaining === 1 ? '' : 's'} available.`
    } else {
      message += `*Players:* ${session.playersRegistered}/${session.playersMax} (${spotsRemaining} spot${spotsRemaining === 1 ? '' : 's'} left)\n`
      message += `*Goalies:* ${session.goaliesRegistered}/${session.goaliesMax}\n`

      if (alert.type === 'OPPORTUNITY') {
        message += '\n_Worth signing up!_'
      } else if (alert.type === 'FILLING_FAST') {
        message += '\n_Act now!_'
      }
    }

    return message
  }

  private formatDate(date: string): string {
    const d = new Date(date + 'T00:00:00')
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
  }

  private formatTime(time: string): string {
    const [hours, minutes] = time.split(':').map(Number)
    const period = hours >= 12 ? 'pm' : 'am'
    const displayHours = hours % 12 || 12
    return `${displayHours}:${minutes.toString().padStart(2, '0')}${period}`
  }
}
