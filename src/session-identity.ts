/**
 * Single definition of session identity. Post-merger, XIC (facility 1) and
 * PIH (facility 2) share one DASH tenant, so date+time alone is ambiguous —
 * two rinks can run pickup at the same time slot.
 */
export interface SessionRef {
  date: string // YYYY-MM-DD
  time: string // HH:MM (24h)
  facilityId?: number // DASH facility; undefined on legacy state/button values, 0 when the parser could not resolve the resource. Both mean "unknown".
}

export function sessionKey(ref: SessionRef): string {
  return `${ref.date}:${ref.time}:${ref.facilityId ?? 0}`
}

export function sessionMatches(a: SessionRef, b: SessionRef): boolean {
  if (a.date !== b.date || a.time !== b.time) return false
  // Unknown facility (undefined on legacy state/button values, or 0 when the
  // parser could not resolve the resource) matches on date+time alone.
  if (!a.facilityId || !b.facilityId) return true
  return a.facilityId === b.facilityId
}

/**
 * Count how many refs share this ref's date+time slot (facility ignored).
 * >1 signals an ambiguous slot where an unknown-facility identity could match
 * multiple concrete-facility sessions (both rinks running pickup at once).
 */
export function countSlotMatches(refs: SessionRef[], ref: SessionRef): number {
  return refs.filter((r) => r.date === ref.date && r.time === ref.time).length
}
