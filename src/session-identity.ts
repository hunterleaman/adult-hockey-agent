/**
 * Single definition of session identity. Post-merger, XIC (facility 1) and
 * PIH (facility 2) share one DASH tenant, so date+time alone is ambiguous —
 * two rinks can run pickup at the same time slot.
 */
export interface SessionRef {
  date: string // YYYY-MM-DD
  time: string // HH:MM (24h)
  facilityId?: number // DASH facility; undefined on legacy state/button values
}

export function sessionKey(ref: SessionRef): string {
  return `${ref.date}:${ref.time}:${ref.facilityId ?? 0}`
}

export function sessionMatches(a: SessionRef, b: SessionRef): boolean {
  if (a.date !== b.date || a.time !== b.time) return false
  // Legacy fallback: state entries and Slack button values written before
  // facility awareness lack facilityId — match on date+time alone for those.
  if (a.facilityId === undefined || b.facilityId === undefined) return true
  return a.facilityId === b.facilityId
}
