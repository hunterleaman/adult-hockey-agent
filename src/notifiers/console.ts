import type { Notifier } from './interface'
import type { Alert } from '../evaluator'

/**
 * Console notifier - logs alerts to stdout.
 * Always active, useful for testing and debugging.
 */
export class ConsoleNotifier implements Notifier {
  name = 'Console'

  isConfigured(): boolean {
    return true // Always available
  }

  async send(alert: Alert): Promise<void> {
    try {
      const separator = '='.repeat(60)
      console.log(separator)
      console.log(alert.message)
      console.log(`\nRegister: ${alert.registrationUrl}`)
      console.log(separator)
    } catch {
      // Silently ignore console errors (e.g., stdout closed)
      // Don't throw - console notifier should never block
    }
  }
}
