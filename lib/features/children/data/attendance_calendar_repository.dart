import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/child_calendar_session.dart';

/// Repository for the child-scoped historical attendance calendar.
///
/// Composes `attendance` + `scheduled_workshops` into per-day sessions and
/// wraps the same UPSERT contract that `WorkshopsRepository.markAttendance`
/// uses. Since the migration `20260817_chronological_payment_cycles.sql`,
/// every INSERT/UPDATE/DELETE on `attendance` triggers a per-child
/// chronological recalc of payment cycles, so historical edits never
/// corrupt cycle counts anymore. No client-side lock is needed.
class AttendanceCalendarRepository {
  const AttendanceCalendarRepository(this._client);

  final SupabaseClient _client;

  /// Fetches every eligible session for [childId] whose `workshop_date` is
  /// in the half-open range `[monthStart, monthEndExclusive)`.
  ///
  /// A session is "eligible" when either:
  ///   • the child already has an `attendance` row for the pair (persisted
  ///     history — always shown, even after unenroll or workshop archive),
  ///     OR
  ///   • the child is currently enrolled in the workshop's series AND the
  ///     workshop is active + not archived (recovery of a forgotten mark).
  Future<List<ChildCalendarSession>> fetchMonth({
    required String childId,
    required DateTime monthStart,
    required DateTime monthEndExclusive,
  }) async {
    final startStr = _dateOnly(monthStart);
    final endStr = _dateOnly(monthEndExclusive);

    // Step 1: full attendance history for the child, filtered locally
    //         to the requested date range.
    final attRowsRaw = await _client
        .from('attendance')
        .select(
          'id, child_id, scheduled_workshop_id, status, observation, '
          'marked_at, marked_by, '
          'scheduled_workshops!scheduled_workshop_id('
          '  id, title, workshop_type, workshop_date, day_of_week, '
          '  start_time, end_time, trainer_id, is_active, archived_at'
          '), '
          'profiles!marked_by(first_name, last_name)',
        )
        .eq('child_id', childId)
        .eq('is_archived', false);

    final attendanceSessions = <String, ChildCalendarSession>{};
    for (final row in (attRowsRaw as List)) {
      final map = row as Map<String, dynamic>;
      final ws = map['scheduled_workshops'] as Map<String, dynamic>?;
      if (ws == null) continue;
      final dateStr = ws['workshop_date'] as String?;
      if (dateStr == null) continue;
      if (dateStr.compareTo(startStr) < 0) continue;
      if (dateStr.compareTo(endStr) >= 0) continue;
      final wsId = ws['id'] as String;
      attendanceSessions[wsId] = _sessionFromAttendanceRow(map, ws);
    }

    // Step 2: active-enrolment scheduled_workshops in the same range
    //         that don't already appear above.
    final seriesIds = await _fetchActiveSeriesIds(childId);
    List<Map<String, dynamic>> unmarkedWs = const [];
    if (seriesIds.isNotEmpty) {
      final quoted = seriesIds.map((s) => '"$s"').join(',');
      final rows = await _client
          .from('scheduled_workshops')
          .select(
            'id, title, workshop_type, workshop_date, day_of_week, '
            'start_time, end_time, trainer_id, is_active, archived_at',
          )
          .gte('workshop_date', startStr)
          .lt('workshop_date', endStr)
          .eq('is_active', true)
          .filter('archived_at', 'is', null)
          .or('series_id.in.($quoted),recurring_series_id.in.($quoted)');
      unmarkedWs = (rows as List).cast<Map<String, dynamic>>();
    }

    final merged = <String, ChildCalendarSession>{...attendanceSessions};
    for (final ws in unmarkedWs) {
      final wsId = ws['id'] as String;
      if (merged.containsKey(wsId)) continue;
      merged[wsId] = _sessionFromWorkshopRow(ws, enrolmentActive: true);
    }

    final list = merged.values.toList();
    list.sort(_compareByDateAndTime);
    return list;
  }

