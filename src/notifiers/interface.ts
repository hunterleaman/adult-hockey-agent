import type { Alert } from '../evaluator'

/**
 * Common interface for all notification modules
 */
export interface Notifier {
  name: string
  send(alert: Alert): Promise<void>
  isConfigured(): boolean
}
