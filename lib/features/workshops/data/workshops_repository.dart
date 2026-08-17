import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../dashboard/domain/dashboard_workshop.dart';
import '../domain/scheduled_workshop.dart';
import '../domain/workshop_detail_row.dart';

/// Reason a cancel call refused. Lets the UI render a friendly message
/// without string-matching exceptions.
///
///   • [refusedByServer] — the UPDATE statement reached the server but
///     no row was actually modified. Typical causes: an RLS policy
///     denies UPDATE for this caller (the request still returns 2xx
///     but matches zero rows).
enum WorkshopCancelBlockedReason {
  refusedByServer,
}

/// Thrown by `archiveWorkshopOneOff` / `cancelWorkshopSeries` when the
/// safety gate refuses the archive OR when the UPDATE statement returned
/// successfully but did not modify the targeted row. Never thrown for
/// infrastructure errors (those propagate as `PostgrestException` /
/// generic errors).
class WorkshopCancelBlockedException implements Exception {
  const WorkshopCancelBlockedException(this.reason);
  final WorkshopCancelBlockedReason reason;

  @override
  String toString() =>
      'WorkshopCancelBlockedException(reason: ${reason.name})';
}

/// Pre-flight counts for an `cancelWorkshopSeries` call. The UI uses
/// these to phrase the confirmation dialog with concrete numbers of
/// sessions / attendance rows / enrolled children that will be
/// preserved as history.
///
/// After the archive-only refactor (2026-06-23), these numbers are no
/// longer "will be lost" — they are "will be preserved". The UI copy
/// was updated accordingly.
class SeriesCancellationImpact {
  const SeriesCancellationImpact({
    required this.scheduledCount,
    required this.attendanceCount,
    required this.enrollmentCount,
  });

  /// Number of `scheduled_workshops` rows that will be archived
  /// (marked `archived_at = now()`, hidden from active lists, retained
  /// for history).
  final int scheduledCount;

  /// Number of `attendance` rows referencing those scheduled workshops.
  /// These are **preserved** — the UI shows the number so operators know
  /// how much history is being retained.
  final int attendanceCount;

  /// Number of `workshop_enrollments` rows that will be flipped to
  /// `is_active = false` (kept as historical association records).
  final int enrollmentCount;
}

class WorkshopsRepository {
  const WorkshopsRepository(this._client);

  final SupabaseClient _client;

  /// Fetches all workshops with trainer name + children count from the
  /// `dashboard_workshops` view (no date filter — full list).
  Future<List<DashboardWorkshop>> getAllWorkshops() async {
    final data = await _client
        .from('dashboard_workshops')
        .select()
        .order('workshop_date')
        .order('start_time');
    final list = (data as List)
        .map((e) => DashboardWorkshop.fromMap(e as Map<String, dynamic>))
        .toList();

    // Sort client-side: chronological by actual date then start time.
    // The view may order day_of_week alphabetically in Romanian
    // (JOI < LUNI < MARTI < MIERCURI < VINERI) instead of Mon–Fri.
    list.sort((a, b) {
      final dateCmp = a.workshopDate.compareTo(b.workshopDate);
      if (dateCmp != 0) return dateCmp;
      return a.startTime.compareTo(b.startTime);
    });

    return list;
  }

