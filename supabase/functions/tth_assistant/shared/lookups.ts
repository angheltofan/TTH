// Batched id → name lookups used by tools that hydrate lists of
// children / trainers before returning them to the model.
// Extracted from index.ts on 2026-07-10.

import { SupabaseClient } from "./types.ts";
import { escapeIlike, fullName, normalise } from "./format.ts";

/** Bulk name lookup keyed by child id. Empty-input safe. */
export async function fetchChildNames(
  admin: SupabaseClient,
  ids: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (ids.length === 0) return out;
  const { data } = await admin
    .from("children")
    .select("id, first_name, last_name")
    .in("id", Array.from(new Set(ids)));
  for (
    const r of (data ?? []) as Array<
      { id: string; first_name: string | null; last_name: string | null }
    >
  ) {
    out.set(r.id, fullName(r.first_name, r.last_name));
  }
  return out;
}

/** Bulk name lookup keyed by profile id (trainers, admins, etc.). */
export async function fetchTrainerNames(
  admin: SupabaseClient,
  ids: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const uniq = Array.from(new Set(ids.filter((s) => s)));
  if (uniq.length === 0) return out;
  const { data } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .in("id", uniq);
  for (
    const r of (data ?? []) as Array<
      { id: string; first_name: string | null; last_name: string | null }
    >
  ) {
    out.set(r.id, fullName(r.first_name, r.last_name));
  }
  return out;
}

/** Best-effort name → trainer id resolver. Returns null on no match. */
export async function findTrainerByName(
  admin: SupabaseClient,
  name: string,
): Promise<{ id: string; full: string } | null> {
  const q = (name ?? "").trim();
  if (q.length < 2) return null;
  const escaped = escapeIlike(q);
  const { data } = await admin
    .from("profiles")
    .select("id, first_name, last_name")
    .eq("role", "trainer")
    .or(`first_name.ilike.%${escaped}%,last_name.ilike.%${escaped}%`)
    .limit(5);
  const rows = (data ?? []) as Array<
    { id: string; first_name: string | null; last_name: string | null }
  >;
  if (rows.length === 0) return null;
  const target = normalise(q);
  const exact = rows.find((r) =>
    normalise(fullName(r.first_name, r.last_name)) === target
  );
  const picked = exact ?? rows[0];
  return {
    id: picked.id,
    full: fullName(picked.first_name, picked.last_name),
  };
}

/** Best-effort name → child id resolver. Returns null on no match. */
export async function findChildByName(
  admin: SupabaseClient,
  childName: string,
): Promise<{ id: string; full: string } | null> {
  const escaped = childName.trim().replace(/%/g, "\\%").replace(/_/g, "\\_");
  const { data } = await admin
    .from("children")
    .select("id, first_name, last_name")
    .or(`first_name.ilike.%${escaped}%,last_name.ilike.%${escaped}%`)
    .limit(5);
  const rows = (data ?? []) as Array<{
    id: string;
    first_name: string | null;
    last_name: string | null;
  }>;
  if (rows.length === 0) return null;
  const target = normalise(childName);
  const exact = rows.find((r) =>
    normalise(fullName(r.first_name, r.last_name)) === target
  );
  const picked = exact ?? rows[0];
  return {
    id: picked.id,
    full: fullName(picked.first_name, picked.last_name),
  };
}
