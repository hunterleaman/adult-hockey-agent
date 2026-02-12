import { writeFile } from 'fs/promises'
import { join } from 'path'

async function fetchAvailabilities(): Promise<void> {
  const startDate = '2026-02-12' // Today
  const url = `https://apps.daysmartrecreation.com/dash/jsonapi/api/v1/date-availabilities?cache[save]=false&page[size]=365&sort=id&filter[date__gte]=${startDate}&company=extremeice`

  console.log(`\n🔍 Fetching Date Availabilities`)
  console.log(`📅 Start Date: ${startDate}`)
  console.log(`🌐 URL: ${url}\n`)

  try {
    const response = await fetch(url, {
      headers: {
        Accept: 'application/vnd.api+json',
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
      },
    })

    console.log(`📥 Status: ${response.status} ${response.statusText}`)

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`)
    }

    const data = await response.json()

    // Save response
    const outputPath = join('fixtures', 'api-discovery', 'date-availabilities.json')
    await writeFile(outputPath, JSON.stringify(data, null, 2))
    console.log(`✅ Saved to ${outputPath}\n`)

    // Analyze the response
    if (data.data && Array.isArray(data.data)) {
      console.log(`📊 Found ${data.data.length} dates with availability\n`)

      // Look for Feb 13 and Feb 16
      const targetDates = ['2026-02-13', '2026-02-16']

      targetDates.forEach((date) => {
        const dateEntry = data.data.find((d: any) => d.attributes?.date === date || d.id === date)

        if (dateEntry) {
          console.log(`\n📅 ${date}:`)
          console.log(JSON.stringify(dateEntry, null, 2))
        } else {
          console.log(`\n⚠️  No entry found for ${date}`)
        }
      })

      // Show first few entries as examples
      console.log(`\n📋 First 3 entries:`)
      data.data.slice(0, 3).forEach((entry: any) => {
        console.log(`\nDate: ${entry.attributes?.date || entry.id}`)
        console.log(JSON.stringify(entry, null, 2))
      })
    }
  } catch (error) {
    console.error(`\n❌ Error:`, error)
    process.exit(1)
  }
}

fetchAvailabilities()
