import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/error_state.dart';
import '../../domain/child_current_status_row.dart';
import '../../domain/child_payment_cycle.dart';
import '../../providers/child_details_providers.dart';
import 'attendance_row_item.dart';
import 'details_section_card.dart';

/// Shows the child's current-cycle progress **per workshop series**.
///
/// Since 2026-08-21 the row classification is chronological, not based on
/// `attendance.payment_cycle_id`. That column is a financial linkage
/// (populated only on PRESENT rows that formed a closed 4-session cycle);
/// ABSENT rows always carry NULL there, so filtering by NULL alone leaked
/// intermediate absences into the current section. The correct rule is:
///
///   • for each series, find the latest cycle's `period_end`
///   • the current block contains rows whose `workshop_date` is strictly
///     AFTER that boundary
///   • progress counts only PRESENT rows (absences are shown but don't
///     increment the numerator)
class CurrentStatusCard extends ConsumerWidget {
  const CurrentStatusCard({super.key, required this.childId});
  final String childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rowsAsync = ref.watch(childCurrentStatusRowsProvider(childId));
    final cyclesAsync = ref.watch(childPaymentCyclesNewProvider(childId));

    Widget content;

    if (rowsAsync.isLoading || cyclesAsync.isLoading) {
      content = const _InlineLoader();
    } else if (rowsAsync.hasError) {
      content = AppError(message: rowsAsync.error.toString());
    } else {
      final allRows = rowsAsync.valueOrNull ?? const [];
      final cycles = cyclesAsync.valueOrNull ?? const [];
      final grouped = _classifyCurrentPerSeries(allRows, cycles);
      if (grouped.isEmpty) {
        content = Text(
          'Nu există încă prezențe în statusul actual.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        );
      } else {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < grouped.length; i++) ...[
              if (i > 0) const SizedBox(height: 20),
              _SeriesCurrentBlock(
                seriesTitle: grouped[i].seriesTitle,
                rows: grouped[i].rows,
              ),
            ],
          ],
        );
      }
    }

    return DetailsSectionCard(
      title: 'Status actual',
      iconData: Icons.show_chart_rounded,
      iconColor: const Color(0xFF14B8A6),
      child: content,
    );
  }

  /// For each workshop series the child has attendance in:
  ///   - Find the latest completed cycle's `period_end` for that series.
  ///   - Return only rows dated STRICTLY AFTER that boundary.
  ///   - If the series has no completed cycles, return all rows.
  /// Rows already linked to any cycle (`paymentCycleId != null`) are
  /// excluded — those PRESENT rows belong to their financial cycle.
  List<_SeriesGroup> _classifyCurrentPerSeries(
    List<ChildCurrentStatusRow> rows,
    List<ChildPaymentCycle> cycles,
  ) {
    // Latest period_end per series (only counting completed cycles that
    // participate in the chronological chain, not paid_advance).
    final latestEndPerSeries = <String, DateTime>{};
    for (final c in cycles) {
      final sid = c.seriesId;
      final pe = c.periodEnd;
      if (sid == null || pe == null) continue;
      if (c.status == 'paid_advance') continue;
      final existing = latestEndPerSeries[sid];
      if (existing == null || pe.isAfter(existing)) {
        latestEndPerSeries[sid] = pe;
      }
    }

    final byKey = <String, _SeriesGroup>{};
    for (final r in rows) {
      final key = r.seriesId ?? '__no_series__';
      // A row belongs to the current block when its date is strictly
      // after the latest completed cycle boundary for its series AND it
      // is not linked to any financial cycle (PRESENT rows in a closed
      // cycle carry paymentCycleId — never surface them as "current").
      if (r.paymentCycleId != null) continue;
      final latestEnd =
          r.seriesId != null ? latestEndPerSeries[r.seriesId!] : null;
      if (latestEnd != null &&
          r.workshopDate != null &&
          !r.workshopDate!.isAfter(latestEnd)) {
        continue;
      }
      byKey.putIfAbsent(
        key,
        () => _SeriesGroup(
          seriesId: r.seriesId,
          seriesTitle: r.seriesTitle,
          rows: [],
        ),
      );
      byKey[key]!.rows.add(r);
    }
    final list = byKey.values.toList();
    list.sort((a, b) {
      final at = a.seriesTitle ?? '~';
      final bt = b.seriesTitle ?? '~';
      return at.compareTo(bt);
    });
    return list;
  }
}

class _SeriesGroup {
  _SeriesGroup({
    required this.seriesId,
    required this.seriesTitle,
    required this.rows,
  });

  final String? seriesId;
  final String? seriesTitle;
  final List<ChildCurrentStatusRow> rows;
}

class _SeriesCurrentBlock extends StatelessWidget {
  const _SeriesCurrentBlock({
    required this.seriesTitle,
    required this.rows,
  });

  final String? seriesTitle;
  final List<ChildCurrentStatusRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const total = 4;
    final presentCount =
        rows.where((r) => r.attendanceStatus == 'present').length;
    final progress = (presentCount / total).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          seriesTitle == null || seriesTitle!.isEmpty
              ? 'Atelier neasociat'
              : seriesTitle!,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$presentCount / $total prezențe',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: AppColors.purple.withValues(alpha: 0.12),
            valueColor:
                const AlwaysStoppedAnimation<Color>(AppColors.purple),
          ),
        ),
        const SizedBox(height: 12),
        const AttendanceTableHeader(),
        for (int i = 0; i < rows.length; i++)
          AttendanceRowItem(
            index: i + 1,
            workshopTitle: rows[i].workshopTitle ?? '—',
            dayOfWeek: rows[i].dayOfWeek,
            workshopDate: rows[i].workshopDate,
            startTime: rows[i].startTime,
            endTime: rows[i].endTime,
            attendanceStatus: rows[i].attendanceStatus,
            observation: rows[i].observation,
          ),
      ],
    );
  }
}

class _InlineLoader extends StatelessWidget {
  const _InlineLoader();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
}
