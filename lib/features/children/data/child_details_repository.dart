import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/child_current_status.dart';
import '../domain/child_current_status_row.dart';
import '../domain/child_model.dart';
import '../domain/child_payment_cycle.dart';
import '../domain/child_payment_status_row.dart';

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

  // ── Current cycle summary from child_current_status view ──────────────────

  Future<ChildCurrentStatus?> fetchChildCurrentStatus(
      String childId) async {
    final data = await _client
        .from('child_current_status')
        .select()
        .eq('child_id', childId)
        .maybeSingle();
    return data != null ? ChildCurrentStatus.fromMap(data) : null;
  }

  // ── Current cycle rows directly from attendance table ────────────────────
  // Returns all rows where payment_cycle_id IS NULL and is_archived = false.
  // This bypasses the child_current_status_rows view which may apply a date
  // filter and miss older sessions still in the current open cycle.
  //
  // For free participants the server never creates payment_cycles rows (a
  // BEFORE INSERT trigger silently skips them), so EVERY unarchived
  // attendance row stays with `payment_cycle_id IS NULL` forever. Walking
  // through this set chronologically and grouping into blocks of four
  // presents gives the same visual "X / 4 → reset to 0 / 4" behavior as
  // the paid workflow without ever generating a financial obligation.

  Future<List<ChildCurrentStatusRow>> fetchChildCurrentStatusRows(
      String childId, {
    bool isFreeParticipant = false,
  }) async {
    final data = await _client
        .from('attendance')
        .select(
            'id, child_id, status, observation, '
            'scheduled_workshops!scheduled_workshop_id('
            'title, workshop_date, day_of_week, start_time, end_time, '
            'series_id, recurring_series_id, '
            'workshop_series!series_id(title))')
        .eq('child_id', childId)
        .filter('payment_cycle_id', 'is', null)
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
    return _windowToCurrentFourPresentBlock(rows);
  }

  /// Returns the trailing slice of [rows] that comes AFTER the most recent
  /// 4th-present row. Walks chronologically: every time the running count
  /// of `present` rows hits four, the in-progress block is discarded and
  /// the counter resets. Anything past the last discard is the "current
  /// open block" — exactly what the paid view shows once
  /// `payment_cycle_id` resets to NULL.
  List<ChildCurrentStatusRow> _windowToCurrentFourPresentBlock(
      List<ChildCurrentStatusRow> rows) {
    var presentCount = 0;
    var blockStart = 0;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].attendanceStatus == 'present') {
        presentCount += 1;
        if (presentCount == 4) {
          // The 4th present closes the block; the next row begins a fresh one.
          blockStart = i + 1;
          presentCount = 0;
        }
      }
    }
    if (blockStart >= rows.length) return const [];
    return rows.sublist(blockStart);
  }

  // ── Payment history rows from child_payment_status_rows view ──────────────

  Future<List<ChildPaymentStatusRow>> fetchChildPaymentStatusRows(
      String childId) async {
    final data = await _client
        .from('child_payment_status_rows')
        .select()
        .eq('child_id', childId)
        .order('workshop_date', ascending: false);
    return (data as List)
        .map((r) =>
            ChildPaymentStatusRow.fromMap(r as Map<String, dynamic>))
        .toList();
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
