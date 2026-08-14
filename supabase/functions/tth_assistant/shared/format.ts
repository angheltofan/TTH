// String / list / label utilities shared across tool implementations.
// Extracted from index.ts on 2026-07-10.

/** Lowercase + diacritic-free normalisation for fuzzy name matching. */
export function normalise(s: string): string {
  return s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[şș]/g, "s")
    .replace(/[ţț]/g, "t");
}

export function fullName(first?: string | null, last?: string | null): string {
  return `${(first ?? "").trim()} ${(last ?? "").trim()}`.trim();
}

/** PostgREST ilike-safe escape: literal `%` and `_` are protected. */
export function escapeIlike(s: string): string {
  return s.replace(/%/g, "\\%").replace(/_/g, "\\_");
}

/** Cap a list at [max]; never return hundreds of rows to the model. */
export function trim<T>(list: T[], max: number): T[] {
  return list.slice(0, Math.max(0, max));
}

/** Attendance rate as a whole-number percentage, or null when denominator is 0. */
export function attendanceRate(
  present: number,
  total: number,
): number | null {
  if (total <= 0) return null;
  return Math.round((present / total) * 100);
}
