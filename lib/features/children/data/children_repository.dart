import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/child_row.dart';

// ── Lightweight model used by the add/edit form ───────────────────────────────

class Child {
  const Child({
    required this.id,
    this.firstName = '',
    this.lastName = '',
    this.birthDate,
    this.age,
    this.parentName,
    this.parentPhone,
    this.notes,
    this.isActive,
    this.paymentType = 'paid',
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
  final String paymentType;

  factory Child.fromMap(Map<String, dynamic> m) => Child(
        id: m['id'] as String,
        firstName: m['first_name'] as String? ?? '',
        lastName: m['last_name'] as String? ?? '',
        birthDate: m['birth_date'] != null
            ? DateTime.tryParse(m['birth_date'] as String)
            : null,
        age: (m['age'] as num?)?.toInt(),
        parentName: m['parent_name'] as String?,
        parentPhone: m['parent_phone'] as String?,
        notes: m['notes'] as String?,
        isActive: m['is_active'] as bool?,
        paymentType: (m['payment_type'] as String?) ?? 'paid',
      );
}

class ChildrenRepository {
  const ChildrenRepository(this._client);

  final SupabaseClient _client;

  // ── List with embedded workshops + last attendance ────────────────────────

  Future<List<ChildRow>> getAllWithWorkshops() async {
    final childData = await _client
        .from('children')
        .select(
            '*, workshop_enrollments!child_id(is_active, workshop_series!series_id(id, title, workshop_type, day_of_week, start_time, end_time, trainer_id, is_active, archived_at))')
        .order('last_name');

    // Latest attendance per child comes from the `child_latest_attendance`
    // view (DISTINCT ON child_id, ordered by workshop_date desc, marked_at
    // desc). This avoids fetching the full attendance table client-side.
    final attData = await _client
        .from('child_latest_attendance')
        .select('child_id, status, workshop_date');

    final lastAttMap = <String, ({String status, DateTime date})>{};
    for (final row in attData as List) {
      final map = row as Map<String, dynamic>;
      final childId = map['child_id'] as String?;
      final workshopDateStr = map['workshop_date'] as String?;
      if (childId == null || workshopDateStr == null) continue;
      lastAttMap[childId] = (
        status: (map['status'] as String?) ?? '',
        date: DateTime.parse(workshopDateStr),
      );
    }

    return (childData as List).map((e) {
      final map = e as Map<String, dynamic>;
      final id = map['id'] as String;
      final att = lastAttMap[id];
      return ChildRow.fromMap(map,
          lastAttStatus: att?.status, lastAttDate: att?.date);
    }).toList();
  }

  // ── Single child row (for details page) ──────────────────────────────────

  Future<ChildRow?> getRowById(String id) async {
    final data = await _client
        .from('children')
        .select(
            '*, workshop_enrollments!child_id(is_active, workshop_series!series_id(id, title, workshop_type, day_of_week, start_time, end_time, trainer_id, is_active, archived_at))')
        .eq('id', id)
        .maybeSingle();
    if (data == null) return null;

    final attData = await _client
        .from('workshop_details')
        .select('child_id, attendance_status, workshop_date')
        .eq('child_id', id)
        .not('attendance_status', 'is', null)
        .order('workshop_date', ascending: false)
        .limit(1)
        .maybeSingle();

    return ChildRow.fromMap(
      data,
      lastAttStatus: attData?['attendance_status'] as String?,
      lastAttDate: attData != null
          ? DateTime.parse(attData['workshop_date'] as String)
          : null,
    );
  }

  // ── Count-only query: present attendances in a date range ────────────────
  //
  // Backed by Postgres function `count_weekly_present_attendance(p_from, p_to)`
  // which returns COUNT(*)::int over `workshop_details` filtered to
  // attendance_status='present'. Avoids fetching row data just to call .length.
  Future<int> countWeeklyPresentAttendances({
    required String from,
    required String to,
  }) async {
    final result = await _client.rpc(
      'count_weekly_present_attendance',
      params: {
        'p_from': from,
        'p_to': to,
      },
    );
    return (result as num?)?.toInt() ?? 0;
  }

  // ── Simple CRUD ───────────────────────────────────────────────────────────

  Future<List<Child>> getAll() async {
    final data =
        await _client.from('children').select().order('last_name');
    return (data as List)
        .map((e) => Child.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<Child?> getById(String id) async {
    final data = await _client
        .from('children')
        .select()
        .eq('id', id)
        .maybeSingle();
    return data != null ? Child.fromMap(data) : null;
  }

  Future<void> create(Map<String, dynamic> data) async {
    await _client.from('children').insert(data);
  }

  Future<void> update(String id, Map<String, dynamic> data) async {
    await _client.from('children').update(data).eq('id', id);
  }

  /// Soft-deactivates a child (archive flow).
  ///
  /// Sets `children.is_active = false` AND deactivates every active
  /// `workshop_enrollments` row for the child so the child drops out of all
  /// active rosters immediately. Historical data — attendance, payment
  /// cycles, notifications, demo conversions — is preserved untouched.
  ///
  /// Reverse with [reactivateChild]; enrollments are **not** re-activated
  /// automatically — admin must add the child back to each workshop.
  Future<void> deactivateChild(String childId) async {
    await _client
        .from('children')
        .update({'is_active': false})
        .eq('id', childId);
    await _client
        .from('workshop_enrollments')
        .update({'is_active': false})
        .eq('child_id', childId)
        .eq('is_active', true);
  }

  /// Reactivates a previously deactivated child.
  ///
  /// Only flips `children.is_active = true`. Workshop enrollments stay
  /// deactivated by design — admin re-enrolls the child manually into the
  /// workshops they should rejoin.
  Future<void> reactivateChild(String childId) async {
    await _client
        .from('children')
        .update({'is_active': true})
        .eq('id', childId);
  }

  /// Permanently deletes a child and every dependent row.
  ///
  /// Backed by the `delete_child_completely` Postgres RPC
  /// (SECURITY DEFINER, admin-only). The RPC clears
  /// `demo_workshops.converted_child_id` references, then deletes from
  /// `workshop_enrollments`, `attendance`, `payment_cycles`,
  /// `notifications` (related_child_id), the legacy `workshop_children` /
  /// `payments` / `child_progress` tables if they exist, and finally the
  /// `children` row itself — all inside a single transaction with a row
  /// lock on the child.
  ///
  /// Returns the deleted child id (echo from the RPC).
  Future<String> deletePermanently(String childId) async {
    final result = await _client.rpc(
      'delete_child_completely',
      params: {'p_child_id': childId},
    );
    return result as String;
  }
}
