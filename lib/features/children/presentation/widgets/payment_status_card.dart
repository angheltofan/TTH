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

/// Payment status card, series-aware.
///
/// Since migration 20260820, payment cycles are per (child, series).
/// This widget:
///   1. Fetches all data at parent level (rows + cycles + open block).
///   2. Groups by `series_id` using the cycle table (source of truth).
///   3. Renders one [_SeriesPaymentSection] per series.
///
/// Each section keeps the previous single-series behavior verbatim
/// (active cycle vs past cycles, due/overdue/paid grouping, advance
/// consumption UI). Section boundaries are visual dividers.
class PaymentStatusCard extends ConsumerWidget {
  const PaymentStatusCard({super.key, required this.childId});
  final String childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final paymentRowsAsync =
        ref.watch(childPaymentStatusRowsProvider(childId));
    final currentRowsAsync =
        ref.watch(childCurrentStatusRowsProvider(childId));
    final paymentCyclesAsync =
        ref.watch(childPaymentCyclesNewProvider(childId));

    if (paymentRowsAsync.isLoading ||
        currentRowsAsync.isLoading ||
        paymentCyclesAsync.isLoading) {
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

    if (paymentRowsAsync.hasError) {
      return DetailsSectionCard(
        title: 'Status plată',
        iconData: Icons.credit_card_rounded,
        iconColor: const Color(0xFF3B82F6),
        child: AppError(message: paymentRowsAsync.error.toString()),
      );
    }

    final allPaymentRows = paymentRowsAsync.valueOrNull ?? [];
    final currentRows = currentRowsAsync.valueOrNull ?? [];
    final paymentCycles = paymentCyclesAsync.valueOrNull ?? [];

    // Build map cycleId → seriesId from the authoritative table, so we can
    // attribute view rows (which lack series_id) to their series.
    final cycleToSeries = <String, String>{};
    for (final c in paymentCycles) {
      if (c.seriesId != null) cycleToSeries[c.id] = c.seriesId!;
    }

    // Group by seriesId.
    final seriesIds = <String>{
      ...paymentCycles.map((c) => c.seriesId).whereType<String>(),
      ...currentRows.map((r) => r.seriesId).whereType<String>(),
    };

    if (seriesIds.isEmpty) {
      // No series info at all — child has no cycles and no unlinked
      // attendance. Show the classic empty state.
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

    // Sort series by title for deterministic ordering.
    final orderedSeries = seriesIds.toList()
      ..sort((a, b) {
        String titleFor(String sid) {
          for (final c in paymentCycles) {
            if (c.seriesId == sid && c.seriesTitle != null) {
              return c.seriesTitle!;
            }
          }
          for (final r in currentRows) {
            if (r.seriesId == sid && r.seriesTitle != null) {
              return r.seriesTitle!;
            }
          }
          return '~';
        }

        return titleFor(a).compareTo(titleFor(b));
      });

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
              seriesTitle: _titleFor(
                orderedSeries[i],
                paymentCycles,
                currentRows,
              ),
              paymentRows: _rowsForSeries(
                orderedSeries[i],
                allPaymentRows,
                cycleToSeries,
              ),
              currentRows: currentRows
                  .where((r) => r.seriesId == orderedSeries[i])
                  .toList(),
              cycles: paymentCycles
                  .where((c) => c.seriesId == orderedSeries[i])
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  static String _titleFor(
    String seriesId,
    List<ChildPaymentCycle> cycles,
    List<ChildCurrentStatusRow> currentRows,
  ) {
    for (final c in cycles) {
      if (c.seriesId == seriesId && c.seriesTitle != null) {
        return c.seriesTitle!;
      }
    }
    for (final r in currentRows) {
      if (r.seriesId == seriesId && r.seriesTitle != null) {
        return r.seriesTitle!;
      }
    }
    return 'Atelier';
  }

  static List<ChildPaymentStatusRow> _rowsForSeries(
    String seriesId,
    List<ChildPaymentStatusRow> allRows,
    Map<String, String> cycleToSeries,
  ) {
    return allRows.where((r) {
      final sid = cycleToSeries[r.cycleId ?? ''];
      return sid == seriesId;
    }).toList();
  }
}

// ── Per-series section ─────────────────────────────────────────────────

class _SeriesPaymentSection extends ConsumerWidget {
  const _SeriesPaymentSection({
    required this.childId,
    required this.seriesId,
    required this.seriesTitle,
    required this.paymentRows,
    required this.currentRows,
    required this.cycles,
  });

  final String childId;
  final String seriesId;
  final String seriesTitle;
  final List<ChildPaymentStatusRow> paymentRows;
  final List<ChildCurrentStatusRow> currentRows;
  final List<ChildPaymentCycle> cycles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final groups = _buildGroups(paymentRows, cycles);

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
        cycles.any((c) => c.status == 'paid_advance') ||
            groups.any((g) => g.cycleStatus == 'paid_advance');
    final advanceCycle =
        cycles.where((c) => c.status == 'paid_advance').firstOrNull;
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
        // Series title header
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
            cycles.isEmpty
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

  List<CycleGroup> _buildGroups(
    List<ChildPaymentStatusRow> rows,
    List<ChildPaymentCycle> cyclesForSeries,
  ) {
    final Map<String, List<ChildPaymentStatusRow>> map = {};
    final Map<String, ChildPaymentStatusRow> meta = {};

    for (final row in rows) {
      final id = row.cycleId ?? '';
      if (id.isEmpty) continue;
      map.putIfAbsent(id, () => []).add(row);
      meta.putIfAbsent(id, () => row);
    }

    final cycleData = {for (final c in cyclesForSeries) c.id: c};

    final groups = map.entries.map((e) {
      final m = meta[e.key]!;
      final sorted = (e.value
            ..sort((a, b) => (a.workshopDate ?? DateTime(0))
                .compareTo(b.workshopDate ?? DateTime(0))))
          .where((r) => r.workshopDate != null)
          .toList();
      final cycle = cycleData[e.key];
      return CycleGroup(
        cycleId: e.key,
        cycleStatus: cycle?.status ?? m.cycleStatus,
        periodStart: cycle?.periodStart ?? m.periodStart,
        periodEnd: cycle?.periodEnd ?? m.periodEnd,
        paidAt: cycle?.paidAt ?? m.paidAt,
        confirmedByName: m.confirmedByName,
        paymentMethod: _resolveMethod(cycle?.paymentMethod, cycle?.notes),
        sessionsCount: cycle?.sessionsCount,
        rows: sorted,
      );
    }).toList();

    // Defensive: include due/overdue cycles even when the view returned
    // no rows for them (trigger race, freshly closed).
    final represented = map.keys.toSet();
    for (final cycle in cyclesForSeries) {
      if (cycle.id.isEmpty) continue;
      if (represented.contains(cycle.id)) continue;
      if (cycle.status != 'due' && cycle.status != 'overdue') continue;
      groups.add(CycleGroup(
        cycleId: cycle.id,
        cycleStatus: cycle.status,
        periodStart: cycle.periodStart,
        periodEnd: cycle.periodEnd,
        paidAt: cycle.paidAt,
        confirmedByName: null,
        paymentMethod: _resolveMethod(cycle.paymentMethod, cycle.notes),
        sessionsCount: cycle.sessionsCount,
        rows: const [],
      ));
    }
    return groups;
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
