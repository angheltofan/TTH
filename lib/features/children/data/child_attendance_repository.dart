import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/child_row.dart';

class ChildAttendanceRepository {
  const ChildAttendanceRepository(this._client);

  final SupabaseClient _client;

  // ── Trainer-scoped children list ──────────────────────────────────────────

  Future<List<ChildRow>> getAllForTrainer(String trainerId) async {
    // Step 1: series IDs owned by this trainer.
    final seriesData = await _client
        .from('workshop_series')
        .select('id')
        .eq('trainer_id', trainerId);
    final seriesIds =
        (seriesData as List).map((r) => r['id'] as String).toList();
    if (seriesIds.isEmpty) return [];

    // Step 2: active child IDs enrolled in those series.
    final weData = await _client
        .from('workshop_enrollments')
        .select('child_id')
        .inFilter('series_id', seriesIds)
        .eq('is_active', true);
    final childIds = (weData as List)
        .map((row) => row['child_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    if (childIds.isEmpty) return [];

    // Step 3: children with their enrollments (same join as getAllWithWorkshops).
    final childData = await _client
        .from('children')
        .select(
            '*, workshop_enrollments!child_id(is_active, workshop_series!series_id(id, title, workshop_type, day_of_week, start_time, end_time, trainer_id))')
        .inFilter('id', childIds)
        .order('last_name');

    // Step 4: last attendance per child for this trainer (limited).
    final attData = await _client
        .from('workshop_details')
        .select('child_id, attendance_status, workshop_date')
        .eq('trainer_id', trainerId)
        .not('attendance_status', 'is', null)
        .order('workshop_date', ascending: false)
        .limit(500);

    final lastAttMap = <String, ({String status, DateTime date})>{};
    for (final row in (attData as List)) {
      final childId = row['child_id'] as String?;
      if (childId != null && !lastAttMap.containsKey(childId)) {
        lastAttMap[childId] = (
          status: row['attendance_status'] as String,
          date: DateTime.parse(row['workshop_date'] as String),
        );
      }
    }

    return (childData as List).map((e) {
      final map = e as Map<String, dynamic>;
      final id = map['id'] as String;
      final att = lastAttMap[id];
      return ChildRow.fromMap(map,
          lastAttStatus: att?.status, lastAttDate: att?.date);
    }).toList();
  }

  // ── Full attendance history (all records) ────────────────────────────────

  Future<List<Map<String, dynamic>>> getAttendanceHistoryFull(
      String childId) async {
    final data = await _client
        .from('attendance')
        .select(
            'id, child_id, scheduled_workshop_id, status, observation, marked_at, marked_by,'
            ' scheduled_workshops!scheduled_workshop_id(id, title, workshop_type, workshop_date, day_of_week, start_time, end_time),'
            ' profiles!marked_by(first_name, last_name)')
        .eq('child_id', childId);
    return _sortByWorkshopDate((data as List).cast<Map<String, dynamic>>());
  }

  Future<List<Map<String, dynamic>>> getAttendanceHistoryForTrainerFull(
      String childId, String trainerId) async {
    final wsData = await _client
        .from('scheduled_workshops')
        .select('id')
        .eq('trainer_id', trainerId);
    final wsIds = (wsData as List).map((r) => r['id'] as String).toList();
    if (wsIds.isEmpty) return [];

    final data = await _client
        .from('attendance')
        .select(
            'id, child_id, scheduled_workshop_id, status, observation, marked_at, marked_by,'
            ' scheduled_workshops!scheduled_workshop_id(id, title, workshop_type, workshop_date, day_of_week, start_time, end_time),'
            ' profiles!marked_by(first_name, last_name)')
        .eq('child_id', childId)
        .inFilter('scheduled_workshop_id', wsIds);
    return _sortByWorkshopDate((data as List).cast<Map<String, dynamic>>());
  }

  // Legacy view-backed methods removed 2026-08-22 (getActivityHistory,
  // getCurrentCycleSummary, getCurrentCycleActivity). Their underlying
  // views (child_activity_history, child_current_cycle_summary,
  // child_current_cycle_activity) were dropped by migration 20260822.

  // ── Private helpers ──────────────────────────────────────────────────────

  List<Map<String, dynamic>> _sortByWorkshopDate(
      List<Map<String, dynamic>> rows) {
    rows.sort((a, b) {
      final wsA = a['scheduled_workshops'] as Map<String, dynamic>?;
      final wsB = b['scheduled_workshops'] as Map<String, dynamic>?;
      final dateA = wsA?['workshop_date'] as String? ?? '';
      final dateB = wsB?['workshop_date'] as String? ?? '';
      final cmp = dateB.compareTo(dateA);
      if (cmp != 0) return cmp;
      final timeA = wsA?['start_time'] as String? ?? '';
      final timeB = wsB?['start_time'] as String? ?? '';
      return timeB.compareTo(timeA);
    });
    return rows;
  }


}