  /// Past sessions in the last [monthsBack] months for [childId] that have
  /// no attendance recorded. Used by the "Prezențe necompletate" mode.
  Future<List<ChildCalendarSession>> fetchMissing({
    required String childId,
    int monthsBack = 6,
    int limit = 200,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = DateTime(now.year, now.month - monthsBack, 1);

    final seriesIds = await _fetchActiveSeriesIds(childId);
    if (seriesIds.isEmpty) return const [];

    final quoted = seriesIds.map((s) => '"$s"').join(',');
    final wsRows = await _client
        .from('scheduled_workshops')
        .select(
          'id, title, workshop_type, workshop_date, day_of_week, '
          'start_time, end_time, trainer_id, is_active, archived_at',
        )
        .gte('workshop_date', _dateOnly(from))
        .lte('workshop_date', _dateOnly(today))
        .eq('is_active', true)
        .filter('archived_at', 'is', null)
        .or('series_id.in.($quoted),recurring_series_id.in.($quoted)')
        .order('workshop_date', ascending: false);

    final wsList = (wsRows as List).cast<Map<String, dynamic>>();
    if (wsList.isEmpty) return const [];

    final wsIds = wsList.map((w) => w['id'] as String).toList();
    final existing = await _client
        .from('attendance')
        .select('scheduled_workshop_id')
        .eq('child_id', childId)
        .inFilter('scheduled_workshop_id', wsIds);
    final markedIds = <String>{
      for (final r in (existing as List))
        (r as Map<String, dynamic>)['scheduled_workshop_id'] as String,
    };

    final out = <ChildCalendarSession>[];
    for (final ws in wsList) {
      final wsId = ws['id'] as String;
      if (markedIds.contains(wsId)) continue;
      out.add(_sessionFromWorkshopRow(ws, enrolmentActive: true));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Ensures every recurring series the child is currently enrolled in
  /// has all its weekly `scheduled_workshops` rows materialised from
  /// `workshop_series.start_date` to today. Called by the calendar
  /// modal once per open so historical dates the legacy generator never
  /// filled become selectable.
  ///
  /// Delegates to the `ensure_child_series_backfilled` RPC — idempotent,
  /// cheap (skips existing rows). Returns the total number of new
  /// `scheduled_workshops` rows inserted (usually 0).
  Future<int> ensureBackfilled(String childId) async {
    final res = await _client
        .rpc('ensure_child_series_backfilled', params: {
      'p_child_id': childId,
    });
    if (res is Map && res['total_inserted'] is int) {
      return res['total_inserted'] as int;
    }
    if (res is Map && res['total_inserted'] is num) {
      return (res['total_inserted'] as num).toInt();
    }
    return 0;
  }

  /// Sets attendance for `(childId, scheduledWorkshopId)`, creating a new
  /// row on first touch or updating the existing one otherwise.
  ///
  /// Same UPSERT contract as `WorkshopsRepository.markAttendance`. The
  /// server-side trigger `trg_recalculate_cycles_on_attendance` recomputes
  /// the child's payment cycles chronologically after the write, so
  /// historical edits are always safe.
  Future<void> upsertAttendance({
    required String childId,
    required String scheduledWorkshopId,
    required String status,
    String? observation,
    required String markedBy,
    required bool isStaff,
  }) async {
    if (!isStaff) {
      throw StateError('Unauthorized role');
    }
    if (status != 'present' && status != 'absent' && status != 'motivated') {
      throw ArgumentError.value(status, 'status');
    }

    await _client.from('attendance').upsert(
      {
        'scheduled_workshop_id': scheduledWorkshopId,
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

  /// Removes an `attendance` row entirely. Use ONLY for rows that were
  /// created by mistake (wrong child, wrong session — not a "child was
  /// absent" case, which should be recorded as `absent` instead).
  ///
  /// Staff-only guarded here (client defence). Since migration
  /// `20260823_attendance_delete_trainer.sql`, the server-side policy
  /// `attendance_delete_admin_or_trainer` allows either an admin OR a
  /// trainer that owns the scheduled_workshop the attendance points to
  /// — so a trainer trying to delete for someone else's workshop still
  /// gets rejected at the DB level.
  ///
  /// The DB trigger `trg_recalculate_cycles_on_attendance` fires on
  /// DELETE and re-runs `recalculate_child_series_payment_cycles` for
  /// the affected (child, series), so payment cycles stay consistent
  /// automatically.
  Future<void> deleteAttendance({
    required String attendanceId,
    required bool isStaff,
  }) async {
    if (!isStaff) {
      throw StateError('Only staff may delete attendance rows');
    }
    await _client.from('attendance').delete().eq('id', attendanceId);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  Future<List<String>> _fetchActiveSeriesIds(String childId) async {
    final rows = await _client
        .from('workshop_enrollments')
        .select('series_id')
        .eq('child_id', childId)
        .eq('is_active', true);
    return (rows as List)
        .map((r) => (r as Map<String, dynamic>)['series_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
  }

  static String _dateOnly(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static int _compareByDateAndTime(
      ChildCalendarSession a, ChildCalendarSession b) {
    final c = a.workshopDate.compareTo(b.workshopDate);
    if (c != 0) return c;
    return a.startTime.compareTo(b.startTime);
  }

  ChildCalendarSession _sessionFromAttendanceRow(
    Map<String, dynamic> row,
    Map<String, dynamic> ws,
  ) {
    final profile = row['profiles'] as Map<String, dynamic>?;
    final markedByName = profile == null
        ? null
        : '${profile['first_name'] ?? ''} ${profile['last_name'] ?? ''}'
            .trim();

    final workshopDate = DateTime.parse(ws['workshop_date'] as String);
    return ChildCalendarSession(
      scheduledWorkshopId: ws['id'] as String,
      workshopDate:
          DateTime(workshopDate.year, workshopDate.month, workshopDate.day),
      startTime: (ws['start_time'] as String?) ?? '',
      endTime: (ws['end_time'] as String?) ?? '',
      workshopTitle: (ws['title'] as String?) ?? '',
      workshopType: (ws['workshop_type'] as String?) ?? '',
      dayOfWeek: ws['day_of_week'] as String?,
      trainerId: ws['trainer_id'] as String?,
      attendanceId: row['id'] as String?,
      status: row['status'] as String?,
      observation: row['observation'] as String?,
      markedAt: (row['marked_at'] as String?) != null
          ? DateTime.parse(row['marked_at'] as String)
          : null,
      markedByName: (markedByName == null || markedByName.isEmpty)
          ? null
          : markedByName,
      isWorkshopArchived: ws['archived_at'] != null ||
          (ws['is_active'] as bool? ?? true) == false,
    );
  }

  ChildCalendarSession _sessionFromWorkshopRow(
    Map<String, dynamic> ws, {
    required bool enrolmentActive,
  }) {
    final workshopDate = DateTime.parse(ws['workshop_date'] as String);
    return ChildCalendarSession(
      scheduledWorkshopId: ws['id'] as String,
      workshopDate:
          DateTime(workshopDate.year, workshopDate.month, workshopDate.day),
      startTime: (ws['start_time'] as String?) ?? '',
      endTime: (ws['end_time'] as String?) ?? '',
      workshopTitle: (ws['title'] as String?) ?? '',
      workshopType: (ws['workshop_type'] as String?) ?? '',
      dayOfWeek: ws['day_of_week'] as String?,
      trainerId: ws['trainer_id'] as String?,
      isWorkshopArchived: ws['archived_at'] != null ||
          (ws['is_active'] as bool? ?? true) == false,
      isEnrolmentActive: enrolmentActive,
    );
  }
}
