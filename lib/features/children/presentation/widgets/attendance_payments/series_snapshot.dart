import '../../../domain/child_current_status_row.dart';
import '../../../domain/child_payment_cycle.dart';

/// Everything the "Prezențe și plăți" module needs to render one workshop
/// series for one child: cycles (paid / due / advance), the current open
/// block, and — critically — the map of `cycleId → List<attendance in
/// [period_start, period_end]>` used by the timeline.
///
/// This is the SINGLE source of computed data. Both tabs (current +
/// history) consume it, so the classification rules never diverge.
///
/// Business rules encoded here:
///   1. Cycles are per (child, series). This model only handles rows
///      already filtered by series.
///   2. Attendance-to-cycle membership is CHRONOLOGICAL. A row belongs
///      to a cycle iff its `workshop_date` is between the cycle's
///      `period_start` and `period_end` inclusive. Absences carry
///      `payment_cycle_id = NULL` at DB level; that column is a purely
///      financial linkage (PRESENT-only) and MUST NOT be used to decide
///      display membership.
///   3. Current-block = rows in this series with workshop_date > the
///      latest non-advance cycle's period_end, AND not linked to any
///      cycle. If no cycles exist, all series rows are the current block.
///   4. Only PRESENT contributes to the 4/4 counter (financial invariant).
class SeriesFinancialSnapshot {
  SeriesFinancialSnapshot._({
    required this.seriesId,
    required this.seriesTitle,
    required this.allCycles,
    required this.paidCycles,
    required this.dueCycles,
    required this.advanceCycles,
    required this.attendancePerCycle,
    required this.currentBlock,
    required this.latestCycleEnd,
  });

  final String seriesId;
  final String seriesTitle;

  /// All non-advance cycles for this (child, series), sorted by
  /// `period_start` ascending. Numbering in UI = index + 1.
  final List<ChildPaymentCycle> allCycles;
  final List<ChildPaymentCycle> paidCycles;
  final List<ChildPaymentCycle> dueCycles;
  final List<ChildPaymentCycle> advanceCycles;

  /// For every completed cycle, the list of attendance rows whose
  /// workshop_date falls within [period_start, period_end], sorted
  /// chronologically. Includes present AND absent rows — the timeline
  /// renders them in order.
  final Map<String, List<ChildCurrentStatusRow>> attendancePerCycle;

  /// Rows AFTER the latest cycle boundary (or all rows if no cycle
  /// exists yet). Sorted chronologically. Progress = 4/4 counter over
  /// PRESENT entries only.
  final List<ChildCurrentStatusRow> currentBlock;

  /// Latest non-advance cycle `period_end`. Null if the series has no
  /// completed cycles.
  final DateTime? latestCycleEnd;

  // ── Derived ─────────────────────────────────────────────────────────

  int get currentPresentCount =>
      currentBlock.where((r) => r.attendanceStatus == 'present').length;

  int get currentAbsentCount =>
      currentBlock.where((r) => r.attendanceStatus == 'absent').length;

  bool get currentBlockClosingSoon => currentPresentCount == 3;

  DateTime? get lastPresentDate {
    ChildCurrentStatusRow? last;
    for (final r in currentBlock) {
      if (r.attendanceStatus == 'present') last = r;
    }
    return last?.workshopDate;
  }

  ChildPaymentCycle? get advanceCycle =>
      advanceCycles.isEmpty ? null : advanceCycles.first;

  bool get hasAdvance => advanceCycle != null;

  int get totalPaid => paidCycles.length;
  int get totalDue => dueCycles.length;
  int get totalCompleted =>
      allCycles.where((c) => (c.sessionsCount ?? 0) >= 4).length;

  /// Chronologically-classified rows for the given cycle. Empty if the
  /// cycle has null period boundaries (shouldn't happen in practice).
  List<ChildCurrentStatusRow> rowsForCycle(String cycleId) =>
      attendancePerCycle[cycleId] ?? const [];

  /// Absence count within a cycle's interval (used for history tab).
  int absencesInCycle(String cycleId) => rowsForCycle(cycleId)
      .where((r) => r.attendanceStatus == 'absent')
      .length;

