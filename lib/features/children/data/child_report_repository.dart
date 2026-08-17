import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/child_activity_report.dart';

/// Data layer for the Child Activity Report PDF.
///
/// One public entry point: [fetchChildActivityReport] runs four bulk reads
/// in parallel (child info, active enrollments, full attendance history,
/// payment cycles) then assembles a single [ChildActivityReportData] for
/// the PDF service. No N+1 queries. RLS scopes results: admin sees all,
/// trainer sees only children in their assigned series.
class ChildReportRepository {
  const ChildReportRepository(this._client);

  final SupabaseClient _client;

  Future<ChildActivityReportData> fetchChildActivityReport(
      String childId) async {
    final results = await Future.wait<dynamic>([
      _fetchChildRow(childId),
      _fetchActiveWorkshops(childId),
      _fetchAttendance(childId),
      _fetchPaymentCycles(childId),
    ]);

    final childRow = results[0] as Map<String, dynamic>?;
    if (childRow == null) {
      throw StateError('Child not found');
    }

    final workshops =
        (results[1] as List<ChildReportWorkshopInfo>);
    final attendance =
        (results[2] as List<ChildReportAttendanceRow>);
    final payments = (results[3] as List<ChildReportPaymentRow>);

    final childInfo = _childInfoFromRow(childRow);
    final observations = _extractObservations(attendance);
    final summary = _buildSummary(
      attendance: attendance,
      payments: payments,
    );

    return ChildActivityReportData(
      childInfo: childInfo,
      activeWorkshops: workshops,
      attendanceRows: attendance,
      paymentRows: payments,
      observations: observations,
      summary: summary,
      generatedAt: DateTime.now(),
    );
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _fetchChildRow(String childId) async {
    return _client
        .from('children')
        .select(
            'id, first_name, last_name, birth_date, '
            'parent_name, parent_phone')
        .eq('id', childId)
        .maybeSingle();
  }

  Future<List<ChildReportWorkshopInfo>> _fetchActiveWorkshops(
      String childId) async {
    final data = await _client
        .from('workshop_enrollments')
        .select(
            'workshop_series!series_id('
            'title, workshop_type, day_of_week, start_time, end_time, '
            'profiles!trainer_id(first_name, last_name))')
        .eq('child_id', childId)
        .eq('is_active', true);

    final result = <ChildReportWorkshopInfo>[];
    for (final raw in (data as List)) {
      final ws = (raw as Map<String, dynamic>)['workshop_series'];
      if (ws is! Map) continue;
      result.add(_workshopInfoFromMap(ws.cast<String, dynamic>()));
    }
    return result;
  }

  Future<List<ChildReportAttendanceRow>> _fetchAttendance(
      String childId) async {
    final data = await _client
        .from('attendance')
        .select(
            'status, observation, marked_at, '
            'scheduled_workshops!scheduled_workshop_id('
            'title, workshop_type, workshop_date, '
            'start_time, end_time, '
            'profiles!trainer_id(first_name, last_name)))')
        .eq('child_id', childId)
        .eq('is_archived', false);

    final rows = <ChildReportAttendanceRow>[];
    for (final raw in (data as List)) {
      final map = raw as Map<String, dynamic>;
      final sw = map['scheduled_workshops'];
      final swMap =
          sw is Map ? sw.cast<String, dynamic>() : <String, dynamic>{};
      final status = (map['status'] as String?) ?? '';
      if (status.isEmpty) continue;
      rows.add(ChildReportAttendanceRow(
        date: _parseDate(swMap['workshop_date']),
        workshopTitle: (swMap['title'] as String?) ?? 'Atelier',
        workshopType: swMap['workshop_type'] as String?,
        trainerName: _trainerNameFrom(swMap['profiles']),
        startTime: swMap['start_time'] as String?,
        endTime: swMap['end_time'] as String?,
        status: status,
        observation: (map['observation'] as String?)?.trim().isEmpty == true
            ? null
            : map['observation'] as String?,
      ));
    }

    // Newest first: by workshop_date desc, then start_time desc.
    rows.sort((a, b) {
      final dateCmp = (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0));
      if (dateCmp != 0) return dateCmp;
      return (b.startTime ?? '').compareTo(a.startTime ?? '');
    });
    return rows;
  }

