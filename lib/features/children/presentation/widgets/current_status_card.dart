import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/error_state.dart';
import '../../domain/child_current_status_row.dart';
import '../../providers/child_details_providers.dart';
import 'attendance_row_item.dart';
import 'details_section_card.dart';

/// Shows the child's current-cycle progress **per workshop series**.
///
/// Since migration 20260820, payment cycles are scoped per (child, series).
/// The row list is grouped by `seriesId`; each group renders its own
/// progress header + attendance table.
class CurrentStatusCard extends ConsumerWidget {
  const CurrentStatusCard({super.key, required this.childId});
  final String childId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rowsAsync = ref.watch(childCurrentStatusRowsProvider(childId));

    Widget content;

    if (rowsAsync.isLoading) {
      content = const _InlineLoader();
    } else if (rowsAsync.hasError) {
      content = AppError(message: rowsAsync.error.toString());
    } else {
      final rows = rowsAsync.valueOrNull ?? [];
      final grouped = _groupBySeries(rows);
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

  List<_SeriesGroup> _groupBySeries(List<ChildCurrentStatusRow> rows) {
    // Preserve encounter order so the sections show up in the same
    // sequence they would visually (title-driven).
    final byKey = <String, _SeriesGroup>{};
    for (final r in rows) {
      final key = r.seriesId ?? '__no_series__';
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
    // Stable alphabetic ordering by title (nullable last).
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
