// Date utilities used across every tool that talks about time
// windows. Extracted from index.ts on 2026-07-10.

export const ROMANIAN_DAYS = [
  "Duminică",
  "Luni",
  "Marți",
  "Miercuri",
  "Joi",
  "Vineri",
  "Sâmbătă",
];

export const RO_MONTHS = [
  "ianuarie",
  "februarie",
  "martie",
  "aprilie",
  "mai",
  "iunie",
  "iulie",
  "august",
  "septembrie",
  "octombrie",
  "noiembrie",
  "decembrie",
];

export function startOfWeek(d: Date): Date {
  const date = new Date(d);
  const weekday = (date.getDay() + 6) % 7; // Monday=0
  date.setDate(date.getDate() - weekday);
  date.setHours(0, 0, 0, 0);
  return date;
}

export function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

export function ymd(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/** Romanian long-format date: "5 mai 2026". Returns "" when undefined. */
export function roDate(d: Date | string | null | undefined): string {
  if (!d) return "";
  const date = typeof d === "string" ? new Date(d) : d;
  if (Number.isNaN(date.getTime())) return "";
  return `${date.getDate()} ${RO_MONTHS[date.getMonth()]} ${date.getFullYear()}`;
}

/** Trim "HH:MM:SS" → "HH:MM"; passes through anything else unchanged. */
export function trimHm(t: string | null | undefined): string {
  if (!t) return "";
  return t.length >= 5 ? t.substring(0, 5) : t;
}

/** First/last day of the calendar month containing [d]. */
export function monthBounds(
  d: Date,
): { start: string; end: string; nextStart: string } {
  const start = new Date(d.getFullYear(), d.getMonth(), 1);
  const nextStart = new Date(d.getFullYear(), d.getMonth() + 1, 1);
  const end = new Date(nextStart.getTime() - 1);
  return { start: ymd(start), end: ymd(end), nextStart: ymd(nextStart) };
}
