/* eslint-disable @typescript-eslint/no-unsafe-return */
import { writeFile } from 'fs/promises'
import { join } from 'path'

async function fetchEvents(): Promise<void> {
  const targetDate = '2026-02-13' // Friday

  // Event IDs from date-availabilities endpoint
  const eventIds = [213376, 214134, 213364, 213412, 213853, 213851, 214136, 213399]

  // Base URL from network capture
  const baseUrl = 'https://apps.daysmartrecreation.com/dash/jsonapi/api/v1/events'

  const params = new URLSearchParams({
    'cache[save]': 'false',
    'page[size]': '50',
    sort: 'end,start',
    'filter[id__in]': eventIds.join(','),
    'filter[start_date__gte]': targetDate,
    'filter[start_date__lte]': '2026-02-14',
    'filter[unconstrained]': '1',
    company: 'extremeice',
  })

  // Add include parameter (complex nested relationships)
  const includes = [
    'summary',
    'comments',
    'resource.facility.address',
    'resource.address',
    'eventType.product.locations',
    'homeTeam.facility.address',
    'homeTeam.league.season.priorities.memberships',
    'homeTeam.league.season.priorities.activatedBySeasons',
    'homeTeam.programType',
    'homeTeam.product',
    'homeTeam.product.locations',
    'homeTeam.sport',
  ]
  params.set('include', includes.join(','))
  params.set('filterRelations[comments.comment_type]', 'public')

  const url = `${baseUrl}?${params.toString()}`

  console.log(`\n🔍 Fetching Events API`)
  console.log(`📅 Date: ${targetDate}`)
  console.log(`🌐 URL: ${url}\n`)

  try {
    const response = await fetch(url, {
      headers: {
        Accept: 'application/vnd.api+json',
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
      },
    })

    console.log(`📥 Status: ${response.status} ${response.statusText}`)
    console.log(`📦 Content-Type: ${response.headers.get('content-type')}`)

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`)
    }

    const data = await response.json()

    // Save the full response
    const outputPath = join('fixtures', 'api-discovery', `events_${targetDate}.json`)
    await writeFile(outputPath, JSON.stringify(data, null, 2))
    console.log(`\n✅ Saved response to ${outputPath}`)

    // Print summary
    if (data.data && Array.isArray(data.data)) {
      console.log(`\n📊 Found ${data.data.length} total events\n`)

      // Filter for ADULT Pick Up events
      const adultEvents = data.data.filter((event: any) =>
        event.attributes?.desc?.includes('ADULT')
      )

      console.log(`🏒 Found ${adultEvents.length} ADULT events:\n`)

      adultEvents.forEach((event: any, index: number) => {
        console.log(`${index + 1}. ${event.attributes?.desc}`)
        console.log(`   ID: ${event.id}`)
        console.log(`   Start: ${event.attributes?.start}`)
        console.log(`   End: ${event.attributes?.end}`)
        console.log(`   Event Type ID: ${event.attributes?.event_type_id}`)
        console.log(`   Summary ID: ${event.relationships?.summary?.data?.id}`)
        console.log()
      })

      // Log all event types for reference
      const allTypes = [...new Set(data.data.map((e: any) => e.attributes?.desc).filter(Boolean))]
      console.log(`\n📋 All event types found: ${allTypes.length}`)
      allTypes.forEach((type) => console.log(`   - ${type}`))
    } else {
      console.log(`\n⚠️  Unexpected response format`)
    }
  } catch (error) {
    console.error(`\n❌ Error fetching events:`, error)
    process.exit(1)
  }
}

fetchEvents()
