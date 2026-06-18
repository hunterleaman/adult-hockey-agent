import type { Alert } from '../evaluator'

/**
 * Common interface for all notification modules
 */
export interface Notifier {
  name: string
  send(alert: Alert): Promise<void>
  /**
   * Send a plain diagnostic/health message not tied to a session (e.g. the
   * canary warning when the agent stops seeing usable pickup data).
   */
  sendDiagnostic(text: string): Promise<void>
  isConfigured(): boolean
}
