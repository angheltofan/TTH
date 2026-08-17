import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_client_provider.dart';
import '../data/child_details_repository.dart';
import '../domain/child_current_status_row.dart';
import '../domain/child_model.dart';
import '../domain/child_payment_cycle.dart';

// ── Repository ────────────────────────────────────────────────────────────────

final childDetailsRepositoryProvider =
    Provider<ChildDetailsRepository>((ref) {
  return ChildDetailsRepository(ref.watch(supabaseClientProvider));
});

// ── Child by ID ───────────────────────────────────────────────────────────────

final childByIdProvider =
    FutureProvider.autoDispose.family<ChildModel?, String>((ref, childId) {
  return ref
      .watch(childDetailsRepositoryProvider)
      .fetchChildById(childId);
});

// ── Attendance rows (all non-archived, series-aware) ─────────────────────────
//
// Since 2026-08-21 this provider returns every non-archived attendance row
// for the child with resolved series info + `paymentCycleId`. Cards do
// their own chronological classification: PRESENT rows linked to a cycle
// go inside that cycle's card; ABSENT rows (always payment_cycle_id NULL)
// are placed in whichever cycle their workshop_date falls into; unlinked
// rows AFTER the latest cycle boundary land in the current section.
//
// For free children the server never creates payment_cycles rows so the
// repository applies a per-series windowing pass to emulate the same
// "X / 4 → reset to 0 / 4" behaviour without a financial cycle.

final childCurrentStatusRowsProvider =
    FutureProvider.autoDispose.family<List<ChildCurrentStatusRow>, String>(
        (ref, childId) async {
  final child = await ref.watch(childByIdProvider(childId).future);
  final isFree = child?.isFreeParticipant ?? false;
  return ref
      .watch(childDetailsRepositoryProvider)
      .fetchChildCurrentStatusRows(childId, isFreeParticipant: isFree);
});

// ── Payment cycles (source of truth for card grouping) ──────────────────────

final childPaymentCyclesNewProvider =
    FutureProvider.autoDispose.family<List<ChildPaymentCycle>, String>(
        (ref, childId) {
  return ref
      .watch(childDetailsRepositoryProvider)
      .fetchPaymentCycles(childId);
});
