import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/child_current_status_row.dart';
import '../domain/child_model.dart';
import '../domain/child_payment_cycle.dart';

/// Data layer for the Child Details page.
/// Uses: children, attendance, scheduled_workshops, profiles,
///       child_current_status, child_current_status_rows,
///       child_payment_status_rows, payment_cycles.
class ChildDetailsRepository {
  const ChildDetailsRepository(this._client);

  final SupabaseClient _client;

  // ── Fetch a single child by ID ────────────────────────────────────────────

  Future<ChildModel?> fetchChildById(String childId) async {
    final data = await _client
        .from('children')
        .select(
            'id, first_name, last_name, birth_date, '
            'parent_name, parent_phone, notes, is_active, payment_type')
        .eq('id', childId)
        .maybeSingle();
    return data != null ? ChildModel.fromMap(data) : null;
  }

  // ── ALL non-archived attendance for a child (series-aware) ───────────────
  //
  // Returns every non-archived attendance row for the child with resolved
  // series info + payment_cycle_id. The UI does the "current cycle" vs
  // "belongs to a closed cycle" classification chronologically per series
  // — this is the ONLY source of truth for both CurrentStatusCard and
  // PaymentStatusCard because:
  //
  //   • PRESENT rows in a closed cycle carry `payment_cycle_id = cycle.id`
  //     (financial linkage)
  //   • ABSENT rows always carry `payment_cycle_id = NULL`, so relying on
  //     this column to decide "current cycle membership" leaks historical
  //     absences into the current block (bug reported 2026-08-20).
  //
  // For free participants the server never creates payment_cycles rows
  // (BEFORE INSERT trigger blocks them), so a chronological windowing
  // pass is applied client-side per series so the UI shows the same
  // "X / 4 → reset to 0 / 4" pattern without a financial cycle.
  Future<List<ChildCurrentStatusRow>> fetchChildCurrentStatusRows(
      String childId, {
    bool isFreeParticipant = false,
  }) async {
    final data = await _client
        .from('attendance')
        .select(
            'id, child_id, status, observation, payment_cycle_id, '
            'scheduled_workshops!scheduled_workshop_id('
            'title, workshop_date, day_of_week, start_time, end_time, '
            'series_id, recurring_series_id, '
            'workshop_series!series_id(title))')
        .eq('child_id', childId)
        .eq('is_archived', false);

    final rows = (data as List).map((e) {
      final map = e as Map<String, dynamic>;
      final sw = map['scheduled_workshops'] as Map<String, dynamic>?;
      final wsEmbed = sw?['workshop_series'] as Map<String, dynamic>?;
      final resolvedSeriesId = (sw?['series_id'] as String?) ??
          (sw?['recurring_series_id'] as String?);
      return ChildCurrentStatusRow(
        childId: (map['child_id'] as String?) ?? '',
        attendanceId: map['id'] as String?,
        workshopTitle: sw?['title'] as String?,
        workshopDate: sw?['workshop_date'] != null
            ? DateTime.tryParse(sw!['workshop_date'] as String)
            : null,
        dayOfWeek: sw?['day_of_week'] as String?,
        startTime: sw?['start_time'] as String?,
        endTime: sw?['end_time'] as String?,
        attendanceStatus: map['status'] as String?,
        observation: map['observation'] as String?,
        seriesId: resolvedSeriesId,
        seriesTitle: wsEmbed?['title'] as String?,
        paymentCycleId: map['payment_cycle_id'] as String?,
      );
    }).toList();

    // Sort by workshop date asc, then start_time asc (client-side).
    rows.sort((a, b) {
      final dateCmp = (a.workshopDate ?? DateTime(0))
          .compareTo(b.workshopDate ?? DateTime(0));
      if (dateCmp != 0) return dateCmp;
      return (a.startTime ?? '').compareTo(b.startTime ?? '');
    });

    if (!isFreeParticipant) return rows;
    // Free children: no cycles exist server-side, so window the rows
    // per series to emulate the same "current block" semantics.
    return _windowToCurrentFourPresentBlockPerSeries(rows);
  }

