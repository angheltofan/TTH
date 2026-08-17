import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/monthly_management_report.dart';

/// Fetches everything a [MonthlyManagementReportData] needs in a small
/// number of bulk queries (no N+1) and aggregates the result in Dart.
///
/// All counts are derived from real rows in the database; nothing is
/// invented. Names render as `'First Last'`; when names are missing
/// we fall back to `'Necunoscut'` instead of leaving holes.
class MonthlyManagementReportRepository {
  const MonthlyManagementReportRepository(this._client);

  final SupabaseClient _client;

  Future<MonthlyManagementReportData> fetchReport({
    required int year,
    required int month,
  }) async {
    final monthStart = DateTime(year, month, 1);
    final monthEnd = DateTime(year, month + 1, 0, 23, 59, 59);
    final monthStartIso = _ymd(monthStart);
    final monthEndIso = _ymd(monthEnd);

    // ── Phase 1: parallel bulk queries (everything except attendance).
    //   Attendance must be filtered by the workshop's *scheduled* date,
    //   not by when the row was marked. Since retro-entries from the
    //   historical calendar can be entered in a later month than the
    //   session they refer to, `marked_at` is not a reliable business-
    //   date. We first fetch the scheduled_workshops in the month, then
    //   pull only attendance rows referencing those ids.

    final phase1 = await Future.wait<dynamic>([
      // 0. Children (all rows for counts + new-this-month + payment_type)
      _client
          .from('children')
          .select('id, is_active, created_at, payment_type'),
      // 1. Active children's enrollments to detect "without active workshop"
      _client
          .from('workshop_enrollments')
          .select('child_id, series_id')
          .eq('is_active', true),
      // 2. child_parents links
      _client.from('child_parents').select('child_id'),
      // 3. Scheduled workshops in the month — drives attendance scoping
      _client
          .from('scheduled_workshops')
          .select('id, title, workshop_type, trainer_id, series_id, '
              'recurring_series_id, workshop_date, is_active')
          .gte('workshop_date', monthStartIso)
          .lte('workshop_date', monthEndIso),
      // 4. Active workshop_series for "popular" + workshops-without-children
      _client
          .from('workshop_series')
          .select('id, title, workshop_type, trainer_id')
          .eq('is_active', true),
      // 5. Payment cycles overlapping the month
      _client
          .from('payment_cycles')
          .select(
              'child_id, status, payment_method, paid_at, period_start, period_end'),
      // 6. Profiles for trainer names
      _client
          .from('profiles')
          .select('id, first_name, last_name, role')
          .eq('role', 'trainer'),
      // 7. Demo workshops in the month
      _client
          .from('demo_workshops')
          .select('id, demo_date, status')
          .gte('demo_date', monthStartIso)
          .lte('demo_date', monthEndIso),
      // 8. Parent profiles for portal stats
      _client
          .from('profiles')
          .select('id')
          .eq('role', 'parent'),
      // 9. Open parent-setup tokens (TTL classification done client-side)
      _client
          .from('parent_setup_tokens')
          .select('parent_id, expires_at')
          .isFilter('consumed_at', null),
      // 10. Consumed tokens (identifies parents who have activated)
      _client
          .from('parent_setup_tokens')
          .select('parent_id')
          .not('consumed_at', 'is', null),
    ]);

    final childrenRows = _list(phase1[0]);
    final enrollmentRows = _list(phase1[1]);
    final parentLinkRows = _list(phase1[2]);
    final scheduledRows = _list(phase1[3]);
    final activeSeriesRows = _list(phase1[4]);
    final paymentCycleRows = _list(phase1[5]);
    final trainerRows = _list(phase1[6]);
    final demoRows = _list(phase1[7]);
    final parentProfileRows = _list(phase1[8]);
    final openTokenRows = _list(phase1[9]);
    final consumedTokenRows = _list(phase1[10]);

    // ── Phase 2: attendance rows for the scheduled workshops in the
    //   month. This is the business-date correct scoping — any historical
    //   attendance entered *this* month for a *prior* month's session is
    //   correctly attributed to the prior month, and vice-versa.
    final scheduledIdsInMonth = scheduledRows
        .map((r) => r['id'] as String?)
        .whereType<String>()
        .toList();
    List<Map<String, dynamic>> attendanceRows = const [];
    if (scheduledIdsInMonth.isNotEmpty) {
      final attRaw = await _client
          .from('attendance')
          .select(
              'child_id, scheduled_workshop_id, status, marked_at, marked_by, '
              'is_archived')
          .eq('is_archived', false)
          .inFilter('scheduled_workshop_id', scheduledIdsInMonth);
      attendanceRows = _list(attRaw);
    }

    // Resolve child name lookup once. Used by many sections so we fetch
    // names upfront when we have at least one referenced child id.
    final referencedChildIds = <String>{
      ...attendanceRows.map((r) => r['child_id'] as String? ?? ''),
      ...paymentCycleRows.map((r) => r['child_id'] as String? ?? ''),
      ...enrollmentRows.map((r) => r['child_id'] as String? ?? ''),
    }..removeWhere((s) => s.isEmpty);
    final childNames = await _fetchChildNames(referencedChildIds);

    // ── Section: Children status ────────────────────────────────────────────

    final activeChildrenIds = <String>{};
    final inactiveChildrenIds = <String>{};
    final freeChildIds = <String>{};
    var payingActive = 0;
    var freeActive = 0;
    var newChildren = 0;
    for (final row in childrenRows) {
      final id = row['id'] as String?;
      if (id == null) continue;
      final active = row['is_active'] as bool? ?? false;
      final paymentType = (row['payment_type'] as String?) ?? 'paid';
      final isFree = paymentType == 'free';
      if (isFree) freeChildIds.add(id);
      if (active) {
        activeChildrenIds.add(id);
        if (isFree) {
          freeActive += 1;
        } else {
          payingActive += 1;
        }
      } else {
        inactiveChildrenIds.add(id);
      }
      final createdRaw = row['created_at'] as String?;
      if (createdRaw != null) {
        final created = DateTime.tryParse(createdRaw);
        if (created != null &&
            !created.isBefore(monthStart) &&
            !created.isAfter(monthEnd)) {
          newChildren += 1;
        }
      }
    }

    final enrolledChildIds = enrollmentRows
        .map((r) => r['child_id'] as String?)
        .whereType<String>()
        .toSet();
    final withoutActiveWorkshop = activeChildrenIds
        .where((id) => !enrolledChildIds.contains(id))
        .length;

    final linkedChildIds = parentLinkRows
        .map((r) => r['child_id'] as String?)
        .whereType<String>()
        .toSet();
    final withoutParent =
        activeChildrenIds.where((id) => !linkedChildIds.contains(id)).length;

    final children = ReportChildrenStatus(
      totalActive: activeChildrenIds.length,
      newThisMonth: newChildren,
      totalInactive: inactiveChildrenIds.length,
      withoutActiveWorkshop: withoutActiveWorkshop,
      withoutParentLink: withoutParent,
      payingActive: payingActive,
      freeActive: freeActive,
    );

    // ── Section: Workshops ──────────────────────────────────────────────────

    final scheduledHeld = scheduledRows
        .where((r) => (r['is_active'] as bool? ?? false) == true)
        .toList(growable: false);
    final sessionsHeld = scheduledHeld.length;

    final typeCounts = <String, int>{};
    for (final r in scheduledHeld) {
      final type = (r['workshop_type'] as String?)?.trim();
      final bucket = (type == null || type.isEmpty) ? 'Necategorizat' : type;
      typeCounts[bucket] = (typeCounts[bucket] ?? 0) + 1;
    }
    final byType = typeCounts.entries
        .map((e) => ReportWorkshopTypeStat(type: e.key, count: e.value))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));

    // Most popular: count present attendance rows per workshop title
    final presentByWorkshop = <String, int>{};
    for (final r in attendanceRows) {
      if (r['status'] != 'present') continue;
      final wid = r['scheduled_workshop_id'] as String? ?? '';
      if (wid.isEmpty) continue;
      presentByWorkshop[wid] = (presentByWorkshop[wid] ?? 0) + 1;
    }
    final titleByWorkshopId = <String, String>{
      for (final r in scheduledRows)
        (r['id'] as String? ?? ''): (r['title'] as String? ?? 'Atelier'),
    };
    final perTitleAttendance = <String, int>{};
    presentByWorkshop.forEach((wid, count) {
      final title = titleByWorkshopId[wid] ?? 'Atelier';
      perTitleAttendance[title] = (perTitleAttendance[title] ?? 0) + count;
    });
    final mostPopular = perTitleAttendance.entries
        .map((e) => ReportPopularWorkshop(title: e.key, attendees: e.value))
        .toList()
      ..sort((a, b) => b.attendees.compareTo(a.attendees));

    // Workshops without children: scheduled workshops in the month with no
    // attendance row at all
    final attendanceWorkshopIds = attendanceRows
        .map((r) => r['scheduled_workshop_id'] as String?)
        .whereType<String>()
        .toSet();
    final workshopsWithoutChildren = scheduledHeld
        .where((r) => !attendanceWorkshopIds.contains(r['id'] as String? ?? ''))
        .length;

    final workshopsWithoutTrainer = scheduledHeld
        .where((r) {
          final tid = r['trainer_id'] as String?;
          return tid == null || tid.isEmpty;
        })
        .length;

    final workshops = ReportWorkshopsStatus(
      sessionsHeld: sessionsHeld,
      byType: byType,
      mostPopular: mostPopular.take(5).toList(growable: false),
      withoutChildren: workshopsWithoutChildren,
      withoutTrainer: workshopsWithoutTrainer,
    );

    // ── Section: Attendance ────────────────────────────────────────────────

    var totalPresent = 0;
    var totalAbsent = 0;
    var totalMotivated = 0;
    final perChildPresent = <String, int>{};
    final perChildAbsent = <String, int>{};
    final perChildTotal = <String, int>{};
    final perWorkshopIdPresent = <String, int>{};
    final perWorkshopIdAbsent = <String, int>{};
    final perWorkshopIdMotivated = <String, int>{};
    for (final r in attendanceRows) {
      final status = r['status'] as String? ?? '';
      final childId = r['child_id'] as String? ?? '';
      final workshopId = r['scheduled_workshop_id'] as String? ?? '';
      perChildTotal[childId] = (perChildTotal[childId] ?? 0) + 1;
      switch (status) {
        case 'present':
          totalPresent += 1;
          perChildPresent[childId] = (perChildPresent[childId] ?? 0) + 1;
          perWorkshopIdPresent[workshopId] =
              (perWorkshopIdPresent[workshopId] ?? 0) + 1;
          break;
        case 'absent':
          totalAbsent += 1;
          perChildAbsent[childId] = (perChildAbsent[childId] ?? 0) + 1;
          perWorkshopIdAbsent[workshopId] =
              (perWorkshopIdAbsent[workshopId] ?? 0) + 1;
          break;
        case 'motivated':
          totalMotivated += 1;
          perWorkshopIdMotivated[workshopId] =
              (perWorkshopIdMotivated[workshopId] ?? 0) + 1;
          break;
      }
    }
    final attRecordsTotal = totalPresent + totalAbsent + totalMotivated;
    final attendanceRate = attRecordsTotal == 0
        ? null
        : ((totalPresent / attRecordsTotal) * 100).round();

    final topByAttendance = perChildTotal.entries
        .where((e) => e.value >= 2)
        .map((e) {
          final present = perChildPresent[e.key] ?? 0;
          final rate = ((present / e.value) * 100).round();
          return ReportNamedRate(
            name: childNames[e.key] ?? 'Necunoscut',
            ratePercent: rate,
            totalSessions: e.value,
          );
        })
        .toList()
      ..sort((a, b) {
        final c = b.ratePercent.compareTo(a.ratePercent);
        if (c != 0) return c;
        return b.totalSessions.compareTo(a.totalSessions);
      });

    final topAbsences = perChildAbsent.entries
        .map((e) => ReportNamedCount(
              name: childNames[e.key] ?? 'Necunoscut',
              count: e.value,
            ))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));

    final workshopsHighAbsence = <ReportNamedRate>[];
    perWorkshopIdAbsent.forEach((wid, absent) {
      final present = perWorkshopIdPresent[wid] ?? 0;
      final motivated = perWorkshopIdMotivated[wid] ?? 0;
      final total = present + absent + motivated;
      if (total < 3) return; // too small to be meaningful
      final ratePresent = ((present / total) * 100).round();
      final absenceRate = 100 - ratePresent;
      if (absenceRate < 25) return;
      workshopsHighAbsence.add(ReportNamedRate(
        name: titleByWorkshopId[wid] ?? 'Atelier',
        ratePercent: absenceRate,
        totalSessions: total,
      ));
    });
    workshopsHighAbsence
        .sort((a, b) => b.ratePercent.compareTo(a.ratePercent));

    final attendance = ReportAttendanceStatus(
      totalPresent: totalPresent,
      totalAbsent: totalAbsent,
      totalMotivated: totalMotivated,
      attendanceRate: attendanceRate,
      topChildrenByAttendance: topByAttendance.take(5).toList(growable: false),
      topChildrenByAbsences: topAbsences.take(5).toList(growable: false),
      workshopsWithHighAbsenceRate:
          workshopsHighAbsence.take(5).toList(growable: false),
    );

    // ── Section: Payments ──────────────────────────────────────────────────

    var paidInMonth = 0;
    var unconfirmed = 0;
    var advance = 0;
    var cancelled = 0;
    final unconfirmedChildIds = <String>{};
    final methodBuckets = <String, int>{'POS': 0, 'OP': 0, 'Necunoscut': 0};

    for (final r in paymentCycleRows) {
      // Skip cycles owned by free participants — they are informational
      // only and never count toward financial buckets, alerts, or unpaid
      // lists.
      final ownerChildId = r['child_id'] as String? ?? '';
      if (ownerChildId.isNotEmpty && freeChildIds.contains(ownerChildId)) {
        continue;
      }
      final status = r['status'] as String? ?? '';
      final paidAtRaw = r['paid_at'] as String?;
      final paidAt =
          paidAtRaw != null ? DateTime.tryParse(paidAtRaw) : null;
      final periodStartRaw = r['period_start'] as String?;
      final periodEndRaw = r['period_end'] as String?;
      final periodStart = periodStartRaw != null
          ? DateTime.tryParse(periodStartRaw)
          : null;
      final periodEnd =
          periodEndRaw != null ? DateTime.tryParse(periodEndRaw) : null;
      final overlapsMonth = periodStart != null &&
          periodEnd != null &&
          !periodEnd.isBefore(monthStart) &&
          !periodStart.isAfter(monthEnd);

      final method =
          (r['payment_method'] as String?)?.trim().toUpperCase() ?? '';
      final childId = r['child_id'] as String? ?? '';

      if (status == 'paid' && paidAt != null) {
        if (!paidAt.isBefore(monthStart) && !paidAt.isAfter(monthEnd)) {
          paidInMonth += 1;
          if (method == 'POS') {
            methodBuckets['POS'] = methodBuckets['POS']! + 1;
          } else if (method == 'OP') {
            methodBuckets['OP'] = methodBuckets['OP']! + 1;
          } else {
            methodBuckets['Necunoscut'] = methodBuckets['Necunoscut']! + 1;
          }
        }
      }
      if (status == 'paid_advance' &&
          paidAt != null &&
          !paidAt.isBefore(monthStart) &&
          !paidAt.isAfter(monthEnd)) {
        advance += 1;
      }
      if ((status == 'due' || status == 'overdue') && overlapsMonth) {
        unconfirmed += 1;
        if (childId.isNotEmpty) unconfirmedChildIds.add(childId);
      }
      if (status == 'cancelled' && overlapsMonth) {
        cancelled += 1;
      }
    }

    // Resolve names for unconfirmed children — may not be in the
    // already-fetched name set (a parent of a now-inactive child, etc.).
    final unconfirmedNames = await _fetchChildNames(unconfirmedChildIds);

    final payments = ReportPaymentsStatus(
      paidCycles: paidInMonth,
      unconfirmedCycles: unconfirmed,
      advancePaidCycles: advance,
      cancelledCycles: cancelled,
      childrenWithUnconfirmedPayments: unconfirmedChildIds
          .map((id) => unconfirmedNames[id] ?? 'Necunoscut')
          .where((s) => s != 'Necunoscut' && s.trim().isNotEmpty)
          .toList(growable: false)
        ..sort(),
      paymentMethods: methodBuckets.entries
          .map((e) =>
              ReportPaymentMethodCount(method: e.key, count: e.value))
          .toList(growable: false),
    );

    // ── Section: Trainers ──────────────────────────────────────────────────

    final trainerNameById = <String, String>{
      for (final t in trainerRows)
        (t['id'] as String? ?? ''):
            _fullName(t['first_name'], t['last_name'])
    };
    final sessionsByTrainer = <String, int>{};
    final markedByTrainer = <String, int>{};
    for (final r in scheduledHeld) {
      final tid = r['trainer_id'] as String? ?? '';
      if (tid.isEmpty) continue;
      sessionsByTrainer[tid] = (sessionsByTrainer[tid] ?? 0) + 1;
    }
    for (final r in attendanceRows) {
      final tid = r['marked_by'] as String? ?? '';
      if (tid.isEmpty) continue;
      markedByTrainer[tid] = (markedByTrainer[tid] ?? 0) + 1;
    }
    final activeSeriesByTrainer = <String, int>{};
    for (final s in activeSeriesRows) {
      final tid = s['trainer_id'] as String? ?? '';
      if (tid.isEmpty) continue;
      activeSeriesByTrainer[tid] = (activeSeriesByTrainer[tid] ?? 0) + 1;
    }
    final perTrainer = trainerRows.map((t) {
      final id = t['id'] as String? ?? '';
      return ReportTrainerStat(
        name: trainerNameById[id] ?? 'Necunoscut',
        sessions: sessionsByTrainer[id] ?? 0,
        attendanceMarked: markedByTrainer[id] ?? 0,
        activeWorkshops: activeSeriesByTrainer[id] ?? 0,
      );
    }).toList()
      ..sort((a, b) => b.sessions.compareTo(a.sessions));

    final trainers = ReportTrainersStatus(
      totalTrainers: trainerRows.length,
      perTrainer: perTrainer,
    );

    // ── Section: Parent Portal ────────────────────────────────────────────

    final activatedParentIds = <String>{
      for (final r in consumedTokenRows)
        if ((r['parent_id'] as String? ?? '').isNotEmpty)
          r['parent_id'] as String
    };
    final nowUtc = DateTime.now().toUtc();
    var pendingInvitations = 0;
    final expiredCandidateIds = <String>{};
    for (final r in openTokenRows) {
      final parentId = (r['parent_id'] as String? ?? '').trim();
      if (parentId.isEmpty) continue;
      final expiresAtRaw = r['expires_at'] as String?;
      final expiresAt = expiresAtRaw != null
          ? DateTime.tryParse(expiresAtRaw)
          : null;
      final isExpired = expiresAt == null || expiresAt.isBefore(nowUtc);
      if (isExpired) {
        // Only count as "expired" when the parent has not also
        // activated through another (consumed) token.
        if (!activatedParentIds.contains(parentId)) {
          expiredCandidateIds.add(parentId);
        }
      } else {
        pendingInvitations += 1;
      }
    }
    final childrenLinked = linkedChildIds.length;
    final childrenUnlinked = activeChildrenIds
        .where((id) => !linkedChildIds.contains(id))
        .length;

    final parentPortal = ReportParentPortalStatus(
      totalParentAccounts: parentProfileRows.length,
      activatedParents: activatedParentIds.length,
      pendingInvitations: pendingInvitations,
      expiredInvitations: expiredCandidateIds.length,
      childrenLinkedToParent: childrenLinked,
      childrenWithoutParentLink: childrenUnlinked,
    );

    // ── Executive summary ─────────────────────────────────────────────────

    final exec = ReportExecutiveSummary(
      activeChildren: activeChildrenIds.length,
      newChildren: newChildren,
      sessionsHeld: sessionsHeld,
      attendanceRate: attendanceRate,
      paidCycles: paidInMonth,
      unpaidCycles: unconfirmed,
      demoCount: demoRows.length,
    );

    // ── Alerts (rule-based) ───────────────────────────────────────────────

    final alerts = <String>[];
    if (children.withoutParentLink > 0) {
      alerts.add(
          '${children.withoutParentLink} copii activi nu au un părinte asociat.');
    }
    if (children.withoutActiveWorkshop > 0) {
      alerts.add(
          '${children.withoutActiveWorkshop} copii activi nu sunt înscriși la niciun atelier.');
    }
    if (attendance.topChildrenByAbsences.isNotEmpty &&
        attendance.topChildrenByAbsences.first.count >= 3) {
      alerts.add(
          'Există copii cu prezență slabă în această lună (peste 3 absențe).');
    }
    if (payments.unconfirmedCycles > 0) {
      alerts.add(
          '${payments.unconfirmedCycles} cicluri de plată sunt neconfirmate sau restante.');
    }
    if (workshops.withoutChildren > 0) {
      alerts.add(
          '${workshops.withoutChildren} sesiuni nu au avut copii prezenți.');
    }
    if (workshops.withoutTrainer > 0) {
      alerts.add(
          '${workshops.withoutTrainer} sesiuni nu au avut trainer asignat.');
    }
    final missingDataCount =
        children.withoutParentLink + workshops.withoutTrainer;
    if (missingDataCount == 0 && alerts.isEmpty) {
      alerts.add('Nicio alertă majoră în această lună.');
    }

    // ── Recommendations (rule-based) ──────────────────────────────────────

    final recommendations = <String>[];
    if (payments.unconfirmedCycles > 0) {
      recommendations
          .add('Contactați părinții copiilor cu plăți neconfirmate.');
    }
    if (attendance.topChildrenByAbsences.isNotEmpty &&
        attendance.topChildrenByAbsences.first.count >= 3) {
      recommendations
          .add('Verificați copiii cu prezență sub 50% sau cu absențe repetate.');
    }
    if (children.withoutParentLink > 0) {
      recommendations.add(
          'Completați asocierea părinte-copil pentru copiii nelegați.');
    }
    if (workshops.withoutChildren > 0) {
      recommendations
          .add('Revizuiți atelierele fără copii înscriși sau prezenți.');
    }
    if (workshops.withoutTrainer > 0) {
      recommendations
          .add('Asignați un trainer atelierelor fără trainer.');
    }
    if (children.withoutActiveWorkshop > 0) {
      recommendations.add(
          'Reinscrieți copiii activi care nu sunt înscriși la niciun atelier.');
    }
    if (recommendations.isEmpty) {
      recommendations.add('Nu sunt acțiuni urgente necesare în această lună.');
    }

    return MonthlyManagementReportData(
      year: year,
      month: month,
      generatedAt: DateTime.now(),
      executiveSummary: exec,
      children: children,
      workshops: workshops,
      attendance: attendance,
      payments: payments,
      trainers: trainers,
      parentPortal: parentPortal,
      alerts: alerts,
      recommendations: recommendations,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<Map<String, String>> _fetchChildNames(Set<String> ids) async {
    if (ids.isEmpty) return const {};
    final data = await _client
        .from('children')
        .select('id, first_name, last_name')
        .inFilter('id', ids.toList(growable: false));
    final out = <String, String>{};
    for (final row in (data as List)) {
      final r = row as Map<String, dynamic>;
      out[r['id'] as String] = _fullName(r['first_name'], r['last_name']);
    }
    return out;
  }

  static String _fullName(dynamic first, dynamic last) {
    final f = (first as String?)?.trim() ?? '';
    final l = (last as String?)?.trim() ?? '';
    final full = '$f $l'.trim();
    return full.isEmpty ? 'Necunoscut' : full;
  }

  static String _ymd(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  static List<Map<String, dynamic>> _list(dynamic data) {
    return (data as List).cast<Map<String, dynamic>>();
  }
}
