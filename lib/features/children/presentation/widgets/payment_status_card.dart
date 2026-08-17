import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/error_state.dart';
import '../../../../core/widgets/loading_state.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../domain/child_current_status_row.dart';
import '../../domain/child_payment_cycle.dart';
import '../../domain/child_payment_status_row.dart';
import '../../providers/child_details_providers.dart';
import 'active_cycle_section.dart';
import 'details_section_card.dart';
import 'payment_cycle_card.dart';
import 'payment_dialog.dart';
import 'payment_status_helpers.dart';

/// Payment status, series-aware + chronologically correct.
///
/// Since 2026-08-21 attendance-to-cycle membership is determined by
/// chronology, not by `attendance.payment_cycle_id`:
///
///   • Historical cycle card contains every attendance row (present +
///     absent) belonging to the same series whose `workshop_date` falls
///     inside `[period_start, period_end]`.
///   • Current/active section contains rows in the same series whose
///     `workshop_date` is strictly AFTER the latest completed cycle's
///     `period_end` — and are not already linked to any financial cycle.
///
/// Financial semantics are unchanged: only PRESENT rows count toward the
/// four-session threshold; `sessions_count` remains 4.
class PaymentStatusCard extends ConsumerWidget {
  const PaymentStatusCard({super.key, required this.childId});
  final String childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final attendanceAsync =
        ref.watch(childCurrentStatusRowsProvider(childId));
    final paymentCyclesAsync =
        ref.watch(childPaymentCyclesNewProvider(childId));