  /// Free-participant windowing, per series. For each series, keeps only
  /// the rows AFTER the most recent 4th-PRESENT boundary, so the UI shows
  /// the same "current block" resetting to 0/4 as paid children get from
  /// server-side payment_cycles. Applied per-series so a child enrolled
  /// in multiple free workshops sees independent counters.
  List<ChildCurrentStatusRow> _windowToCurrentFourPresentBlockPerSeries(
      List<ChildCurrentStatusRow> rows) {
    // Group by seriesId (nullable → group under empty key so the row
    // isn't lost).
    final bySeries = <String, List<ChildCurrentStatusRow>>{};
    for (final r in rows) {
      final key = r.seriesId ?? '';
      bySeries.putIfAbsent(key, () => []).add(r);
    }
    final out = <ChildCurrentStatusRow>[];
    for (final entry in bySeries.entries) {
      final seriesRows = entry.value; // already sorted
      var presentCount = 0;
      var blockStart = 0;
      for (var i = 0; i < seriesRows.length; i++) {
        if (seriesRows[i].attendanceStatus == 'present') {
          presentCount += 1;
          if (presentCount == 4) {
            blockStart = i + 1;
            presentCount = 0;
          }
        }
      }
      if (blockStart < seriesRows.length) {
        out.addAll(seriesRows.sublist(blockStart));
      }
    }
    // Re-sort combined output to keep chronological order across series.
    out.sort((a, b) {
      final d = (a.workshopDate ?? DateTime(0))
          .compareTo(b.workshopDate ?? DateTime(0));
      if (d != 0) return d;
      return (a.startTime ?? '').compareTo(b.startTime ?? '');
    });
    return out;
  }

  // ── Payment cycles from payment_cycles table ──────────────────────────────

  Future<List<ChildPaymentCycle>> fetchPaymentCycles(
      String childId) async {
    // Join workshop_series so the model carries seriesTitle for UI grouping.
    // Cycles created before migration 20260820 may still have series_id NULL
    // (only for legacy paid_advance rows that couldn't be safely mapped) —
    // the model tolerates it as null.
    final data = await _client
        .from('payment_cycles')
        .select('*, workshop_series!series_id(title)')
        .eq('child_id', childId)
        .order('period_start', ascending: false);
    return (data as List)
        .map((r) =>
            ChildPaymentCycle.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  // ── Confirm payment for a cycle ──────────────────────────────────────────

  Future<void> confirmPayment({
    required bool isStaff,
    required String cycleId,
    required String userId,
    required String paymentMethod,
    String notes = '',
  }) async {
    if (!isStaff) throw StateError('Unauthorized role');
    await _client
        .from('payment_cycles')
        .update({
          'status': 'paid',
          'paid_at': DateTime.now().toUtc().toIso8601String(),
          'confirmed_by': userId,
          'payment_method': paymentMethod, // 'pos' or 'op'
          if (notes.isNotEmpty) 'notes': notes,
        })
        .eq('id', cycleId);
  }

  // ── Create or update advance payment cycle ───────────────────────────────
  // Backed by the `upsert_advance_payment` Postgres RPC (SECURITY INVOKER),
  // which performs an INSERT … ON CONFLICT (child_id) WHERE status='paid_advance'
  // DO UPDATE. The partial unique index
  // `uq_payment_cycles_one_advance_per_child` guarantees at most one
  // paid_advance cycle per child even under concurrent calls from multiple
  // devices.
  //
  // The RPC derives `confirmed_by` from `auth.uid()` server-side and gates
  // by `is_admin() OR is_trainer_for_child(p_child_id)` (Phase 6C-2). The
  // client therefore no longer passes a user id.
  //
  // Does NOT set payment_cycle_id on attendance rows.
  // Rows stay in child_current_status_rows until the cycle closes at 4 presents.

  Future<void> markAdvancePayment({
    required String childId,
    required String seriesId,
    required String paymentMethod,
    String notes = '',
  }) async {
    await _client.rpc(
      'upsert_advance_payment',
      params: {
        'p_child_id': childId,
        'p_series_id': seriesId,
        'p_payment_method': paymentMethod, // 'pos' or 'op'
        'p_notes': notes.isEmpty ? null : notes,
      },
    );
  }
}
