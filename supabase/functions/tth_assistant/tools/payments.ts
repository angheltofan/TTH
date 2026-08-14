// Payment-related tools: due/overdue cycles, method-filtered listings,
// financial summary, amount summary, advance/cancelled cycles,
// per-child cycle history, "near next payment" watch.
//
// Extracted from index.ts on 2026-07-10. Every function was moved as-is
// (only the `export` prefix was added); logic and DB semantics are
// identical to the pre-refactor version.

import type { SupabaseClient, ToolDef, ToolHandler } from "../shared/types.ts";
import { addDays, ymd } from "../shared/date.ts";
import { fullName, trim } from "../shared/format.ts";
import { paymentLabel } from "../shared/labels.ts";
import {
  fetchChildNames,
  fetchTrainerNames,
  findChildByName,
} from "../shared/lookups.ts";

// ─────────────────────────────────────────────────────────────────────
// Schemas
// ─────────────────────────────────────────────────────────────────────

export const paymentsTools: ToolDef[] = [
  {
    name: "get_payments_due",
    description:
      "Ciclurile de plată cu status due sau overdue. Returnează numele copiilor afectați și totalurile.",
    parameters: {
      type: "object",
      properties: {
        only_overdue: {
          type: "boolean",
          description: "Dacă true, doar restante. Altfel due+overdue.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_financial_summary",
    description:
      "Sumar financiar: cicluri neîncasate (due), restante (overdue), achitate luna aceasta și copiii cu cele mai multe plăți restante. Nu returnează sume monetare exacte (prețul/sesiune nu este stocat în aplicație).",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_payments_by_method",
    description:
      "Listează plățile confirmate filtrate după una sau mai multe metode (POS, " +
      "OP/transfer bancar, unknown). Rezultatele sunt grupate pe metodă. " +
      "Pentru fiecare plată returnează: id ciclu, nume copil, numele părintelui, " +
      "sumă, monedă, data plății (paid_at), created_at, status, metodă, " +
      "confirmed_by (numele utilizatorului care a confirmat plata), perioada " +
      "ciclului, ședințe. Folosește pentru: 'cine a plătit cu POS', 'cine a " +
      "plătit prin OP', 'arată-mi toate plățile POS și OP din iunie', 'grupează " +
      "plățile după metodă'. Alias-uri recunoscute automat: 'card' → pos; " +
      "'transfer', 'transfer bancar', 'bank transfer', 'ordin de plată' → op.",
    parameters: {
      type: "object",
      properties: {
        methods: {
          type: "array",
          items: { type: "string", enum: ["pos", "op", "unknown"] },
          minItems: 1,
          uniqueItems: true,
          description:
            "Metodele de plată de returnat. Poate conține una sau mai multe din " +
            "'pos' (card/POS), 'op' (transfer bancar / OP / ordin de plată), " +
            "'unknown' (plăți confirmate fără metodă înregistrată). Pentru " +
            "'arată-mi POS și OP' trimite [\"pos\", \"op\"].",
        },
        year: {
          type: "integer",
          minimum: 2020,
          maximum: 2100,
          description:
            "Anul ferestrei de căutare. Combinat cu [month] restrânge la o " +
            "lună calendaristică (paid_at ∈ [1-a, ultima_zi]). Dacă lipsește " +
            "și există [month], se folosește anul curent.",
        },
        month: {
          type: "integer",
          minimum: 1,
          maximum: 12,
          description:
            "Luna (1-12). Combinată cu [year] filtrează plățile cu paid_at " +
            "în acea lună. Ignorat dacă lipsește.",
        },
        days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description:
            "Fereastra de zile în urmă când NU se folosește year/month " +
            "(implicit 30).",
        },
        limit_per_method: {
          type: "integer",
          minimum: 1,
          maximum: 200,
          description:
            "Maxim plăți returnate per metodă (implicit 100). Grupele fiecărei " +
            "metode sunt tăiate separat la această limită.",
        },
      },
      required: ["methods"],
      additionalProperties: false,
    },
  },
  {
    name: "get_advance_paid_cycles",
    description:
      "Cicluri de plată achitate în avans, cu copilul, data plății, metoda, sesiunile incluse.",
    parameters: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 50 } },
      additionalProperties: false,
    },
  },
  {
    name: "get_cancelled_payment_cycles",
    description: "Cicluri de plată anulate (status=cancelled).",
    parameters: {
      type: "object",
      properties: { limit: { type: "integer", minimum: 1, maximum: 50 } },
      additionalProperties: false,
    },
  },
  {
    name: "get_payment_cycles_by_child",
    description:
      "Istoria ciclurilor de plată pentru un copil, ordonată cronologic descrescător.",
    parameters: {
      type: "object",
      properties: {
        child_name: { type: "string", description: "Numele copilului." },
        limit: { type: "integer", minimum: 1, maximum: 30 },
      },
      required: ["child_name"],
      additionalProperties: false,
    },
  },
  {
    name: "get_payment_amount_summary",
    description:
      "Sumar de valori monetare pe payment_cycles. Calculează DOAR din rândurile " +
      "care au coloana amount nenulă. Returnează separat total încasat, total restant, " +
      "câte cicluri nu au sumă, și o notă explicită când lipsesc sume. " +
      "Niciodată nu inventează prețuri.",
    parameters: {
      type: "object",
      properties: {
        year: { type: "integer", description: "An (opțional)." },
        month: {
          type: "integer",
          minimum: 1,
          maximum: 12,
          description: "Lună (opțional).",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_recent_confirmed_payments",
    description:
      "Plăți confirmate recent: numele copilului, suma (dacă există), valuta, " +
      "data plății, cine a confirmat, metoda. Folosește pentru 'plăți confirmate ultima săptămână'.",
    parameters: {
      type: "object",
      properties: {
        days: {
          type: "integer",
          minimum: 1,
          maximum: 365,
          description: "Fereastra în zile. Implicit 30.",
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: 50,
          description: "Maxim plăți returnate. Implicit 20.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_children_near_payment_cycle",
    description:
      "Copii plătitori cu 3 prezențe în ciclul curent — la o singură prezență de " +
      "finalizare. Niciodată include copii cu participare gratuită. " +
      "Folosește pentru 'cine e aproape de următoarea plată'.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
];

// ─────────────────────────────────────────────────────────────────────
// Implementations
// ─────────────────────────────────────────────────────────────────────

export async function toolGetPaymentsDue(
  admin: SupabaseClient,
  args: { only_overdue?: boolean },
): Promise<Record<string, unknown>> {
  const statuses = args.only_overdue ? ["overdue"] : ["due", "overdue"];
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "child_id, status, payment_method, period_start, period_end, " +
        "sessions_count, paid_at, confirmed_by, " +
        "children!inner(first_name, last_name, payment_type)",
    )
    .in("status", statuses)
    .eq("children.payment_type", "paid")
    .order("period_start", { ascending: false })
    .limit(50);

  const rows = (data ?? []) as Array<{
    child_id: string;
    status: string | null;
    payment_method: string | null;
    period_start: string | null;
    period_end: string | null;
    sessions_count: number | null;
    paid_at: string | null;
    confirmed_by: string | null;
    children:
      | { first_name: string | null; last_name: string | null; payment_type: string | null }
      | null;
  }>;

  const overdue = rows.filter((r) => r.status === "overdue").length;
  const due = rows.filter((r) => r.status === "due").length;

  return {
    total: rows.length,
    restante: overdue,
    neconfirmate: due,
    detalii: rows.map((r) => ({
      copil: r.children
        ? fullName(r.children.first_name, r.children.last_name)
        : null,
      child_id: r.child_id,
      status: r.status,
      metoda: (r.payment_method ?? "").toUpperCase() || null,
      perioada: `${r.period_start} – ${r.period_end}`,
      sedinte: r.sessions_count,
    })),
  };
}

export async function toolGetFinancialSummary(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const now = new Date();
  const monthStart = ymd(new Date(now.getFullYear(), now.getMonth(), 1));
  const nextMonthStart = ymd(
    new Date(now.getFullYear(), now.getMonth() + 1, 1),
  );

  const [dueRes, overdueRes, paidThisMonthRes, outstandingRes] = await Promise
    .all([
      admin
        .from("payment_cycles")
        .select("id, children!inner(payment_type)", {
          count: "exact",
          head: true,
        })
        .eq("status", "due")
        .eq("children.payment_type", "paid"),
      admin
        .from("payment_cycles")
        .select("id, children!inner(payment_type)", {
          count: "exact",
          head: true,
        })
        .eq("status", "overdue")
        .eq("children.payment_type", "paid"),
      admin
        .from("payment_cycles")
        .select("id, children!inner(payment_type)", {
          count: "exact",
          head: true,
        })
        .eq("status", "paid")
        .eq("children.payment_type", "paid")
        .gte("paid_at", monthStart)
        .lt("paid_at", nextMonthStart),
      admin
        .from("payment_cycles")
        .select(
          "child_id, sessions_count, status, period_start, period_end, " +
            "children!inner(payment_type)",
        )
        .in("status", ["due", "overdue"])
        .eq("children.payment_type", "paid"),
    ]);

  const outstanding = (outstandingRes.data ?? []) as Array<{
    child_id: string;
    sessions_count: number | null;
    status: string | null;
    period_start: string | null;
    period_end: string | null;
  }>;

  type ChildAgg = {
    cycles: number;
    sessions: number;
    overdue: number;
    earliestPeriod: string | null;
  };
  const perChild = new Map<string, ChildAgg>();
  for (const r of outstanding) {
    const b = perChild.get(r.child_id) ??
      { cycles: 0, sessions: 0, overdue: 0, earliestPeriod: null };
    b.cycles += 1;
    b.sessions += r.sessions_count ?? 0;
    if (r.status === "overdue") b.overdue += 1;
    if (
      r.period_start &&
      (b.earliestPeriod === null || r.period_start < b.earliestPeriod)
    ) {
      b.earliestPeriod = r.period_start;
    }
    perChild.set(r.child_id, b);
  }

  const childIds = Array.from(perChild.keys());
  let topChildren: Array<Record<string, unknown>> = [];
  if (childIds.length > 0) {
    const { data: kids } = await admin
      .from("children")
      .select("id, first_name, last_name")
      .in("id", childIds);
    const names = new Map<string, string>();
    for (
      const k of (kids ?? []) as Array<
        { id: string; first_name: string | null; last_name: string | null }
      >
    ) {
      names.set(k.id, fullName(k.first_name, k.last_name));
    }
    topChildren = childIds
      .map((id) => {
        const b = perChild.get(id)!;
        return {
          nume: names.get(id) ?? "Necunoscut",
          cicluri_neincasate: b.cycles,
          sedinte_neincasate: b.sessions,
          restante: b.overdue,
          cea_mai_veche_perioada: b.earliestPeriod,
        };
      })
      .sort((a, b) =>
        (b.restante as number) - (a.restante as number) ||
        (b.cicluri_neincasate as number) - (a.cicluri_neincasate as number) ||
        (b.sedinte_neincasate as number) - (a.sedinte_neincasate as number)
      )
      .slice(0, 5);
  }

  const totalOutstandingSessions = outstanding.reduce(
    (s, r) => s + (r.sessions_count ?? 0),
    0,
  );

  return {
    cicluri_neincasate: dueRes.count ?? 0,
    cicluri_restante: overdueRes.count ?? 0,
    cicluri_platite_luna_aceasta: paidThisMonthRes.count ?? 0,
    total_sedinte_neincasate: totalOutstandingSessions,
    nota_suma:
      "Aplicația nu stochează preț per sesiune; o sumă monetară exactă nu poate fi calculată. Folosește total_sedinte_neincasate ca proxy.",
    copii_cu_cele_mai_multe_plati_neincasate: topChildren,
  };
}

// Method key used internally by toolGetPaymentsByMethod.
type MethodKey = "pos" | "op" | "unknown";

// Raw shape read from `payment_cycles`. Children and confirmer profiles
// are joined in code via batched follow-up queries — we intentionally
// do NOT use PostgREST's `children!inner(...)` embedding because in
// some environments the FK is not auto-detected (or the schema cache
// is stale), causing the embed to silently return null.
interface PaymentCycleRow {
  id: string;
  child_id: string;
  status: string | null;
  payment_method: string | null;
  paid_at: string | null;
  created_at: string | null;
  confirmed_by: string | null;
  amount?: number | null;
  currency?: string | null;
  period_start: string | null;
  period_end: string | null;
  sessions_count: number | null;
  notes: string | null;
}

export async function toolGetPaymentsByMethod(
  admin: SupabaseClient,
  args: {
    methods?: string[];
    method?: string;
    year?: number;
    month?: number;
    days?: number;
    limit_per_method?: number;
  },
): Promise<Record<string, unknown>> {
  const methodMap: Record<string, MethodKey> = {
    "pos": "pos",
    "card": "pos",
    "op": "op",
    "transfer": "op",
    "transfer bancar": "op",
    "bank transfer": "op",
    "ordin de plata": "op",
    "ordin de plată": "op",
    "unknown": "unknown",
    "necunoscut": "unknown",
    "null": "unknown",
  };
  const rawMethods = Array.isArray(args.methods) && args.methods.length > 0
    ? args.methods
    : (args.method ? [args.method] : ["pos"]);
  const methods: MethodKey[] = Array.from(
    new Set(
      rawMethods
        .map((m) => methodMap[(m ?? "").toLowerCase().trim()])
        .filter((m): m is MethodKey => !!m),
    ),
  );
  if (methods.length === 0) methods.push("pos");

  const limitPerMethod = Math.min(
    Math.max(args.limit_per_method ?? 100, 1),
    200,
  );
  let sinceIso: string;
  let untilIso: string | null = null;
  let windowLabel: string;
  if (args.month) {
    const now = new Date();
    const year = args.year ?? now.getUTCFullYear();
    const monthIdx = args.month - 1;
    const start = new Date(Date.UTC(year, monthIdx, 1));
    const end = new Date(Date.UTC(year, monthIdx + 1, 0));
    sinceIso = ymd(start);
    untilIso = ymd(end);
    windowLabel = `${sinceIso} – ${untilIso}`;
  } else {
    const days = Math.min(Math.max(args.days ?? 30, 1), 365);
    sinceIso = ymd(addDays(new Date(), -days));
    windowLabel = `ultimele ${days} zile (de la ${sinceIso})`;
  }

  let amountAvailable = true;
  const probe = await admin.from("payment_cycles").select("amount").limit(1);
  if (probe.error) {
    const code = (probe.error as { code?: string }).code;
    if (code === "42703" || (probe.error.message ?? "").includes("amount")) {
      amountAvailable = false;
    }
  }
  const selectCols = amountAvailable
    ? "id, child_id, status, payment_method, paid_at, created_at, " +
      "confirmed_by, amount, currency, period_start, period_end, " +
      "sessions_count, notes"
    : "id, child_id, status, payment_method, paid_at, created_at, " +
      "confirmed_by, period_start, period_end, sessions_count, notes";

  const perMethodQueries = methods.map((m) => {
    let q = admin
      .from("payment_cycles")
      .select(selectCols)
      .in("status", ["paid", "paid_advance"])
      .gte("paid_at", sinceIso)
      .order("paid_at", { ascending: false })
      .limit(limitPerMethod);
    if (untilIso) q = q.lte("paid_at", untilIso);
    if (m === "unknown") q = q.is("payment_method", null);
    else q = q.eq("payment_method", m);
    return q;
  });
  const perMethodResults = await Promise.all(perMethodQueries);

  const allChildIds = new Set<string>();
  for (const res of perMethodResults) {
    const rows = (res.data ?? []) as PaymentCycleRow[];
    for (const r of rows) if (r.child_id) allChildIds.add(r.child_id);
  }
  const childMap = new Map<
    string,
    {
      first_name: string | null;
      last_name: string | null;
      parent_name: string | null;
      payment_type: string | null;
    }
  >();
  let childrenFetched = 0;
  if (allChildIds.size > 0) {
    const { data: kids, error: kidsErr } = await admin
      .from("children")
      .select("id, first_name, last_name, parent_name, payment_type")
      .in("id", Array.from(allChildIds));
    if (!kidsErr) {
      for (
        const c of (kids ?? []) as Array<{
          id: string;
          first_name: string | null;
          last_name: string | null;
          parent_name: string | null;
          payment_type: string | null;
        }>
      ) {
        childMap.set(c.id, {
          first_name: c.first_name,
          last_name: c.last_name,
          parent_name: c.parent_name,
          payment_type: c.payment_type,
        });
      }
      childrenFetched = kids?.length ?? 0;
    }
  }

  const allConfirmerIds = new Set<string>();
  for (const res of perMethodResults) {
    const rows = (res.data ?? []) as PaymentCycleRow[];
    for (const r of rows) if (r.confirmed_by) allConfirmerIds.add(r.confirmed_by);
  }
  const confirmerNames = new Map<string, string>();
  let confirmersFetched = 0;
  if (allConfirmerIds.size > 0) {
    const { data: profs } = await admin
      .from("profiles")
      .select("id, first_name, last_name")
      .in("id", Array.from(allConfirmerIds));
    for (
      const p of (profs ?? []) as Array<{
        id: string;
        first_name: string | null;
        last_name: string | null;
      }>
    ) {
      confirmerNames.set(p.id, fullName(p.first_name, p.last_name));
    }
    confirmersFetched = profs?.length ?? 0;
  }

  const mapRow = (r: PaymentCycleRow) => {
    const amount = amountAvailable && typeof r.amount === "number"
      ? r.amount
      : null;
    const child = childMap.get(r.child_id) ?? null;
    const copil = child
      ? fullName(child.first_name, child.last_name)
      : `child_id: ${r.child_id} (nume nerezolvat)`;
    const confirmatDe = r.confirmed_by
      ? (confirmerNames.get(r.confirmed_by) ??
        `confirmed_by: ${r.confirmed_by} (nume nerezolvat)`)
      : null;
    return {
      payment_cycle_id: r.id,
      child_id: r.child_id,
      child_first_name: child?.first_name ?? null,
      child_last_name: child?.last_name ?? null,
      copil,
      parinte: child?.parent_name ?? null,
      status: r.status,
      metoda: (r.payment_method ?? "").toUpperCase() || null,
      suma: amount,
      moneda: amount !== null ? (r.currency ?? "RON") : null,
      confirmed_at: r.paid_at?.slice(0, 10) ?? null,
      created_at: r.created_at?.slice(0, 10) ?? null,
      confirmed_by: r.confirmed_by,
      confirmat_de: confirmatDe,
      perioada: r.period_start && r.period_end
        ? `${r.period_start} – ${r.period_end}`
        : null,
      sedinte: r.sessions_count,
      ciclu_note: (r.notes ?? "").trim() || null,
    };
  };

  const groups: Record<string, {
    total: number;
    suma_totala: number | null;
    plati: ReturnType<typeof mapRow>[];
  }> = {};
  let anyErr: string | null = null;
  let grandTotal = 0;
  let grandAmount = 0;
  let anyAmountSeen = false;
  let cyclesFetched = 0;
  let droppedFree = 0;
  for (let i = 0; i < methods.length; i++) {
    const method = methods[i];
    const res = perMethodResults[i];
    const key = method === "unknown" ? "NECUNOSCUT" : method.toUpperCase();
    if (res.error) {
      anyErr = res.error.message;
      groups[key] = { total: 0, suma_totala: null, plati: [] };
      continue;
    }
    const rows = (res.data ?? []) as PaymentCycleRow[];
    cyclesFetched += rows.length;
    const filtered = rows.filter((r) => {
      const child = childMap.get(r.child_id);
      if (child && child.payment_type === "free") {
        droppedFree++;
        return false;
      }
      return true;
    });
    const plati = filtered.map(mapRow);
    let sumaTotala: number | null = null;
    if (amountAvailable) {
      sumaTotala = 0;
      for (const p of plati) {
        if (p.suma !== null) {
          sumaTotala += p.suma;
          grandAmount += p.suma;
          anyAmountSeen = true;
        }
      }
    }
    grandTotal += plati.length;
    groups[key] = {
      total: plati.length,
      suma_totala: sumaTotala,
      plati,
    };
  }

  return {
    metode_cerute: methods.map((m) =>
      m === "unknown" ? "NECUNOSCUT" : m.toUpperCase()
    ),
    fereastra: windowLabel,
    limit_per_metoda: limitPerMethod,
    total_plati: grandTotal,
    total_suma: amountAvailable && anyAmountSeen ? grandAmount : null,
    moneda: amountAvailable && anyAmountSeen ? "RON" : null,
    pe_metoda: groups,
    debug: {
      cycles_fetched: cyclesFetched,
      children_fetched: childrenFetched,
      confirmers_fetched: confirmersFetched,
      dropped_free_participants: droppedFree,
      unresolved_child_ids: Array.from(allChildIds).filter(
        (id) => !childMap.has(id),
      ).length,
      unresolved_confirmer_ids: Array.from(allConfirmerIds).filter(
        (id) => !confirmerNames.has(id),
      ).length,
    },
    nota: amountAvailable
      ? (anyErr ? `Interogare parțial eșuată: ${anyErr}` : null)
      : "Coloana payment_cycles.amount nu există în această schemă — sumele lipsesc.",
  };
}

export async function toolGetAdvancePaidCycles(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "child_id, paid_at, payment_method, sessions_count, " +
        "children!inner(payment_type)",
    )
    .eq("status", "paid_advance")
    .eq("children.payment_type", "paid")
    .order("paid_at", { ascending: false });
  const rows = (data ?? []) as Array<{
    child_id: string;
    paid_at: string | null;
    payment_method: string | null;
    sessions_count: number | null;
  }>;
  const names = await fetchChildNames(admin, rows.map((r) => r.child_id));
  return {
    total: rows.length,
    cicluri_in_avans: trim(
      rows.map((r) => ({
        nume: names.get(r.child_id) ?? "Necunoscut",
        platit_la: r.paid_at?.slice(0, 10) ?? null,
        metoda: (r.payment_method ?? "").toUpperCase() || null,
        sedinte: r.sessions_count,
      })),
      limit,
    ),
  };
}

export async function toolGetCancelledPaymentCycles(
  admin: SupabaseClient,
  args: { limit?: number },
): Promise<Record<string, unknown>> {
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "child_id, period_start, period_end, sessions_count, " +
        "children!inner(payment_type)",
    )
    .eq("status", "cancelled")
    .eq("children.payment_type", "paid")
    .order("period_start", { ascending: false });
  const rows = (data ?? []) as Array<{
    child_id: string;
    period_start: string | null;
    period_end: string | null;
    sessions_count: number | null;
  }>;
  const names = await fetchChildNames(admin, rows.map((r) => r.child_id));
  return {
    total: rows.length,
    cicluri_anulate: trim(
      rows.map((r) => ({
        nume: names.get(r.child_id) ?? "Necunoscut",
        perioada: r.period_start && r.period_end
          ? `${r.period_start} – ${r.period_end}`
          : null,
        sedinte: r.sessions_count,
      })),
      limit,
    ),
  };
}

export async function toolGetPaymentCyclesByChild(
  admin: SupabaseClient,
  args: { child_name: string; limit?: number },
): Promise<Record<string, unknown>> {
  const child = await findChildByName(admin, args.child_name ?? "");
  if (!child) return { eroare: `Nu am găsit copilul "${args.child_name}".` };

  const { data: meta } = await admin
    .from("children")
    .select("payment_type")
    .eq("id", child.id)
    .maybeSingle();
  if ((meta?.payment_type as string | undefined) === "free") {
    return {
      copil: child.full,
      tip_participare: "gratuit",
      total: 0,
      cicluri: [],
      nota:
        "Copilul are participare gratuită — nu se generează cicluri de plată " +
        "pentru el. Pentru istoricul prezenței folosește get_child_recent_activity.",
    };
  }

  const limit = Math.min(Math.max(args.limit ?? 10, 1), 30);
  const { data } = await admin
    .from("payment_cycles")
    .select(
      "period_start, period_end, sessions_count, status, payment_method, paid_at",
    )
    .eq("child_id", child.id)
    .order("period_start", { ascending: false })
    .limit(limit);
  const rows = (data ?? []) as Array<{
    period_start: string | null;
    period_end: string | null;
    sessions_count: number | null;
    status: string | null;
    payment_method: string | null;
    paid_at: string | null;
  }>;
  return {
    copil: child.full,
    total: rows.length,
    cicluri: rows.map((r) => ({
      perioada: r.period_start && r.period_end
        ? `${r.period_start} – ${r.period_end}`
        : null,
      sedinte: r.sessions_count,
      status: paymentLabel(r.status, r.payment_method),
      platit_la: r.paid_at?.slice(0, 10) ?? null,
    })),
  };
}

export async function toolGetPaymentAmountSummary(
  admin: SupabaseClient,
  args: { year?: number; month?: number },
): Promise<Record<string, unknown>> {
  let amountColumnExists = true;
  const probe = await admin
    .from("payment_cycles")
    .select(
      "amount, currency, status, paid_at, period_start, period_end, " +
        "children!inner(payment_type)",
    )
    .eq("children.payment_type", "paid")
    .limit(1);
  if (probe.error) {
    const code = (probe.error as { code?: string }).code;
    if (code === "42703" || (probe.error.message ?? "").includes("amount")) {
      amountColumnExists = false;
    }
  }
  if (!amountColumnExists) {
    return {
      nota:
        "Aplicația nu stochează valori monetare per ciclu (coloana amount lipsește). " +
        "Pot raporta doar număr de cicluri, nu sume.",
      suma_incasata: null,
      suma_restanta: null,
    };
  }

  let q = admin
    .from("payment_cycles")
    .select(
      "amount, currency, status, paid_at, period_start, period_end, " +
        "children!inner(payment_type)",
    )
    .eq("children.payment_type", "paid");

  if (args.year && args.month) {
    const monthStart = `${args.year}-${String(args.month).padStart(2, "0")}-01`;
    const nextMonth = new Date(args.year, args.month, 1);
    const monthEnd = ymd(addDays(nextMonth, -1));
    q = q.or(
      `and(paid_at.gte.${monthStart},paid_at.lte.${monthEnd}T23:59:59),` +
        `and(period_start.lte.${monthEnd},period_end.gte.${monthStart})`,
    );
  }

  const { data } = await q;
  const rows = (data ?? []) as Array<{
    amount: number | null;
    currency: string | null;
    status: string | null;
    paid_at: string | null;
    period_start: string | null;
    period_end: string | null;
  }>;
  let paidAmount = 0;
  let pendingAmount = 0;
  let paidCount = 0;
  let pendingCount = 0;
  let amountMissing = 0;
  const currencies = new Set<string>();
  for (const r of rows) {
    if (r.amount == null) {
      amountMissing += 1;
      continue;
    }
    if (r.currency) currencies.add(r.currency.toUpperCase());
    if (r.status === "paid" || r.status === "paid_advance") {
      paidAmount += r.amount;
      paidCount += 1;
    } else if (r.status === "due" || r.status === "overdue") {
      pendingAmount += r.amount;
      pendingCount += 1;
    }
  }
  return {
    interval: args.year && args.month
      ? `${args.year}-${String(args.month).padStart(2, "0")}`
      : "toate ciclurile",
    suma_incasata: paidAmount,
    cicluri_incasate: paidCount,
    suma_restanta: pendingAmount,
    cicluri_restante: pendingCount,
    cicluri_fara_suma: amountMissing,
    valute: Array.from(currencies),
    nota: amountMissing > 0
      ? `Atenție: ${amountMissing} cicluri nu au valoare monetară completată ` +
        `(amount NULL). Sumele de mai sus sunt parțiale.`
      : undefined,
  };
}

export async function toolGetRecentConfirmedPayments(
  admin: SupabaseClient,
  args: { days?: number; limit?: number },
): Promise<Record<string, unknown>> {
  const days = Math.min(Math.max(args.days ?? 30, 1), 365);
  const limit = Math.min(Math.max(args.limit ?? 20, 1), 50);
  const since = ymd(addDays(new Date(), -days));
  let q = admin
    .from("payment_cycles")
    .select(
      "child_id, paid_at, payment_method, status, " +
        "children!inner(first_name, last_name, payment_type), " +
        "confirmed_by",
    )
    .in("status", ["paid", "paid_advance"])
    .eq("children.payment_type", "paid")
    .gte("paid_at", since)
    .order("paid_at", { ascending: false })
    .limit(limit);
  let amountAvailable = true;
  const probe = await admin.from("payment_cycles").select("amount").limit(1);
  if (probe.error) {
    const code = (probe.error as { code?: string }).code;
    if (code === "42703" || (probe.error.message ?? "").includes("amount")) {
      amountAvailable = false;
    }
  }
  if (amountAvailable) {
    q = admin
      .from("payment_cycles")
      .select(
        "child_id, paid_at, payment_method, status, amount, currency, " +
          "children!inner(first_name, last_name, payment_type), " +
          "confirmed_by",
      )
      .in("status", ["paid", "paid_advance"])
      .eq("children.payment_type", "paid")
      .gte("paid_at", since)
      .order("paid_at", { ascending: false })
      .limit(limit);
  }
  const { data } = await q;
  const rows = (data ?? []) as Array<{
    child_id: string;
    paid_at: string | null;
    payment_method: string | null;
    status: string | null;
    amount?: number | null;
    currency?: string | null;
    children: {
      first_name: string | null;
      last_name: string | null;
      payment_type: string | null;
    } | null;
    confirmed_by: string | null;
  }>;
  const trainerIds = rows.map((r) => r.confirmed_by ?? "").filter(Boolean);
  const confirmerNames = await fetchTrainerNames(admin, trainerIds);
  return {
    fereastra_zile: days,
    total: rows.length,
    plati: rows.map((r) => ({
      copil: r.children
        ? fullName(r.children.first_name, r.children.last_name)
        : null,
      suma: r.amount ?? null,
      valuta: r.currency ?? null,
      data: r.paid_at?.slice(0, 10) ?? null,
      metoda: (r.payment_method ?? "").toUpperCase() || null,
      confirmat_de: r.confirmed_by
        ? (confirmerNames.get(r.confirmed_by) ?? "Necunoscut")
        : null,
      status: r.status,
    })),
    nota: amountAvailable ? undefined : "Coloana amount nu este disponibilă.",
  };
}

export async function toolGetChildrenNearPaymentCycle(
  admin: SupabaseClient,
): Promise<Record<string, unknown>> {
  const { data: attRows } = await admin
    .from("attendance")
    .select(
      "child_id, status, marked_at, " +
        "children!inner(payment_type, first_name, last_name, is_active), " +
        "scheduled_workshops!scheduled_workshop_id(title, workshop_date)",
    )
    .is("payment_cycle_id", null)
    .eq("is_archived", false)
    .eq("children.payment_type", "paid")
    .eq("children.is_active", true);
  const rows = (attRows ?? []) as Array<{
    child_id: string;
    status: string | null;
    marked_at: string | null;
    children: {
      payment_type: string | null;
      first_name: string | null;
      last_name: string | null;
      is_active: boolean;
    } | null;
    scheduled_workshops: {
      title: string | null;
      workshop_date: string | null;
    } | null;
  }>;
  type Bucket = {
    name: string;
    present: number;
    lastDate: string | null;
    lastWorkshop: string | null;
  };
  const byChild = new Map<string, Bucket>();
  for (const r of rows) {
    if (!r.children) continue;
    const b = byChild.get(r.child_id) ?? {
      name: fullName(r.children.first_name, r.children.last_name),
      present: 0,
      lastDate: null,
      lastWorkshop: null,
    };
    if (r.status === "present") b.present += 1;
    const wsDate = r.scheduled_workshops?.workshop_date ?? null;
    if (wsDate && (b.lastDate == null || wsDate > b.lastDate)) {
      b.lastDate = wsDate;
      b.lastWorkshop = r.scheduled_workshops?.title ?? null;
    }
    byChild.set(r.child_id, b);
  }
  const near = Array.from(byChild.values())
    .filter((b) => b.present === 3)
    .sort((a, b) => (a.lastDate ?? "").localeCompare(b.lastDate ?? ""));
  return {
    total: near.length,
    copii: near.map((b) => ({
      copil: b.name,
      prezente_in_ciclul_curent: b.present,
      ultima_prezenta: b.lastDate,
      ultimul_atelier: b.lastWorkshop,
    })),
  };
}

// ─────────────────────────────────────────────────────────────────────
// Dispatcher for this module
// ─────────────────────────────────────────────────────────────────────

export const paymentsHandlers: Record<string, ToolHandler> = {
  "get_payments_due": (admin, args) =>
    toolGetPaymentsDue(admin, args as { only_overdue?: boolean }),
  "get_financial_summary": (admin) => toolGetFinancialSummary(admin),
  "get_payments_by_method": (admin, args) =>
    toolGetPaymentsByMethod(admin, args as {
      methods?: string[];
      method?: string;
      year?: number;
      month?: number;
      days?: number;
      limit_per_method?: number;
    }),
  "get_advance_paid_cycles": (admin, args) =>
    toolGetAdvancePaidCycles(admin, args as { limit?: number }),
  "get_cancelled_payment_cycles": (admin, args) =>
    toolGetCancelledPaymentCycles(admin, args as { limit?: number }),
  "get_payment_cycles_by_child": (admin, args) =>
    toolGetPaymentCyclesByChild(admin, args as {
      child_name: string;
      limit?: number;
    }),
  "get_payment_amount_summary": (admin, args) =>
    toolGetPaymentAmountSummary(admin, args as {
      year?: number;
      month?: number;
    }),
  "get_recent_confirmed_payments": (admin, args) =>
    toolGetRecentConfirmedPayments(admin, args as {
      days?: number;
      limit?: number;
    }),
  "get_children_near_payment_cycle": (admin) =>
    toolGetChildrenNearPaymentCycle(admin),
};
