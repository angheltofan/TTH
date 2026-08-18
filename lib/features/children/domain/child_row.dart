import 'child_workshop_summary.dart';

/// A child row enriched with their enrolled workshops and last attendance info.
/// Used for the children list page.
class ChildRow {
  const ChildRow({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.birthDate,
    this.age,
    this.parentName,
    this.parentPhone,
    this.notes,
    this.isActive,
    this.paymentType = 'paid',
    required this.workshops,
    this.lastAttStatus,
    this.lastAttDate,
  });

  final String id;
  final String firstName;
  final String lastName;
  final DateTime? birthDate;
  final int? age;
  final String? parentName;
  final String? parentPhone;
  final String? notes;
  final bool? isActive;

  /// 'paid' or 'free'. Defaults to 'paid' when the column is unavailable.
  final String paymentType;
  final List<ChildWorkshopSummary> workshops;

  /// Most-recent recorded attendance status: 'present', 'absent', 'motivated'
  final String? lastAttStatus;
  final DateTime? lastAttDate;

  bool get isFreeParticipant => paymentType == 'free';

  String get fullName => '$firstName $lastName';

  factory ChildRow.fromMap(
    Map<String, dynamic> map, {
    String? lastAttStatus,
    DateTime? lastAttDate,
  }) {
    // Parse embedded workshop_enrollments → workshop_series.
    // Filters applied:
    //   - enrollment must be active
    //   - the underlying workshop_series must also be active + not
    //     archived; otherwise the child ends up "enrolled" in a dead
    //     workshop and the archived series leaks into filter dropdowns
    //     and chips (Modelare 3D bug reported 2026-08-18).
    // Unique constraint on (series_id, child_id) → no dedup needed.
    final weList = map['workshop_enrollments'] as List? ?? [];
    final workshops = weList
        .map((item) {
          final e = item as Map<String, dynamic>;
          if ((e['is_active'] as bool?) != true) return null;
          final ws = e['workshop_series'] as Map<String, dynamic>?;
          if (ws == null) return null;
          if ((ws['is_active'] as bool?) == false) return null;
          if (ws['archived_at'] != null) return null;
          return ChildWorkshopSummary.fromMap(ws);
        })
        .whereType<ChildWorkshopSummary>()
        .toList();

    return ChildRow(
      id: map['id'] as String,
      firstName: (map['first_name'] as String?) ?? '',
      lastName: (map['last_name'] as String?) ?? '',
      birthDate: map['birth_date'] != null
          ? DateTime.parse(map['birth_date'] as String)
          : null,
      age: (map['age'] as num?)?.toInt(),
      parentName: map['parent_name'] as String?,
      parentPhone: map['parent_phone'] as String?,
      notes: map['notes'] as String?,
      isActive: map['is_active'] as bool?,
      paymentType: (map['payment_type'] as String?) ?? 'paid',
      workshops: workshops,
      lastAttStatus: lastAttStatus,
      lastAttDate: lastAttDate,
    );
  }
}
