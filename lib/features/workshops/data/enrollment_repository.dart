import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/utils/weekday_utils.dart';
import '../domain/series_enrolled_child.dart';
import '../domain/workshop_series.dart';

class EnrollmentRepository {
  const EnrollmentRepository(this._client);

  final SupabaseClient _client;

  // ── Workshop Series ────────────────────────────────────────────────────────

  /// Fetches all active workshop series. Does NOT join profiles —
  /// this keeps the query simple and avoids silent row exclusion when
  /// [trainer_id] is NULL (PostgREST inner-joins on FK hints by default).
  Future<List<WorkshopSeries>> fetchActiveWorkshopSeries() async {
    final data = await _client
        .from('workshop_series')
        .select(
            'id, title, workshop_type, day_of_week, start_time, end_time, '
            'trainer_id, notes, is_active')
        .eq('is_active', true);
    return ((data as List)
        .map((e) => WorkshopSeries.fromMap(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => compareByWeekday(
            dayA: a.dayOfWeek,
            dayB: b.dayOfWeek,
            timeA: a.startTime,
            timeB: b.startTime,
            titleA: a.title,
            titleB: b.title,
          )));
  }

  Future<WorkshopSeries?> fetchWorkshopSeriesById(String id) async {
    final data = await _client
        .from('workshop_series')
        .select(
            'id, title, workshop_type, day_of_week, start_time, end_time, '
            'trainer_id, notes, is_active, '
            'profiles!trainer_id(first_name, last_name)')
        .eq('id', id)
        .maybeSingle();
    return data != null ? WorkshopSeries.fromMap(data) : null;
  }

  // ── Child → Series ────────────────────────────────────────────────────────

  /// Active series a child is enrolled in.
  /// Does NOT join profiles — avoids silent row exclusion when trainer_id IS NULL.
  Future<List<WorkshopSeries>> fetchChildWorkshopSeries(
      String childId) async {
    final data = await _client
        .from('workshop_enrollments')
        .select(
            'workshop_series!series_id('
            'id, title, workshop_type, day_of_week, start_time, end_time, '
            'trainer_id, notes, is_active, archived_at)')
        .eq('child_id', childId)
        .eq('is_active', true);

    return ((data as List)
        .map((e) {
          final ws = (e as Map<String, dynamic>)['workshop_series']
              as Map<String, dynamic>?;
          if (ws == null) return null;
          // Skip enrollments whose parent series has been archived.
          // Defensive filter: the migration should have deactivated
          // these enrollments already, but manual DB writes / future
          // regressions could re-introduce the drift.
          if ((ws['is_active'] as bool?) == false) return null;
          if (ws['archived_at'] != null) return null;
          return WorkshopSeries.fromMap(ws);
        })
        .whereType<WorkshopSeries>()
        .toList()
      ..sort((a, b) => compareByWeekday(
            dayA: a.dayOfWeek,
            dayB: b.dayOfWeek,
            timeA: a.startTime,
            timeB: b.startTime,
            titleA: a.title,
            titleB: b.title,
          )));
  }

  /// Active workshop series that [childId] is NOT yet enrolled in.
  ///
  /// Reads [workshop_enrollments] to get already-assigned series ids, then
  /// returns all active [workshop_series] rows that are not in that set.
  /// If the enrollment read fails (RLS not configured), shows all active series
  /// so the admin can still attempt to enroll.
  Future<List<WorkshopSeries>> fetchAvailableWorkshopSeriesForChild(
      String childId) async {
    var assignedIds = <String>{};
    try {
      final enrolled = await _client
          .from('workshop_enrollments')
          .select('series_id')
          .eq('child_id', childId)
          .eq('is_active', true);
      assignedIds = (enrolled as List)
          .map((e) =>
              (e as Map<String, dynamic>)['series_id'] as String)
          .toSet();
    } catch (_) {
      // Enrollment table unreadable — fall back to showing all series.
    }

    final all = await _client
        .from('workshop_series')
        .select(
            'id, title, workshop_type, day_of_week, start_time, end_time, '
            'trainer_id, notes, is_active')
        .eq('is_active', true)
        .order('title');

    return ((all as List)
        .cast<Map<String, dynamic>>()
        .where((s) => !assignedIds.contains(s['id'] as String))
        .map((s) => WorkshopSeries.fromMap(s))
        .toList()
      ..sort((a, b) => compareByWeekday(
            dayA: a.dayOfWeek,
            dayB: b.dayOfWeek,
            timeA: a.startTime,
            timeB: b.startTime,
            titleA: a.title,
            titleB: b.title,
          )));
  }

  // ── Series → Children ─────────────────────────────────────────────────────

  /// Active children enrolled in a workshop series, sorted by name.
  Future<List<SeriesEnrolledChild>> fetchWorkshopSeriesChildren(
      String seriesId) async {
    final data = await _client
        .from('workshop_enrollments')
        .select(
            'id, child_id, is_active, '
            'children!child_id(first_name, last_name, is_active)')
        .eq('series_id', seriesId)
        .eq('is_active', true);

    final rows = (data as List)
        .map((e) =>
            SeriesEnrolledChild.fromMap(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.fullName.compareTo(b.fullName));
    return rows;
  }

  /// Children who are active and NOT already enrolled (active) in [seriesId].
  /// If the enrollment read fails (e.g. RLS not configured), falls back to
  /// returning all active children.
  Future<List<Map<String, dynamic>>> fetchAvailableChildrenForSeries(
      String seriesId) async {
    var enrolledIds = <String>{};
    try {
      final enrolled = await _client
          .from('workshop_enrollments')
          .select('child_id')
          .eq('series_id', seriesId)
          .eq('is_active', true);
      enrolledIds = (enrolled as List)
          .map((e) => (e as Map<String, dynamic>)['child_id'] as String)
          .toSet();
    } catch (_) {
      // If we can't read enrollments (RLS not configured), show all children
      // so the admin can still attempt to enroll them.
    }

    final all = await _client
        .from('children')
        .select('id, first_name, last_name')
        .eq('is_active', true)
        .order('last_name');

    return (all as List)
        .cast<Map<String, dynamic>>()
        .where((c) => !enrolledIds.contains(c['id'] as String))
        .toList();
  }

  // ── Enrollment mutations ──────────────────────────────────────────────────

  /// Ensures a `workshop_series` row exists for [seriesId].
  ///
  /// Workshops created before the series-upsert fix may have a series
  /// reference in `scheduled_workshops` (either `series_id` or the legacy
  /// `recurring_series_id`) but no corresponding row in `workshop_series`.
  /// This method backfills it on demand by reading metadata from any
  /// matching scheduled session.
  Future<void> _ensureSeriesExists(String seriesId) async {
    final existing = await _client
        .from('workshop_series')
        .select('id')
        .eq('id', seriesId)
        .maybeSingle();
    if (existing != null) return;

    // Fetch metadata from an existing session for this series, matching
    // either the canonical `series_id` column or the legacy
    // `recurring_series_id` column.
    final session = await _client
        .from('scheduled_workshops')
        .select(
            'title, workshop_type, day_of_week, start_time, end_time, '
            'trainer_id, notes, is_active')
        .or('series_id.eq.$seriesId,recurring_series_id.eq.$seriesId')
        .limit(1)
        .maybeSingle();
    if (session == null) return;

    if (kDebugMode) {
      debugPrint('[Enrollment] backfilling workshop_series id=$seriesId');
    }
    await _client.from('workshop_series').upsert({
      'id': seriesId,
      'title': session['title'],
      'workshop_type': session['workshop_type'],
      'day_of_week': session['day_of_week'],
      'start_time': session['start_time'],
      'end_time': session['end_time'],
      'trainer_id': session['trainer_id'],
      'notes': session['notes'],
      'is_active': session['is_active'] ?? true,
    });
  }

  /// Enrolls a child in a workshop series.
  ///
  /// Uses INSERT first. On a unique-constraint violation (duplicate row that
  /// may be inactive), falls back to UPDATE so we only need the INSERT RLS
  /// policy plus a separate UPDATE policy — rather than the combined
  /// ON CONFLICT DO UPDATE that [upsert] requires.
  Future<void> enrollChildInWorkshopSeries(
      String childId, String seriesId,
      {required bool isStaff}) async {
    if (!isStaff) throw StateError('Unauthorized role');
    if (kDebugMode) {
      debugPrint('[Enrollment] enroll child=$childId series=$seriesId');
    }
    await _ensureSeriesExists(seriesId);
    try {
      await _client.from('workshop_enrollments').insert({
        'child_id': childId,
        'series_id': seriesId,
        'is_active': true,
      });
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // Row already exists (possibly inactive) — re-activate it.
        await _client
            .from('workshop_enrollments')
            .update({'is_active': true})
            .eq('child_id', childId)
            .eq('series_id', seriesId);
      } else {
        rethrow;
      }
    }
  }

  /// Bulk-enrolls multiple children by calling [enrollChildInWorkshopSeries]
  /// for each, so the insert-then-update fallback applies to every child.
  Future<void> enrollChildrenInWorkshopSeries(
      String seriesId, List<String> childIds,
      {required bool isStaff}) async {
    if (!isStaff) throw StateError('Unauthorized role');
    for (final childId in childIds) {
      await enrollChildInWorkshopSeries(childId, seriesId,
          isStaff: isStaff);
    }
  }

  Future<void> removeChildFromWorkshopSeries(
      String childId, String seriesId) async {
    if (kDebugMode) {
      debugPrint('[Enrollment] remove child=$childId from series=$seriesId');
    }
    await _client
        .from('workshop_enrollments')
        .update({'is_active': false})
        .eq('child_id', childId)
        .eq('series_id', seriesId);
  }

  /// Deactivates a workshop series and all its future scheduled sessions.
  /// Existing enrollment and attendance data are preserved.
  ///
  /// The scheduled_workshops filter matches both the canonical `series_id`
  /// column and the legacy `recurring_series_id` column so older sessions
  /// that have not yet been backfilled are also deactivated.
  Future<void> deactivateSeries(String seriesId) async {
    if (kDebugMode) debugPrint('[Enrollment] deactivateSeries id=$seriesId');
    await _client
        .from('workshop_series')
        .update({'is_active': false})
        .eq('id', seriesId);
    final today = DateTime.now().toIso8601String().split('T').first;
    await _client
        .from('scheduled_workshops')
        .update({'is_active': false})
        .or('series_id.eq.$seriesId,recurring_series_id.eq.$seriesId')
        .gte('workshop_date', today);
  }
}
