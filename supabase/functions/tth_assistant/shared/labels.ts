// Display-label helpers used across tools that render Romanian summaries.
// Extracted from index.ts on 2026-07-10.

/** Romanian display label for a `payment_cycles.status` + method pair. */
export function paymentLabel(
  status: string | null | undefined,
  method?: string | null,
): string {
  const m = (method ?? "").trim().toUpperCase();
  const tail = m ? ` ${m}` : "";
  switch (status) {
    case "paid":
      return `Plată confirmată${tail}`;
    case "paid_advance":
      return `Achitat în avans${tail}`;
    case "due":
      return "Plată neconfirmată";
    case "overdue":
      return "Restant";
    case "cancelled":
      return "Anulat";
    default:
      return "—";
  }
}

/** Canonical workshop-type bucket so the model can group reliably. */
export function workshopCategory(type: string | null | undefined): string {
  const t = (type ?? "").toLowerCase();
  if (t.includes("robotic")) return "Robotică";
  if (t.includes("lectur")) return "Lectură";
  if (t.includes("modela")) return "Modelare 3D";
  if (t.includes("tales") || t.includes("povestiri")) return "Povestiri";
  if (t.includes("desen") || t.includes("pictur") || t.includes("culoare")) {
    return "Desen & Pictură";
  }
  if (t.includes("program") || t.includes("ai") || t.includes("inteligenț")) {
    return "Programare & AI";
  }
  return (type ?? "Necategorizat").trim() || "Necategorizat";
}
