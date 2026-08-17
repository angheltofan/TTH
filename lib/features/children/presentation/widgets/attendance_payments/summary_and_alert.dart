import 'package:flutter/material.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/utils/responsive.dart';
import 'series_snapshot.dart';

/// Four compact summary cards + optional financial alert banner.
///
/// Values come from the pre-built [SeriesFinancialSnapshot] map so the
/// numbers here never drift from what the tabs render.
class FinancialSummaryStrip extends StatelessWidget {
  const FinancialSummaryStrip({super.key, required this.snapshots});
  final Map<String, SeriesFinancialSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    final activeWorkshops = snapshots.length;
    var paid = 0;
    var completedTotal = 0;
    var unpaid = 0;
    for (final s in snapshots.values) {
      paid += s.totalPaid;
      completedTotal += s.totalCompleted;
      unpaid += s.totalDue;
    }

    final items = [
      _SummaryItem(
        icon: Icons.school_rounded,
        color: AppColors.purple,
        label: 'Ateliere active',
        value: activeWorkshops.toString(),
      ),
      _SummaryItem(
        icon: Icons.check_circle_rounded,
        color: AppColors.success,
        label: 'Cicluri achitate',
        value: paid.toString(),
      ),
      _SummaryItem(
        icon: Icons.timelapse_rounded,
        color: AppColors.info,
        label: 'Cicluri finalizate',
        value: completedTotal.toString(),
      ),
      _SummaryItem(
        icon: Icons.warning_amber_rounded,
        color: unpaid > 0 ? AppColors.warning : AppColors.muted,
        label: 'Neplătite',
        value: unpaid.toString(),
      ),
    ];

    final isMobile = context.isMobile;
    if (isMobile) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.2,
        children: items,
      );
    }
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: items[i]),
        ],
      ],
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact orange banner shown when the child has one or more due cycles.
/// Lists which workshops are affected so the admin knows where to go.
class PaymentAlertBanner extends StatelessWidget {
  const PaymentAlertBanner({super.key, required this.snapshots});
  final Map<String, SeriesFinancialSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    final duePerSeries = <String, int>{};
    for (final s in snapshots.values) {
      if (s.totalDue > 0) duePerSeries[s.seriesTitle] = s.totalDue;
    }
    final totalDue =
        duePerSeries.values.fold<int>(0, (a, b) => a + b);
    if (totalDue == 0) return const SizedBox.shrink();

    final workshopList = duePerSeries.entries
        .map((e) =>
            e.value > 1 ? '${e.key} (${e.value})' : e.key)
        .join(', ');
    final label = totalDue == 1
        ? '1 ciclu complet este neplătit: $workshopList'
        : '$totalDue cicluri complete sunt neplătite: $workshopList';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: AppColors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF7C5A00),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