  Future<List<ScheduledWorkshop>> getAll() async {
    final data = await _client
        .from('scheduled_workshops')
        .select()
        .order('workshop_date');
    return (data as List)
        .map((e) => ScheduledWorkshop.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  /// Loads children for a workshop occurrence using series-level enrollment.
  ///
  /// For recurring workshops: queries [workshop_enrollments] by `series_id`.
  /// The scheduled_workshops row is read with both `series_id` (canonical)
  /// and `recurring_series_id` (legacy fallback) so older rows that have
  /// not yet been backfilled still resolve to their series.
  /// Attendance is scoped to this specific occurrence only.
  Future<List<WorkshopDetailRow>> getDetails(String workshopId) async {
    // 1. Workshop metadata + trainer name
    final wsData = await _client
        .from('scheduled_workshops')
        .select(
          'id, title, workshop_type, workshop_date, day_of_week, '
          'start_time, end_time, trainer_id, series_id, recurring_series_id, '
          'is_active, profiles!trainer_id(first_name, last_name)',
        )
        .eq('id', workshopId)
        .maybeSingle();
    if (wsData == null) return [];

    // Prefer the canonical `series_id` column. Fall back to the legacy
    // `recurring_series_id` only if `series_id` is null (rows not yet
    // backfilled by the server-side migration / RPC).
    final seriesId = (wsData['series_id'] as String?) ??
        (wsData['recurring_series_id'] as String?);

    // 2. Children enrolled in this series via workshop_enrollments
    final childMap = <String, Map<String, dynamic>>{};
    if (seriesId != null) {
      final enrollmentData = await _client
          .from('workshop_enrollments')
          .select(
              'child_id, children!child_id(id, first_name, last_name)')
          .eq('series_id', seriesId)
          .eq('is_active', true);

      for (final row in (enrollmentData as List)) {
        final childId = row['child_id'] as String?;
        final child = row['children'] as Map<String, dynamic>?;
        if (childId != null &&
            child != null &&
            !childMap.containsKey(childId)) {
          childMap[childId] = child;
        }
      }
    }

    // 3. Attendance for THIS specific workshop occurrence
    final attData = await _client
        .from('attendance')
        .select('child_id, status, observation')
        .eq('scheduled_workshop_id', workshopId);

    final attMap = <String, Map<String, dynamic>>{};
    for (final row in (attData as List)) {
      attMap[row['child_id'] as String] = row as Map<String, dynamic>;
    }

    // 4. Trainer name
    String? trainerName;
    final profileRaw = wsData['profiles'];
    if (profileRaw is Map) {
      final fn = (profileRaw['first_name'] as String?) ?? '';
      final ln = (profileRaw['last_name'] as String?) ?? '';
      final full = '$fn $ln'.trim();
      if (full.isNotEmpty) trainerName = full;
    }

    // Shared workshop fields
    final wsId = wsData['id'] as String;
    final title = wsData['title'] as String;
    final workshopType = wsData['workshop_type'] as String;
    final workshopDate =
        DateTime.parse(wsData['workshop_date'] as String);
    final dayOfWeek = wsData['day_of_week'] as String;
    final startTime = wsData['start_time'] as String;
    final endTime = wsData['end_time'] as String;
    final trainerId = wsData['trainer_id'] as String;

    // 5. No enrolled children → return single metadata-only row
    if (childMap.isEmpty) {
      return [
        WorkshopDetailRow(
          workshopId: wsId,
          title: title,
          workshopType: workshopType,
          workshopDate: workshopDate,
          dayOfWeek: dayOfWeek,
          startTime: startTime,
          endTime: endTime,
          trainerId: trainerId,
          seriesId: seriesId,
          trainerName: trainerName,
        ),
      ];
    }

    return childMap.entries.map((entry) {
      final childId = entry.key;
      final child = entry.value;
      final att = attMap[childId];
      return WorkshopDetailRow(
        workshopId: wsId,
        title: title,
        workshopType: workshopType,
        workshopDate: workshopDate,
        dayOfWeek: dayOfWeek,
        startTime: startTime,
        endTime: endTime,
        trainerId: trainerId,
        seriesId: seriesId,
        trainerName: trainerName,
        childId: childId,
        childFirstName: child['first_name'] as String?,
        childLastName: child['last_name'] as String?,
        attendanceStatus: att?['status'] as String?,
        attendanceObservation: att?['observation'] as String?,
      );
    }).toList();
  }

  Future<ScheduledWorkshop?> getById(String id) async {
    final data = await _client
        .from('scheduled_workshops')
        .select()
        .eq('id', id)
        .maybeSingle();
    if (data == null) return null;
    return ScheduledWorkshop.fromMap(data);
  }

  /// Creates a scheduled workshop session.
  ///
  /// When [data] includes `is_recurring: true` and `series_id` (or the
  /// legacy alias `recurring_series_id`), a corresponding [workshop_series]
  /// row is upserted first so that [workshop_enrollments.series_id] FK
  /// constraints are satisfied. Both `series_id` and `recurring_series_id`
  /// are written to the scheduled_workshops row to keep the legacy column
  /// in sync for any view or RPC that has not yet migrated.
  Future<void> create(Map<String, dynamic> data) async {
    final payload = _normalizeSeriesIdKeys(data);
    final isRecurring = payload['is_recurring'] as bool? ?? false;
    final seriesId = payload['series_id'] as String?;

    if (isRecurring && seriesId != null) {
      if (kDebugMode) {
        debugPrint('[Workshops] upsert workshop_series id=$seriesId');
      }
      await _client.from('workshop_series').upsert({
        'id': seriesId,
        'title': payload['title'],
        'workshop_type': payload['workshop_type'],
        'day_of_week': payload['day_of_week'],
        'start_time': payload['start_time'],
        'end_time': payload['end_time'],
        'trainer_id': payload['trainer_id'],
        'notes': payload['notes'],
        'is_active': payload['is_active'] ?? true,
        // Persist the first-occurrence date so ensure_series_backfilled
        // can materialise every subsequent weekly session on demand.
        // Only set on genuinely new series (this branch runs only when
        // the form generated a fresh series_id).
        'start_date': payload['workshop_date'],
      });
    }

    if (kDebugMode) debugPrint('[Workshops] insert scheduled_workshop');
    await _client.from('scheduled_workshops').insert(payload);
  }

  Future<void> update(String id, Map<String, dynamic> data) async {
    // Mirror create(): when the update flips a workshop into recurring mode
    // (or heals a recurring row whose series_id was missing), upsert the
    // matching workshop_series first so workshop_enrollments.series_id FK
    // constraints can be satisfied. For ordinary recurring edits the form
    // does NOT pass series_id in the payload, so this branch is skipped and
    // only scheduled_workshops is touched.
    final payload = _normalizeSeriesIdKeys(data);
    final isRecurring = payload['is_recurring'] as bool? ?? false;
    final seriesId = payload['series_id'] as String?;

    if (isRecurring && seriesId != null) {
      if (kDebugMode) {
        debugPrint('[Workshops] update: upsert workshop_series id=$seriesId');
      }
      await _client.from('workshop_series').upsert({
        'id': seriesId,
        'title': payload['title'],
        'workshop_type': payload['workshop_type'],
        'day_of_week': payload['day_of_week'],
        'start_time': payload['start_time'],
        'end_time': payload['end_time'],
        'trainer_id': payload['trainer_id'],
        'notes': payload['notes'],
        'is_active': payload['is_active'] ?? true,
      });
    }

    await _client.from('scheduled_workshops').update(payload).eq('id', id);
  }

  /// Returns a copy of [data] where the series identifier is mirrored into
  /// both `series_id` (canonical) and `recurring_series_id` (legacy) keys,
  /// so the underlying scheduled_workshops row keeps both columns in sync.
  ///
  /// If the caller only provided one of the two keys, the other is filled in.
  /// If neither key is present, the payload is returned unchanged.
  Map<String, dynamic> _normalizeSeriesIdKeys(Map<String, dynamic> data) {
    final newSeries = data['series_id'] as String?;
    final legacySeries = data['recurring_series_id'] as String?;
    final resolved = newSeries ?? legacySeries;
    if (resolved == null) return Map<String, dynamic>.from(data);

    final copy = Map<String, dynamic>.from(data);
    copy['series_id'] = resolved;
    copy['recurring_series_id'] = resolved;
    return copy;
  }

  /// Retained for callers that only want to remove a **draft** workshop
  /// row (never marked, never enrolled). The database FK from
  /// `attendance.scheduled_workshop_id` is RESTRICT / NO ACTION, so
  /// this call fails at the server if the row carries any history —
  /// which is exactly the guarantee we want. History-bearing workshops
  /// must go through [archiveWorkshopOneOff] instead.
  Future<void> delete(String id) async {
    await _client.from('scheduled_workshops').delete().eq('id', id);
  }

  /// Materialises weekly `scheduled_workshops` rows for [seriesId] from
  /// [fromDate] up to [toDate] (defaults to today). Delegates to the
  /// `backfill_series_sessions` RPC — idempotent, skips existing
  /// (series_id, workshop_date) pairs, tolerant of the Marți/Marti
  /// diacritic variants.
  ///
  /// Called after admin creates a recurring workshop with a past start
  /// date so the historical attendance calendar has real rows to attach
  /// attendance to. Returns the number of rows inserted.
  Future<int> backfillSeriesSessions({
    required String seriesId,
    required DateTime fromDate,
    DateTime? toDate,
  }) async {
    String dateOnly(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final res = await _client.rpc('backfill_series_sessions', params: {
      'p_series_id': seriesId,
      'p_from_date': dateOnly(fromDate),
      if (toDate != null) 'p_to_date': dateOnly(toDate),
    });
    if (res is int) return res;
    if (res is num) return res.toInt();
    return 0;
  }

  /// Updates all future active workshops that share the same series id,
  /// starting from [fromDate] (inclusive). Also syncs [workshop_series]
  /// metadata so enrollment and series pages reflect the new values.
  ///
  /// The scheduled_workshops filter uses an `.or()` clause to match rows
  /// where either `series_id` (canonical) or the legacy
  /// `recurring_series_id` equals the provided id, so legacy rows that
  /// have not yet been backfilled are still updated together with newer
  /// ones.
  Future<void> updateSeries({
    required String seriesId,
    required DateTime fromDate,
    required Map<String, dynamic> data,
  }) async {
    // Sync workshop_series row with the same fields that are relevant there.
    const seriesKeys = [
      'title', 'workshop_type', 'day_of_week',
      'start_time', 'end_time', 'trainer_id', 'notes',
    ];
    final seriesFields = <String, dynamic>{
      for (final k in seriesKeys)
        if (data.containsKey(k)) k: data[k],
    };
    if (seriesFields.isNotEmpty) {
      if (kDebugMode) {
        debugPrint('[Workshops] update workshop_series id=$seriesId');
      }
      await _client
          .from('workshop_series')
          .update(seriesFields)
          .eq('id', seriesId);
    }

    await _client
        .from('scheduled_workshops')
        .update(data)
        .or('series_id.eq.$seriesId,recurring_series_id.eq.$seriesId')
        .eq('is_active', true)
        .gte('workshop_date', fromDate.toIso8601String().split('T').first);
  }

  /// Cancels a **single** scheduled workshop row. Admin-only.
  ///
  /// The row is marked as archived — `archived_at = now()`,
  /// `archived_by = adminId`, `is_active = false`, plus an optional
  /// `archived_reason` free-text field. Attendance and enrollment rows
  /// remain untouched so child reports and history keep working.
  ///
  /// Works for both one-off workshops AND a single occurrence of a
  /// recurring series (rule 8: cancelling a single occurrence archives
  /// only that session, not the whole series). To archive the whole
  /// series, callers use [cancelWorkshopSeries] instead — that entry
  /// point is reachable from the edit page's "Cancel entire series"
  /// action, per the same rule.
  ///
  /// Refuses (with [WorkshopCancelBlockedException]) when the UPDATE
  /// matches zero rows but the row is still present server-side (e.g.
  /// RLS denial).
  Future<void> cancelWorkshopOneOff({
    required bool isAdmin,
    required String adminId,
    required String workshopId,
    String? reason,
  }) async {
    if (!isAdmin) throw StateError('Unauthorized role');
    if (kDebugMode) {
      debugPrint('[Workshops] cancelWorkshopOneOff id=$workshopId');
    }

    // Verified soft-archive.
    final updated = await _client
        .from('scheduled_workshops')
        .update({
          'archived_at': DateTime.now().toUtc().toIso8601String(),
          'archived_by': adminId,
          if (reason != null && reason.trim().isNotEmpty)
            'archived_reason': reason.trim(),
          'is_active': false,
        })
        .eq('id', workshopId)
        .select('id');
    if ((updated as List).isNotEmpty) return;

    // UPDATE affected zero rows — determine whether the row exists at
    // all (already gone → success from the UI's perspective) or the
    // server refused (RLS).
    final stillThere = await _client
        .from('scheduled_workshops')
        .select('id')
        .eq('id', workshopId)
        .limit(1);
    if ((stillThere as List).isNotEmpty) {
      throw const WorkshopCancelBlockedException(
        WorkshopCancelBlockedReason.refusedByServer,
      );
    }
  }

  /// Measures what an `cancelWorkshopSeries` call will touch. The UI
  /// uses these counts to phrase the confirmation dialog with concrete
  /// numbers of the history that will be **preserved**.
  Future<SeriesCancellationImpact> measureSeriesCancellationImpact({
    required String seriesId,
  }) async {
    // 1. All scheduled_workshops belonging to the series. Match both
    //    the canonical `series_id` and the legacy `recurring_series_id`
    //    column so older rows that haven't been backfilled are still
    //    discovered.
    final scheduled = await _client
        .from('scheduled_workshops')
        .select('id')
        .or('series_id.eq.$seriesId,recurring_series_id.eq.$seriesId');
    final scheduledIds = (scheduled as List)
        .map((e) => (e as Map<String, dynamic>)['id'] as String)
        .toList(growable: false);

    // 2. Enrollment links for the series.
    final enrolls = await _client
        .from('workshop_enrollments')
        .select('id')
        .eq('series_id', seriesId);
    final enrollmentCount = (enrolls as List).length;

    // 3. Attendance for those scheduled workshops (skip the query when
    //    there are no scheduled workshops — `.inFilter` with [] is a
    //    PostgREST error).
    var attendanceCount = 0;
    if (scheduledIds.isNotEmpty) {
      final att = await _client
          .from('attendance')
          .select('id')
          .inFilter('scheduled_workshop_id', scheduledIds);
      attendanceCount = (att as List).length;
    }

    return SeriesCancellationImpact(
      scheduledCount: scheduledIds.length,
      attendanceCount: attendanceCount,
      enrollmentCount: enrollmentCount,
    );
  }

  /// Archives an entire recurring workshop series. Admin-only.
  ///
  /// Sets `archived_at = now()` + `is_active = false` on:
  ///   1. The `workshop_series` row itself (stops the generator from
  ///      creating future sessions — the generator iterates
  ///      `workshop_series where archived_at is null`).
  ///   2. All `scheduled_workshops` rows belonging to the series
  ///      (`series_id` OR legacy `recurring_series_id`).
  ///
  /// Also flips `workshop_enrollments.is_active = false` for every
  /// child enrolled in the series so lists of "active workshops for
  /// this child" stop showing the archived series. **Enrollment rows
  /// are not deleted** — they remain as historical association records.
  ///
  /// Attendance rows are **never** touched.
  ///
  /// Verifies the archive after each step so an RLS denial surfaces as
  /// [WorkshopCancelBlockedException.refusedByServer] rather than a
  /// silent no-op.
  Future<void> cancelWorkshopSeries({
    required bool isAdmin,
    required String adminId,
    required String seriesId,
    String? reason,
  }) async {
    if (!isAdmin) throw StateError('Unauthorized role');
    if (kDebugMode) {
      debugPrint('[Workshops] cancelWorkshopSeries seriesId=$seriesId');
    }

    final archivedAt = DateTime.now().toUtc().toIso8601String();
    final trimmedReason =
        (reason != null && reason.trim().isNotEmpty) ? reason.trim() : null;

    // 1. Archive the workshop_series row itself.
    final seriesUpdate = <String, dynamic>{
      'archived_at': archivedAt,
      'archived_by': adminId,
      'archived_reason': ?trimmedReason,
      'is_active': false,
    };
    final updatedSeries = await _client
        .from('workshop_series')
        .update(seriesUpdate)
        .eq('id', seriesId)
        .select('id');
    if (kDebugMode) {
      debugPrint(
          '[Workshops] series cancel: workshop_series rows updated=${(updatedSeries as List).length}');
    }

    // 2. Archive every scheduled_workshops row belonging to the series.
    final scheduledUpdate = <String, dynamic>{
      'archived_at': archivedAt,
      'archived_by': adminId,
      'archived_reason': ?trimmedReason,
      'is_active': false,
    };
    final updatedScheduled = await _client
        .from('scheduled_workshops')
        .update(scheduledUpdate)
        .or('series_id.eq.$seriesId,recurring_series_id.eq.$seriesId')
        .select('id');
    if (kDebugMode) {
      debugPrint(
          '[Workshops] series cancel: scheduled_workshops rows updated=${(updatedScheduled as List).length}');
    }

    // 3. Flip enrollment.is_active = false so the archived series stops
    //    appearing in "active workshops for this child" lists. Rows are
    //    preserved so history / analytics still know each child was
    //    enrolled at some point.
    await _client
        .from('workshop_enrollments')
        .update({'is_active': false})
        .eq('series_id', seriesId);

    // 4. Verify at least the series row itself was archived. If the
    //    UPDATE affected 0 rows and the series row still has archived_at
    //    IS NULL, the server refused the write (RLS).
    final verify = await _client
        .from('workshop_series')
        .select('id, archived_at')
        .eq('id', seriesId)
        .maybeSingle();
    if (verify != null && verify['archived_at'] == null) {
      throw const WorkshopCancelBlockedException(
        WorkshopCancelBlockedReason.refusedByServer,
      );
    }
  }

  // ── Attendance ────────────────────────────────────────────────────────────

  Future<void> markAttendance({
    required bool isStaff,
    required String workshopId,
    required String childId,
    required String status,
    String? observation,
    required String markedBy,
  }) async {
    if (!isStaff) throw StateError('Unauthorized role');
    await _client.from('attendance').upsert(
      {
        'scheduled_workshop_id': workshopId,
        'child_id': childId,
        'status': status,
        'observation': observation,
        'marked_by': markedBy,
        'marked_at': DateTime.now().toUtc().toIso8601String(),
        'is_archived': false,
      },
      onConflict: 'scheduled_workshop_id,child_id',
    );
  }

  /// Marks all given [childIds] as present for [workshopId].
  /// Preserves existing observation values (does not overwrite them).
  Future<void> markAllPresent({
    required bool isStaff,
    required String workshopId,
    required List<String> childIds,
    required String markedBy,
  }) async {
    if (!isStaff) throw StateError('Unauthorized role');
    if (childIds.isEmpty) return;

    // Fetch existing observations so they are preserved on upsert.
    final existing = await _client
        .from('attendance')
        .select('child_id, observation')
        .eq('scheduled_workshop_id', workshopId)
        .inFilter('child_id', childIds);

    final obsMap = <String, String?>{};
    for (final row in (existing as List)) {
      obsMap[row['child_id'] as String] = row['observation'] as String?;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final rows = childIds
        .map((childId) => {
              'scheduled_workshop_id': workshopId,
              'child_id': childId,
              'status': 'present',
              'observation': obsMap[childId],
              'marked_by': markedBy,
              'marked_at': now,
              'is_archived': false,
            })
        .toList();

    await _client.from('attendance').upsert(
          rows,
          onConflict: 'scheduled_workshop_id,child_id',
        );
  }
}