    if (attendanceAsync.isLoading || paymentCyclesAsync.isLoading) {
      return const DetailsSectionCard(
        title: 'Status plată',
        iconData: Icons.credit_card_rounded,
        iconColor: Color(0xFF3B82F6),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: AppLoading(),
        ),
      );
    }

    if (attendanceAsync.hasError) {
      return DetailsSectionCard(
        title: 'Status plată',
        iconData: Icons.credit_card_rounded,
        iconColor: const Color(0xFF3B82F6),
        child: AppError(message: attendanceAsync.error.toString()),
      );
    }

    final allAttendance = attendanceAsync.valueOrNull ?? const [];
    final allCycles = paymentCyclesAsync.valueOrNull ?? const [];

    // Group everything by seriesId — cycles by series_id, attendance by
    // its own series_id (populated by the join in fetchChildCurrentStatusRows).
    final seriesIds = <String>{
      ...allCycles.map((c) => c.seriesId).whereType<String>(),
      ...allAttendance.map((r) => r.seriesId).whereType<String>(),
    };

    if (seriesIds.isEmpty) {
      return DetailsSectionCard(
        title: 'Status plată',
        iconData: Icons.credit_card_rounded,
        iconColor: const Color(0xFF3B82F6),
        child: Text(
          'Nu există cicluri de plată înregistrate.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }

    String titleFor(String sid) {
      for (final c in allCycles) {
        if (c.seriesId == sid && c.seriesTitle != null) return c.seriesTitle!;
      }
      for (final r in allAttendance) {
        if (r.seriesId == sid && r.seriesTitle != null) return r.seriesTitle!;
      }
      return 'Atelier';
    }

    final orderedSeries = seriesIds.toList()
      ..sort((a, b) => titleFor(a).compareTo(titleFor(b)));

    return DetailsSectionCard(
      title: 'Status plată',
      iconData: Icons.credit_card_rounded,
      iconColor: const Color(0xFF3B82F6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < orderedSeries.length; i++) ...[
            if (i > 0)
              Divider(
                height: 28,
                thickness: 1,
                color: theme.colorScheme.outline.withValues(alpha: 0.15),
              ),
            _SeriesPaymentSection(
              childId: childId,
              seriesId: orderedSeries[i],
              seriesTitle: titleFor(orderedSeries[i]),
              seriesAttendance: allAttendance
                  .where((r) => r.seriesId == orderedSeries[i])
                  .toList(),
              seriesCycles: allCycles
                  .where((c) => c.seriesId == orderedSeries[i])
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Per-series section ─────────────────────────────────────────────────

class _SeriesPaymentSection extends ConsumerWidget {
  const _SeriesPaymentSection({
    required this.childId,
    required this.seriesId,
    required this.seriesTitle,
    required this.seriesAttendance,
    required this.seriesCycles,
  });

  final String childId;
  final String seriesId;
  final String seriesTitle;
  final List<ChildCurrentStatusRow> seriesAttendance;
  final List<ChildPaymentCycle> seriesCycles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // ── Latest completed cycle boundary for this series
    //   (paid_advance is a pre-payment; not part of the chronological chain)
    DateTime? latestCycleEnd;
    for (final c in seriesCycles) {
      if (c.status == 'paid_advance') continue;
      final pe = c.periodEnd;
      if (pe == null) continue;
      if (latestCycleEnd == null || pe.isAfter(latestCycleEnd)) {
        latestCycleEnd = pe;
      }
    }

    // ── Build per-cycle attendance groups by CHRONOLOGY.
    //   For each non-advance cycle, take every attendance row in this
    //   series whose workshop_date is within [period_start, period_end].
    //   This picks up intermediate absences that carry payment_cycle_id
    //   = NULL — the whole point of this fix.
    final groups = <CycleGroup>[];
    for (final c in seriesCycles) {
      if (c.status == 'paid_advance') continue;
      final ps = c.periodStart;
      final pe = c.periodEnd;
      final cycleRows = <ChildPaymentStatusRow>[];
      if (ps != null && pe != null) {
        for (final a in seriesAttendance) {
          final d = a.workshopDate;
          if (d == null) continue;
          if (d.isBefore(ps) || d.isAfter(pe)) continue;
          cycleRows.add(_asPaymentStatusRow(a, c.id, c.status));
        }
        cycleRows.sort(
            (a, b) => a.workshopDate!.compareTo(b.workshopDate!));
      }
      groups.add(CycleGroup(
        cycleId: c.id,
        cycleStatus: c.status,
        periodStart: c.periodStart,
        periodEnd: c.periodEnd,
        paidAt: c.paidAt,
        confirmedByName: null,
        paymentMethod: _resolveMethod(c.paymentMethod, c.notes),
        sessionsCount: c.sessionsCount,
        rows: cycleRows,
      ));
    }

    // ── Current block: rows strictly AFTER the latest cycle boundary
    //   AND not linked to any cycle. Rows before that boundary but
    //   unlinked are ABSENCES that historically belong inside a closed
    //   cycle — displayed via the cycle group above, not here.
    final currentRows = <ChildCurrentStatusRow>[];
    for (final r in seriesAttendance) {
      if (r.paymentCycleId != null) continue;
      if (latestCycleEnd != null &&
          r.workshopDate != null &&
          !r.workshopDate!.isAfter(latestCycleEnd)) {
        continue;
      }
      currentRows.add(r);
    }
    currentRows.sort((a, b) => (a.workshopDate ?? DateTime(0))
        .compareTo(b.workshopDate ?? DateTime(0)));

    // Cycle numbering (chronological by period_start).
    final sortedAsc = [...groups]
      ..sort((a, b) => (a.periodStart ?? DateTime(0))
          .compareTo(b.periodStart ?? DateTime(0)));
    final cycleNumbers = {
      for (var i = 0; i < sortedAsc.length; i++)
        sortedAsc[i].cycleId: i + 1
    };

    final dueGroups = groups
        .where(
            (g) => g.cycleStatus == 'due' || g.cycleStatus == 'overdue')
        .toList();
    final paidGroups =
        groups.where((g) => g.cycleStatus == 'paid').toList();

    final isAlreadyConfirmed =
        seriesCycles.any((c) => c.status == 'paid_advance') ||
            groups.any((g) => g.cycleStatus == 'paid_advance');
    final advanceCycle =
        seriesCycles.where((c) => c.status == 'paid_advance').firstOrNull;
    final confirmedPaymentMethod = advanceCycle != null
        ? _resolveMethod(advanceCycle.paymentMethod, advanceCycle.notes)
        : null;

    final dueGroup = dueGroups.isNotEmpty ? dueGroups.first : null;
    final showActiveCycle = currentRows.isNotEmpty;
    final visible =
        _buildVisible(groups, hasCurrentRows: currentRows.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          seriesTitle,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: AppColors.purple,
          ),
        ),
        const SizedBox(height: 12),

        if (showActiveCycle) ...[
          ActiveCycleSection(
            childId: childId,
            seriesId: seriesId,
            currentRows: currentRows,
            dueGroup: dueGroup,
            isConfirmed: isAlreadyConfirmed,
            confirmedPaymentMethod: confirmedPaymentMethod,
          ),
          if (visible.isNotEmpty)
            Divider(
              height: 24,
              thickness: 1,
              color: theme.colorScheme.outline.withValues(alpha: 0.15),
            ),
        ],

        if (!showActiveCycle && groups.isEmpty)
          Text(
            seriesCycles.isEmpty
                ? 'Nu există cicluri de plată înregistrate.'
                : 'Nu există încă un status de plată.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          )
        else if (visible.isNotEmpty) ...[
          if (dueGroups.isNotEmpty)
            SummaryBanner(
              dueCount: dueGroups.length,
              paidCount: paidGroups.length,
            ),
          ...visible.map(
            (g) => PaymentCycleCard(
              cycleId: g.cycleId,
              cycleNumber: cycleNumbers[g.cycleId],
              cycleStatus: g.cycleStatus,
              periodStart: g.periodStart,
              periodEnd: g.periodEnd,
              paidAt: g.paidAt,
              confirmedByName: g.confirmedByName,
              paymentMethod: g.paymentMethod,
              sessionsCount: g.sessionsCount,
              rows: g.rows,
              onConfirmPayment:
                  (g.cycleStatus == 'due' || g.cycleStatus == 'overdue')
                      ? () => _confirmClosedCycle(context, ref, g.cycleId)
                      : null,
            ),
          ),
          if (dueGroups.isNotEmpty) const InfoNote(),
        ],
      ],
    );
  }

  Future<void> _confirmClosedCycle(
      BuildContext context, WidgetRef ref, String cycleId) async {
    final authUser = ref.read(currentUserProvider);
    if (authUser == null) return;
    final isStaff =
        ref.read(currentProfileProvider).valueOrNull?.isStaff ?? false;

    await showPaymentMethodDialog(
      context,
      onConfirm: (method, observation) async {
        await ref.read(childDetailsRepositoryProvider).confirmPayment(
              isStaff: isStaff,
              cycleId: cycleId,
              userId: authUser.id,
              paymentMethod: method.toLowerCase(),
              notes: observation ?? '',
            );
      },
    );
  }

  /// Adapts a `ChildCurrentStatusRow` (rich attendance model) into a
  /// `ChildPaymentStatusRow` (what `PaymentCycleCard` expects). Only the
  /// display fields are copied; `paidAt` / `confirmedByName` stay null
  /// since the card sources those from the cycle row instead.
  static ChildPaymentStatusRow _asPaymentStatusRow(
    ChildCurrentStatusRow src,
    String cycleId,
    String? cycleStatus,
  ) {
    return ChildPaymentStatusRow(
      childId: src.childId,
      cycleId: cycleId,
      workshopTitle: src.workshopTitle,
      workshopDate: src.workshopDate,
      dayOfWeek: src.dayOfWeek,
      startTime: src.startTime,
      endTime: src.endTime,
      attendanceStatus: src.attendanceStatus,
      observation: src.observation,
      cycleStatus: cycleStatus,
    );
  }

  static String? _resolveMethod(String? paymentMethod, String? notes) {
    if (paymentMethod != null && paymentMethod.isNotEmpty) {
      return paymentMethod.toUpperCase();
    }
    if (notes == null) return null;
    final upper = notes.toUpperCase();
    if (upper.contains('POS')) return 'POS';
    if (RegExp(r'\bOP\b').hasMatch(upper)) return 'OP';
    return null;
  }

  List<CycleGroup> _buildVisible(List<CycleGroup> groups,
      {required bool hasCurrentRows}) {
    final unpaid = groups
        .where(
            (g) => g.cycleStatus == 'due' || g.cycleStatus == 'overdue')
        .toList();
    if (unpaid.isNotEmpty) return unpaid;

    if (!hasCurrentRows) {
      final advance =
          groups.where((g) => g.cycleStatus == 'paid_advance').toList();
      if (advance.isNotEmpty) return advance;
    }

    final paid = groups.where((g) => g.cycleStatus == 'paid').toList()
      ..sort((a, b) => (b.periodStart ?? DateTime(0))
          .compareTo(a.periodStart ?? DateTime(0)));
    return paid.isNotEmpty ? [paid.first] : [];
  }
}
