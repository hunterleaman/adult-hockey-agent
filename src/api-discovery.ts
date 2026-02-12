import { chromium } from 'playwright'
import { writeFile } from 'fs/promises'
import { join } from 'path'

interface NetworkCapture {
  url: string
  method: string
  status: number
  contentType: string
  timestamp: string
}

function getNextHockeyDay(): string {
  const today = new Date()
  const targetDays = [1, 3, 5] // Monday, Wednesday, Friday (0 = Sunday)

  // Start checking from tomorrow
  const candidate = new Date(today)
  candidate.setDate(candidate.getDate() + 1)

  // Find the next Mon/Wed/Fri
  while (!targetDays.includes(candidate.getDay())) {
    candidate.setDate(candidate.getDate() + 1)
  }

  // Format as YYYY-MM-DD
  const year = candidate.getFullYear()
  const month = String(candidate.getMonth() + 1).padStart(2, '0')
  const day = String(candidate.getDate()).padStart(2, '0')

  return `${year}-${month}-${day}`
}

function getDayName(dateStr: string): string {
  const date = new Date(dateStr + 'T00:00:00')
  const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
  return days[date.getDay()]
}

async function discoverAPI(): Promise<void> {
  const targetDate = getNextHockeyDay()
  const dayName = getDayName(targetDate)
  const url = `https://apps.daysmartrecreation.com/dash/x/#/online/extremeice/event-registration?date=${targetDate}&facility_ids=1`

  console.log(`\n🔍 API Discovery Tool`)
  console.log(`📅 Target Date: ${dayName}, ${targetDate}`)
  console.log(`🌐 URL: ${url}`)
  console.log(`\n🎬 Launching browser in headed mode...\n`)

  const browser = await chromium.launch({ headless: false })
  const context = await browser.newContext()
  const page = await context.newPage()

  const captures: NetworkCapture[] = []
  let jsonResponseCount = 0

  // Intercept requests
  page.on('request', (request) => {
    const resourceType = request.resourceType()
    if (resourceType === 'xhr' || resourceType === 'fetch') {
      console.log(`📤 ${request.method()} ${request.url()}`)
    }
  })

  // Intercept responses
  page.on('response', async (response) => {
    const request = response.request()
    const resourceType = request.resourceType()

    if (resourceType === 'xhr' || resourceType === 'fetch') {
      const contentType = response.headers()['content-type'] || ''
      const status = response.status()

      const capture: NetworkCapture = {
        url: response.url(),
        method: request.method(),
        status,
        contentType,
        timestamp: new Date().toISOString(),
      }

      captures.push(capture)

      console.log(`📥 ${status} ${contentType.split(';')[0]} - ${response.url()}`)

      // Save JSON responses
      if (contentType.includes('application/json')) {
        try {
          const body = await response.json()
          jsonResponseCount++

          // Create descriptive filename from URL
          const urlObj = new URL(response.url())
          const pathParts = urlObj.pathname.split('/').filter(Boolean)
          const filename = pathParts.length > 0
            ? `${pathParts.join('_')}_${Date.now()}.json`
            : `response_${Date.now()}.json`

          const filepath = join('fixtures', 'api-discovery', filename)
          await writeFile(filepath, JSON.stringify(body, null, 2))
          console.log(`   💾 Saved to ${filename}`)
        } catch (error) {
          console.log(`   ⚠️  Failed to parse JSON: ${error}`)
        }
      }
    }
  })

  // Navigate to the page
  console.log(`\n🚀 Navigating to DASH...`)
  await page.goto(url)

  // Wait for events to load (adjust timeout as needed)
  console.log(`⏳ Waiting for events to render...`)
  try {
    // Wait for potential API calls to complete
    await page.waitForLoadState('networkidle', { timeout: 10000 })

    // Additional wait to ensure dynamic content renders
    await page.waitForTimeout(3000)
  } catch (error) {
    console.log(`⚠️  Timeout waiting for network idle, proceeding anyway...`)
  }

  // Take screenshot
  const screenshotPath = join('fixtures', 'api-discovery', `dash_${targetDate}.png`)
  await page.screenshot({ path: screenshotPath, fullPage: true })
  console.log(`📸 Screenshot saved to ${screenshotPath}`)

  // Save network log
  const logPath = join('fixtures', 'api-discovery', `network_log_${targetDate}.json`)
  await writeFile(logPath, JSON.stringify(captures, null, 2))
  console.log(`📋 Network log saved to ${logPath}`)

  // Print summary
  console.log(`\n✅ API Discovery Complete`)
  console.log(`📊 Summary:`)
  console.log(`   - Found ${captures.length} XHR/Fetch requests`)
  console.log(`   - ${jsonResponseCount} returned JSON`)
  console.log(`\n🔍 Review the fixtures/api-discovery/ directory for captured data`)
  console.log(`\n⏸️  Browser will remain open for manual inspection.`)
  console.log(`   Press Ctrl+C to close when done.\n`)

  // Keep browser open for manual inspection
  await new Promise(() => {}) // Infinite wait
}

// Run the discovery
discoverAPI().catch((error) => {
  console.error('❌ Error during API discovery:', error)
  process.exit(1)
})
