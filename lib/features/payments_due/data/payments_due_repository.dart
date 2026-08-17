import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/payment_due_item.dart';

class PaymentsDueRepository {
  const PaymentsDueRepository(this._client);

  final SupabaseClient _client;

  /// Loads payment_cycles with status 'due' or 'overdue', applying defensive
  /// validation:
  ///   1. Child must still exist (not deleted).
  ///   2. sessions_count >= 4  OR  at least one linked attendance row exists.
  ///
  /// This prevents orphaned / test cycles from appearing on the overdue page.
  Future<List<PaymentDueItem>> getPaymentsDue() async {
    // ── Step 1: fetch due/overdue cycles with child info ──────────────────
    final data = await _client
        .from('payment_cycles')
        .select(
          'id, child_id, status, period_start, period_end, sessions_count, '
          'children!child_id(first_name, last_name, payment_type)',
        )
        .inFilter('status', ['due', 'overdue'])
        .order('period_start', ascending: false);

    // Discard orphaned cycles (child was deleted → children join is null) and
    // discard cycles belonging to free participants — they never appear on
    // the payments-due page even if a legacy trigger created a 'due' row.
    final all = (data as List)
        .cast<Map<String, dynamic>>()
        .where((e) {
          final child = e['children'];
          if (child is! Map<String, dynamic>) return false;
          return (child['payment_type'] as String? ?? 'paid') != 'free';
        })
        .toList();

    if (all.isEmpty) return [];

    // ── Step 2: partition by sessions_count ──────────────────────────────
    // Cycles with sessions_count >= 4 are considered valid without further
    // checking.  Cycles with fewer sessions need at least one attendance row
    // in the child_payment_status_rows view to be shown.
    final valid = <PaymentDueItem>[];
    final needsCheck = <Map<String, dynamic>>[];

    for (final e in all) {
      final count = (e['sessions_count'] as num?)?.toInt() ?? 0;
      if (count >= 4) {
        valid.add(PaymentDueItem.fromMap(e));
      } else {
        needsCheck.add(e);
      }
    }

    // ── Step 3: verify attendance rows for low-session cycles ─────────────
    if (needsCheck.isNotEmpty) {
      final checkIds =
          needsCheck.map((e) => e['id'] as String).toList();

      // Direct query on `attendance` — no longer via the legacy view
      // `child_payment_status_rows` (dropped 2026-08-21). We only need to
      // know which cycle ids have at least one linked attendance row.
      final rows = await _client
          .from('attendance')
          .select('payment_cycle_id')
          .inFilter('payment_cycle_id', checkIds)
          .not('payment_cycle_id', 'is', null);

      final cyclesWithRows = (rows as List)
          .cast<Map<String, dynamic>>()
          .map((e) => e['payment_cycle_id'] as String?)
          .whereType<String>()
          .toSet();

      for (final e in needsCheck) {
        if (cyclesWithRows.contains(e['id'] as String)) {
          valid.add(PaymentDueItem.fromMap(e));
        }
      }
    }

    // Re-sort after merging the two partitions (newest period_start first).
    valid.sort((a, b) {
      final da = a.periodStart ?? DateTime(0);
      final db = b.periodStart ?? DateTime(0);
      return db.compareTo(da);
    });

    return valid;
  }
}