  Future<List<ChildReportPaymentRow>> _fetchPaymentCycles(
      String childId) async {
    final data = await _client
        .from('payment_cycles')
        .select(
            'period_start, period_end, sessions_count, status, '
            'payment_method, paid_at, notes, created_at, '
            'workshop_series!series_id(title)')
        .eq('child_id', childId);

    final rows = (data as List).map((raw) {
      final map = raw as Map<String, dynamic>;
      final ws = map['workshop_series'] as Map<String, dynamic>?;
      return ChildReportPaymentRow(
        periodStart: _parseDate(map['period_start']),
        periodEnd: _parseDate(map['period_end']),
        sessionsCount: (map['sessions_count'] as num?)?.toInt(),
        status: map['status'] as String?,
        paymentMethod: map['payment_method'] as String?,
        paidAt: _parseDateTime(map['paid_at']),
        notes: (map['notes'] as String?)?.trim().isEmpty == true
            ? null
            : map['notes'] as String?,
        seriesTitle: ws?['title'] as String?,
      );
    }).toList();

    // Newest first: prefer period_start when present, fall back to paid_at.
    rows.sort((a, b) {
      final aKey = a.periodStart ?? a.paidAt ?? DateTime(0);
      final bKey = b.periodStart ?? b.paidAt ?? DateTime(0);
      return bKey.compareTo(aKey);
    });
    return rows;
  }

  // ── Assembly helpers ──────────────────────────────────────────────────────

  ChildReportChildInfo _childInfoFromRow(Map<String, dynamic> row) {
    final birth = _parseDate(row['birth_date']);
    final firstName = (row['first_name'] as String?) ?? '';
    final lastName = (row['last_name'] as String?) ?? '';
    final fullName = '$firstName $lastName'.trim();
    return ChildReportChildInfo(
      id: row['id'] as String,
      fullName: fullName.isEmpty ? '—' : fullName,
      birthDate: birth,
      age: birth != null ? _yearsBetween(birth, DateTime.now()) : null,
      parentName: (row['parent_name'] as String?)?.trim().isEmpty == true
          ? null
          : row['parent_name'] as String?,
      parentPhone: (row['parent_phone'] as String?)?.trim().isEmpty == true
          ? null
          : row['parent_phone'] as String?,
      parentEmail: null,
    );
  }

  ChildReportWorkshopInfo _workshopInfoFromMap(Map<String, dynamic> map) {
    return ChildReportWorkshopInfo(
      title: (map['title'] as String?) ?? '—',
      workshopType: map['workshop_type'] as String?,
      dayOfWeek: map['day_of_week'] as String?,
      startTime: map['start_time'] as String?,
      endTime: map['end_time'] as String?,
      trainerName: _trainerNameFrom(map['profiles']),
    );
  }

  String? _trainerNameFrom(dynamic raw) {
    if (raw is! Map) return null;
    final fn = (raw['first_name'] as String?) ?? '';
    final ln = (raw['last_name'] as String?) ?? '';
    final full = '$fn $ln'.trim();
    return full.isEmpty ? null : full;
  }

  List<ChildReportObservation> _extractObservations(
      List<ChildReportAttendanceRow> attendance) {
    final result = <ChildReportObservation>[];
    for (final row in attendance) {
      final obs = row.observation;
      if (obs == null || obs.trim().isEmpty) continue;
      result.add(ChildReportObservation(
        date: row.date,
        workshopTitle: row.workshopTitle,
        text: obs.trim(),
      ));
    }
    return result;
  }

  ChildReportSummary _buildSummary({
    required List<ChildReportAttendanceRow> attendance,
    required List<ChildReportPaymentRow> payments,
  }) {
    var present = 0;
    var absent = 0;
    var motivated = 0;
    final titles = <String>{};
    for (final row in attendance) {
      switch (row.status) {
        case 'present':
          present++;
          break;
        case 'absent':
          absent++;
          break;
        case 'motivated':
          motivated++;
          break;
      }
      titles.add(row.workshopTitle);
    }
    final total = present + absent + motivated;
    final rate = total == 0 ? 0.0 : present / total;

    var confirmed = 0;
    var overdue = 0;
    for (final p in payments) {
      switch (p.status) {
        case 'paid':
        case 'paid_advance':
          confirmed++;
          break;
        case 'overdue':
          overdue++;
          break;
      }
    }

    return ChildReportSummary(
      totalSessions: total,
      presentCount: present,
      absentCount: absent,
      motivatedCount: motivated,
      attendanceRate: rate,
      totalWorkshops: titles.length,
      totalPaymentCycles: payments.length,
      confirmedPayments: confirmed,
      overduePayments: overdue,
    );
  }

  // ── Parsing helpers ───────────────────────────────────────────────────────

  DateTime? _parseDate(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  DateTime? _parseDateTime(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  int _yearsBetween(DateTime from, DateTime to) {
    var years = to.year - from.year;
    if (to.month < from.month ||
        (to.month == from.month && to.day < from.day)) {
      years--;
    }
    return years;
  }
}
