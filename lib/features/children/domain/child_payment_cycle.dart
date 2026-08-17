/// A payment cycle record from the `payment_cycles` table.
class ChildPaymentCycle {
  const ChildPaymentCycle({
    required this.id,
    required this.childId,
    this.seriesId,
    this.seriesTitle,
    this.periodStart,
    this.periodEnd,
    this.sessionsCount,
    this.status,
    this.paidAt,
    this.confirmedBy,
    this.paymentMethod,
    this.notes,
    this.createdAt,
  });

  final String id;
  final String childId;
  /// The workshop series this cycle belongs to (added 2026-08-20).
  /// Nullable for legacy rows that could not be safely mapped during
  /// the migration; new rows always have it set.
  final String? seriesId;
  /// Human-readable series title, joined from `workshop_series.title`.
  /// Nullable when the row was fetched without the join.
  final String? seriesTitle;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final int? sessionsCount;

  /// 'paid', 'due', 'overdue', 'cancelled'
  final String? status;
  final DateTime? paidAt;
  final String? confirmedBy;

  /// 'pos' or 'op', or null for legacy records.
  final String? paymentMethod;

  /// Optional free-text note — used as fallback to infer method for old records.
  final String? notes;
  final DateTime? createdAt;

  factory ChildPaymentCycle.fromMap(Map<String, dynamic> map) {
    // When fetched with `.select('*, workshop_series!series_id(title)')`
    // the embedded object comes under the key `workshop_series`.
    final embed = map['workshop_series'] as Map<String, dynamic>?;
    return ChildPaymentCycle(
        id: (map['id'] as String?) ?? '',
        childId: (map['child_id'] as String?) ?? '',
        seriesId: map['series_id'] as String?,
        seriesTitle: embed?['title'] as String?,
        periodStart: map['period_start'] != null
            ? DateTime.tryParse(map['period_start'] as String)
            : null,
        periodEnd: map['period_end'] != null
            ? DateTime.tryParse(map['period_end'] as String)
            : null,
        sessionsCount: (map['sessions_count'] as num?)?.toInt(),
        status: map['status'] as String?,
        paidAt: map['paid_at'] != null
            ? DateTime.tryParse(map['paid_at'] as String)
            : null,
        confirmedBy: map['confirmed_by'] as String?,
        paymentMethod: map['payment_method'] as String?,
        notes: map['notes'] as String?,
        createdAt: map['created_at'] != null
            ? DateTime.tryParse(map['created_at'] as String)
            : null,
      );
  }
}