  int presencesInCycle(String cycleId) => rowsForCycle(cycleId)
      .where((r) => r.attendanceStatus == 'present')
      .length;

  // ── Builder ─────────────────────────────────────────────────────────

  /// Groups both attendance and cycles by `seriesId` and produces one
  /// snapshot per series present in either list. Series with no active
  /// enrollment but historical attendance still show up (so archived
  /// enrollments don't hide financial history).
  static Map<String, SeriesFinancialSnapshot> buildAll(
    List<ChildCurrentStatusRow> attendance,
    List<ChildPaymentCycle> cycles,
  ) {
    // Discover series present in either data set.
    final seriesIds = <String>{
      ...cycles.map((c) => c.seriesId).whereType<String>(),
      ...attendance.map((r) => r.seriesId).whereType<String>(),
    };

    // Title resolution — prefer cycle join (most reliable), fall back
    // to attendance-embedded title.
    String titleFor(String sid) {
      for (final c in cycles) {
        if (c.seriesId == sid && c.seriesTitle != null) return c.seriesTitle!;
      }
      for (final r in attendance) {
        if (r.seriesId == sid && r.seriesTitle != null) return r.seriesTitle!;
      }
      return 'Atelier';
    }

    final out = <String, SeriesFinancialSnapshot>{};
    for (final sid in seriesIds) {
      final seriesAttendance =
          attendance.where((r) => r.seriesId == sid).toList()
            ..sort(_byDateAndTime);
      final seriesCycles = cycles.where((c) => c.seriesId == sid).toList()
        ..sort((a, b) => (a.periodStart ?? DateTime(0))
            .compareTo(b.periodStart ?? DateTime(0)));

      final nonAdvance =
          seriesCycles.where((c) => c.status != 'paid_advance').toList();
      final advance =
          seriesCycles.where((c) => c.status == 'paid_advance').toList();

      // Latest boundary for open-block detection.
      DateTime? latestEnd;
      for (final c in nonAdvance) {
        final pe = c.periodEnd;
        if (pe == null) continue;
        if (latestEnd == null || pe.isAfter(latestEnd)) latestEnd = pe;
      }

      // Per-cycle attendance by chronology.
      final perCycle = <String, List<ChildCurrentStatusRow>>{};
      for (final c in nonAdvance) {
        final ps = c.periodStart;
        final pe = c.periodEnd;
        if (ps == null || pe == null) {
          perCycle[c.id] = const [];
          continue;
        }
        perCycle[c.id] = seriesAttendance.where((r) {
          final d = r.workshopDate;
          if (d == null) return false;
          if (d.isBefore(ps)) return false;
          if (d.isAfter(pe)) return false;
          return true;
        }).toList();
      }

      // Current block: rows AFTER latest boundary AND unlinked.
      final currentBlock = seriesAttendance.where((r) {
        if (r.paymentCycleId != null) return false;
        if (latestEnd != null &&
            r.workshopDate != null &&
            !r.workshopDate!.isAfter(latestEnd)) {
          return false;
        }
        return true;
      }).toList();

      out[sid] = SeriesFinancialSnapshot._(
        seriesId: sid,
        seriesTitle: titleFor(sid),
        allCycles: nonAdvance,
        paidCycles:
            nonAdvance.where((c) => c.status == 'paid').toList(),
        dueCycles: nonAdvance
            .where((c) => c.status == 'due' || c.status == 'overdue')
            .toList(),
        advanceCycles: advance,
        attendancePerCycle: perCycle,
        currentBlock: currentBlock,
        latestCycleEnd: latestEnd,
      );
    }
    return out;
  }

  static int _byDateAndTime(
      ChildCurrentStatusRow a, ChildCurrentStatusRow b) {
    final d = (a.workshopDate ?? DateTime(0))
        .compareTo(b.workshopDate ?? DateTime(0));
    if (d != 0) return d;
    return (a.startTime ?? '').compareTo(b.startTime ?? '');
  }
}
